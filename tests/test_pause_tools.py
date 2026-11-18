"""GetPauseState / ControlPause: pure policy in stock AngelScript + source contracts.

No live game. The production PausePolicy.as runs in the stock AngelScript
runner; the cases come from a Python port of the same rules (below), so the
port and the production policy are checked against each other.

UNPROVEN live (2026-11-18): that a programmatic ShowInGameMenu freezes the
clocks like ESC does. ESC in solo was measured to freeze all three clocks
(research/tm2020/2026-11-17-EffectClockAndGamePause.md).
"""
import itertools
import json
import re
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
POLICY = SRC / "PausePolicy.as"
TOOLS = (SRC / "PauseTools.as").read_text()
MCP_TOOLS = (SRC / "McpTools.as").read_text()

PAUSE_TOOLS = ["GetPauseState", "ControlPause"]

# --- Python port of PausePolicy.as -------------------------------------------

U32 = 1 << 32


def clock_bits(signed):
    return signed % U32


def forward_delta(a, b):
    return (b - a) % U32


def jump_ms(paused, first_new):
    d = (first_new - paused) % U32
    return d - U32 if d >= (1 << 31) else d


def verdict(available, changed, window_ms, hold_ms):
    if available == 0:
        return "unknown"
    if changed == 0:
        return "frozen" if window_ms >= hold_ms else "unknown"
    if changed == available or changed >= 2:
        return "running"
    return "mixed"


def refusal(in_pg, loading, local, login_set, spectator):
    if not in_pg:
        return "NO_PLAYGROUND"
    if loading:
        return "LOADING"
    if not local or login_set or spectator:
        return "ONLINE_NOT_PAUSABLE"
    return ""


def resolve(action, menu):
    if action == "toggle":
        return "resume" if menu else "pause"
    return action


def plan(resolved, menu, v):
    if resolved == "pause":
        if not menu:
            return "open"
        return "noop" if v == "frozen" else "verify"
    if resolved == "resume":
        if menu:
            return "close"
        return "noop" if v == "running" else "verify"
    return ""


def clamp(v, given, default, lo, hi):
    if not given:
        return default
    return max(lo, min(hi, v))


def clamp_auto(v, given):
    if not given or v <= 0:
        return 0
    return min(v, 600000)


# --- AngelScript runner --------------------------------------------------------


def run_policy(runner, tmp_path, body):
    case = tmp_path / "pause_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def as_bool(b):
    return "true" if b else "false"


def as_str(s):
    return json.dumps(s)


def test_python_port_basics():
    assert clock_bits(-1) == U32 - 1
    assert forward_delta(U32 - 5, 3) == 8
    assert jump_ms(U32 - 5, 3) == 8
    assert jump_ms(100, 90) == -10
    assert verdict(3, 0, 300, 300) == "frozen"
    assert verdict(3, 0, 299, 300) == "unknown"
    assert verdict(3, 1, 300, 300) == "mixed"


def test_clock_wrap_and_signed_game_time(as_runner, tmp_path):
    lines = []
    for signed in [0, 1, -1, -2147483648, 2147483647, 12844449, -12844449]:
        lines.append(f"Check(ClockBits({signed}) == uint({clock_bits(signed)}), \"bits {signed}\");")
    pairs = [(0, 0), (0, 10), (U32 - 5, 3), (U32 - 1, 0), (100, 90), (12844449, 12844459), (5, U32 - 5)]
    for a, b in pairs:
        lines.append(f"Check(ClockForwardDelta(uint({a}), uint({b})) == uint({forward_delta(a, b)}), \"delta {a}->{b}\");")
        lines.append(f"Check(ClockJumpMs(uint({a}), uint({b})) == {jump_ms(a, b)}, \"jump {a}->{b}\");")
    # A signed client GameTime that crosses the int boundary still steps by 1 in uint bits.
    lines.append("Check(ClockForwardDelta(ClockBits(2147483647), ClockBits(-2147483648)) == uint(1), \"int boundary\");")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_verdict_truth_table(as_runner, tmp_path):
    lines = []
    for available in range(0, 4):
        for changed in range(0, available + 1):
            for window, hold in [(0, 300), (299, 300), (300, 300), (1000, 300), (0, 0)]:
                exp = verdict(available, changed, window, hold)
                lines.append(
                    f"Check(PauseVerdict({available}, {changed}, {window}, {hold}) == {as_str(exp)}, "
                    f"\"verdict {available}/{changed}/{window}/{hold}\");")
    # The key claims, stated plainly.
    lines.append('Check(PauseVerdict(3, 0, 300, 300) == "frozen", "all still for the hold = frozen");')
    lines.append('Check(PauseVerdict(3, 0, 16, 300) == "unknown", "one frame of equal values proves nothing");')
    lines.append('Check(PauseVerdict(3, 1, 300, 300) == "mixed", "one of three moving is not a pause");')
    lines.append('Check(PauseVerdict(1, 1, 300, 300) == "running", "the only clock moving = running");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_locality_gate_truth_table(as_runner, tmp_path):
    lines = []
    for in_pg, loading, local, login, spec in itertools.product([False, True], repeat=5):
        exp = refusal(in_pg, loading, local, login, spec)
        lines.append(
            f"Check(PauseRefusalCode({as_bool(in_pg)}, {as_bool(loading)}, {as_bool(local)}, "
            f"{as_bool(login)}, {as_bool(spec)}) == {as_str(exp)}, "
            f"\"gate {in_pg}/{loading}/{local}/{login}/{spec}\");")
    # Only one combination may pause.
    lines.append('Check(PauseRefusalCode(true, false, true, false, false) == "", "solo/local play pauses");')
    lines.append('Check(PauseRefusalCode(true, false, false, false, false) == "ONLINE_NOT_PAUSABLE", "remote mode script");')
    lines.append('Check(PauseRefusalCode(true, false, true, true, false) == "ONLINE_NOT_PAUSABLE", "connected to a server");')
    lines.append('Check(PauseRefusalReason("ONLINE_NOT_PAUSABLE", false, true, false).IndexOf("Nothing was opened") >= 0, "reason says nothing opened");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))
    allowed = [c for c in itertools.product([False, True], repeat=5) if refusal(*c) == ""]
    assert allowed == [(True, False, True, False, False)]


def test_pause_resume_idempotence_matrix(as_runner, tmp_path):
    lines = []
    verdicts = ["frozen", "running", "mixed", "unknown"]
    for action in ["pause", "resume", "toggle", "bogus", ""]:
        lines.append(f"Check(IsValidPauseAction({as_str(action)}) == {as_bool(action in ('pause', 'resume', 'toggle'))}, \"valid {action}\");")
        for menu in [False, True]:
            r = resolve(action, menu)
            lines.append(f"Check(ResolvePauseAction({as_str(action)}, {as_bool(menu)}) == {as_str(r)}, \"resolve {action}/{menu}\");")
            for v in verdicts:
                exp = plan(r, menu, v)
                lines.append(f"Check(PausePlan({as_str(r)}, {as_bool(menu)}, {as_str(v)}) == {as_str(exp)}, \"plan {r}/{menu}/{v}\");")
    # Idempotence, said plainly.
    lines.append('Check(PausePlan("pause", true, "frozen") == "noop", "pause while paused = no-op");')
    lines.append('Check(PausePlan("resume", false, "running") == "noop", "resume while running = no-op");')
    # Never close a menu someone else opened while asked to pause.
    lines.append('Check(PausePlan("pause", true, "running") == "verify", "online-like menu: touch nothing");')
    # Outcomes.
    lines.append('Check(PauseOutcomeCode(true, "frozen") == "", "paused");')
    lines.append('Check(PauseOutcomeCode(true, "running") == "NOT_PAUSED", "online-like");')
    lines.append('Check(PauseOutcomeCode(true, "mixed") == "NOT_PAUSED", "mixed is not paused");')
    lines.append('Check(PauseOutcomeCode(false, "frozen") == "MENU_NOT_SHOWN", "menu never showed");')
    lines.append('Check(ResumeOutcomeCode(false, "running") == "", "resumed");')
    lines.append('Check(ResumeOutcomeCode(true, "frozen") == "MENU_SUBPAGE_OPEN", "menu still up");')
    lines.append('Check(ResumeOutcomeCode(false, "frozen") == "RESUME_UNVERIFIED", "closed but still");')
    # Auto-resume only fires for the pause it was scheduled for.
    lines.append("Check(AutoResumeShouldFire(3, 3, true, true), \"same pause\");")
    lines.append("Check(!AutoResumeShouldFire(3, 4, true, true), \"a later pause/resume replaced it\");")
    lines.append("Check(!AutoResumeShouldFire(3, 3, false, true), \"not ours\");")
    lines.append("Check(!AutoResumeShouldFire(3, 3, true, false), \"already closed\");")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_clamps(as_runner, tmp_path):
    lines = []
    for v in [-5, 0, 1, 99, 100, 300, 2000, 2001, 99999]:
        for given in [False, True]:
            g = as_bool(given)
            lines.append(f"Check(ClampPauseSampleMs({v}, {g}) == {clamp(v, given, 300, 0, 2000)}, \"sample {v}/{given}\");")
            lines.append(f"Check(ClampPauseHoldMs({v}, {g}) == {clamp(v, given, 300, 100, 2000)}, \"hold {v}/{given}\");")
            lines.append(f"Check(ClampPauseTimeoutMs({v}, {g}) == {clamp(v, given, 3000, 100, 10000)}, \"timeout {v}/{given}\");")
            lines.append(f"Check(ClampAutoResumeMs({v}, {g}) == {clamp_auto(v, given)}, \"auto {v}/{given}\");")
    lines.append("Check(ClampAutoResumeMs(0, false) == 0, \"auto-resume is off by default\");")
    lines.append("Check(ClampAutoResumeMs(999999999, true) == 600000, \"auto-resume cap\");")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


# --- Source contracts -----------------------------------------------------------


def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in text.splitlines())


def test_tools_registered_at_all_three_points():
    for name in PAUSE_TOOLS:
        assert f'name == "{name}"' in MCP_TOOLS, f"{name} missing from IsToolName"
        assert f'if (name == "{name}") return {name}(input);' in MCP_TOOLS, f"{name} missing dispatch"
        assert f'MakeTool("{name}"' in MCP_TOOLS, f"{name} missing MakeTool"


def _schema(name):
    line = next(l for l in MCP_TOOLS.splitlines() if f'MakeTool("{name}"' in l)
    m = re.search(r"'(\{.*\})'\)\);\s*$", line)
    assert m, f"could not extract schema for {name}"
    return json.loads(m.group(1))


def test_schemas_are_closed():
    assert _schema("GetPauseState") == {
        "type": "object", "properties": {"sampleMs": {"type": "integer"}}, "additionalProperties": False}
    s = _schema("ControlPause")
    assert s["additionalProperties"] is False
    assert s["required"] == ["action"]
    assert s["properties"]["action"]["enum"] == ["pause", "resume", "toggle"]
    assert set(s["properties"]) == {"action", "holdMs", "timeoutMs", "autoResumeAfterMs"}


FORBIDDEN_RESULTS = ["Quit", "NormalMenu", "AdvancedMenu", "ServerSettings"]


def test_no_forbidden_close_results_in_new_code():
    code = _strip_comments(TOOLS) + _strip_comments(POLICY.read_text())
    for r in FORBIDDEN_RESULTS:
        assert f"EInGameMenuResult::{r}" not in code, f"{r} must never be used by the pause tools"
    # Exactly one close call, and it is Resume.
    calls = re.findall(r"\.CloseInGameMenu\(([^)]*)\)", code)
    assert calls == ["CGameScriptHandlerPlaygroundInterface::EInGameMenuResult::Resume"], calls


def test_locality_gate_runs_before_show_in_game_menu():
    body = _strip_comments(TOOLS)
    start = body.index("Json::Value@ ControlPause(")
    fn = body[start:]
    gate = fn.index("PauseRefusalCode(")
    refuse = fn.index("if (refusal.Length > 0)")
    show = fn.index("ShowInGameMenu()")
    assert gate < refuse < show, "the locality gate must refuse before the menu is opened"
    # The only other ShowInGameMenu call is the re-try loop, which is reached after the gate.
    assert body.count("ShowInGameMenu()") == 2


def test_verdict_never_comes_from_menu_flag():
    """IsServerOrSolo is reported only; the pause verdict is the clocks."""
    body = _strip_comments(TOOLS)
    assert "IsServerOrSolo" in body
    gate_call = re.search(r"PauseRefusalCode\(([^)]*)\)", body).group(1)
    assert "IsServerOrSolo" not in gate_call
    assert "PauseVerdict(" in body


def test_failed_pause_closes_the_menu_it_opened():
    body = _strip_comments(TOOLS)
    fn = body[body.index('if (plan == "open")'):]
    fail = fn.index("if (code.Length > 0)")
    tail = fn[fail:fn.index("g_pauseToken++", fail)]
    assert "_CloseMenuResume()" in tail


def test_auto_resume_is_off_by_default_and_scoped():
    body = _strip_comments(TOOLS)
    assert "if (autoResumeMs > 0) startnew(_PauseAutoResumeCoro);" in body
    assert "AutoResumeShouldFire(" in body


def test_no_os_input_mlhook_or_raw_memory():
    body = _strip_comments(TOOLS)
    for banned in ["Dev::", "MLHook::", "RunManialinkScript", "SendKey", "VirtualKey", "IO::"]:
        assert banned not in body, banned


def test_policy_file_has_no_game_types():
    policy = _strip_comments(POLICY.read_text())
    for banned in ["GetApp", "CGame", "CMw", "yield", "Time::"]:
        assert banned not in policy, banned


def test_guide_and_docs_mark_live_checks_unproven():
    guides = (SRC / "Guides.as").read_text()
    start = guides.index('_RegisterGuide("pause-bloom",')
    guide = guides[start:guides.index("_RegisterGuide(", start + 1)]
    for name in ["GetPauseState", "ControlPause", "SetDisplaySetting", "RestoreDisplaySetting", "ONLINE_NOT_PAUSABLE"]:
        assert name in guide, name
    for doc in [guide, (ROOT / "README.md").read_text(), (ROOT / "AGENTS.md").read_text(), (ROOT / "CHANGELOG.md").read_text()]:
        assert "nproven" in doc or "NPROVEN" in doc
        for q in ["Q1", "Q2", "Q3", "Q4"]:
            assert q in doc, q
