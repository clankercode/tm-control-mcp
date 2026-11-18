"""GetPauseState / ControlPause: policy, orchestration and source contracts.

No live game. The production PausePolicy.as runs in the stock AngelScript
runner against a Python port of the same rules. The production orchestration
(PauseCore.as: clock window, per-frame observation, one-Resume cleanup,
deadline) runs in the same runner against a scripted fake game
(tests/as_core_fakes.py). Fix round 2 removed the ownership watcher, the
auto-resume timer and the context generations; the regressions here are
named after the brief's P1-P5 and the review-2 findings that still apply.

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
from as_core_fakes import run_pause

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
POLICY = SRC / "PausePolicy.as"
TOOLS = (SRC / "PauseTools.as").read_text()
CORE = (SRC / "PauseCore.as").read_text()
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


def budget(hold, timeout):
    return 3 * hold + timeout + 2000


def clamp(v, given, default, lo, hi):
    if not given:
        return default
    return max(lo, min(hi, v))


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
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_clamps(as_runner, tmp_path):
    lines = []
    for v in [-5, 0, 1, 99, 100, 300, 2000, 2001, 99999]:
        for given in [False, True]:
            g = as_bool(given)
            lines.append(f"Check(ClampPauseSampleMs({v}, {g}) == {clamp(v, given, 300, 0, 2000)}, \"sample {v}/{given}\");")
            lines.append(f"Check(ClampPauseHoldMs({v}, {g}) == {clamp(v, given, 300, 100, 2000)}, \"hold {v}/{given}\");")
            lines.append(f"Check(ClampPauseTimeoutMs({v}, {g}) == {clamp(v, given, 3000, 100, 10000)}, \"timeout {v}/{given}\");")
    # Clamped in double before narrowing (review 2 F10/P3): huge, infinite, NaN, fractional.
    lines.append("Check(ClampPauseHoldMs(1e309, true) == 2000, \"inf hold -> max\");")
    lines.append("Check(ClampPauseHoldMs(-1e309, true) == 100, \"-inf hold -> min\");")
    lines.append("Check(ClampPauseTimeoutMs(4294967296.0 * 8, true) == 10000, \"beyond int range -> max\");")
    lines.append("double inf = 1e309; double nan = inf - inf;")
    lines.append("Check(ClampPauseHoldMs(nan, true) == 100, \"NaN -> min\");")
    lines.append("Check(ClampPauseSampleMs(299.9, true) == 299, \"fraction truncated after the clamp\");")
    for hold in [100, 300, 2000]:
        for timeout in [100, 3000, 10000]:
            lines.append(f"Check(PauseCallBudgetMs({hold}, {timeout}) == {budget(hold, timeout)}, \"budget {hold}/{timeout}\");")
    lines.append("Check(PauseCallBudgetMs(2000, 10000) == 18000, \"worst-case budget\");")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


# --- Production orchestration (PauseCore.as) on a fake game ---------------------
# Each scenario runs the real ControlPauseCore / GetPauseStateCore with a scripted
# fake game: per-frame clocks, menu, gate, dialog, playground/handler ids.


def test_core_pause_resume_round_trip(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(r) && OutBool(r, "paused") && OutBool(r, "changed") && OutBool(r, "openedByThisCall"), "paused: " + Code(r));
    Check(g.menu && g.shows >= 1 && g.closes == 0, "menu up, no Resume sent on a good pause");
    auto again = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(again) && OutStr(again, "plan") == "noop" && !OutBool(again, "changed"), "idempotent pause");
    Check(!OutBool(again, "openedByThisCall"), "the noop opened nothing");
    // Nothing outlives a call: many idle frames later the menu is still up, untouched.
    uint closes = g.closes;
    g.Idle(2000);
    Check(g.menu && g.closes == closes, "no timer, no watcher: the menu stays until the agent resumes");
    auto r2 = ControlPauseCore(g, PauseInput("resume"));
    Check(Ok(r2) && !g.menu && g.closes == closes + 1, "resumed with one Resume: " + Code(r2));
    Check(r2["output"]["jumpMs"].HasKey("clientGameTime"), "jumpMs reported");
    auto again2 = ControlPauseCore(g, PauseInput("resume"));
    Check(Ok(again2) && OutStr(again2, "plan") == "noop", "idempotent resume");
    """)


def test_p1_resume_closes_a_menu_someone_else_opened(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menu = true;                       // a person pressed ESC
    auto p = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(p) && OutStr(p, "plan") == "noop" && !OutBool(p, "openedByThisCall") && g.shows == 0, "noop, not ours");
    auto r = ControlPauseCore(g, PauseInput("resume"));
    Check(Ok(r) && !g.menu && g.closes == 1, "resume closes it whoever opened it: " + Code(r));
    Check(!OutBool(r, "openedByThisCall"), "and says it did not open it");
    // Pause never closes a menu: up but running stays up.
    auto g2 = FakePauseGame();
    g2.menu = true; g2.menuFreezes = false;
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "NOT_PAUSED" && g2.menu && g2.closes == 0, "pause leaves it: " + Code(r2));
    """)


def test_f5_p5_clock_a_b_a_is_not_frozen(as_runner, tmp_path):
    """Review 2 F5 survivor: a clock that goes A -> B -> A has changed twice."""
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menu = true;                       // frozen by a menu
    auto w = PauseClockWindow();
    for (uint i = 0; i < 10; i++) { g.now += 16; w.Observe(g, true); }
    g.clocks[1] += 1; g.now += 16; w.Observe(g, true);   // A -> B
    g.clocks[1] -= 1; g.now += 16; w.Observe(g, true);   // B -> A
    for (uint i = 0; i < 20; i++) { g.now += 16; w.Observe(g, true); }
    Check(w.WindowMs() >= 300, "a full window");
    Check(w.changes[1] == 2 && w.Verdict(300) != "frozen", "A->B->A is not frozen: " + w.Verdict(300));
    // Through GetPauseStateCore too.
    auto g2 = FakePauseGame();
    g2.menu = true;
    g2.At(1100, "bump", 2); g2.At(1200, "unbump", 2);
    auto r = GetPauseStateCore(g2, SampleInput(300));
    Check(OutStr(r, "verdict") != "frozen", "GetPauseState: A->B->A not frozen: " + OutStr(r, "verdict"));
    // Through a pause's verification window: never claims paused.
    auto g3 = FakePauseGame();
    g3.At(1700, "bump", 0); g3.At(1800, "unbump", 0);
    g3.At(2700, "bump", 0); g3.At(2800, "unbump", 0);
    g3.At(3700, "bump", 0); g3.At(3800, "unbump", 0);
    g3.At(4700, "bump", 0); g3.At(4800, "unbump", 0);
    auto r3 = ControlPauseCore(g3, PauseInput("pause", 1000, 3000));
    Check(!(Ok(r3) && OutBool(r3, "paused")), "a flickering clock is never a verified pause: " + Code(r3));
    """)


def test_f5_window_restarts_on_unreadable_or_loading(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menu = true;
    auto w = PauseClockWindow();
    g.readable[0] = false; w.Observe(g, true);
    g.now += 300; g.readable[0] = true; w.Observe(g, true);
    Check(w.Verdict(300) != "frozen", "a late clock never counts for the elapsed window");
    auto w2 = PauseClockWindow();
    w2.Observe(g, true);
    g.now += 100; g.clocks[0] += 10; w2.Observe(g, true);
    g.now += 200; g.readable[0] = false; w2.Observe(g, true);
    Check(w2.Verdict(300) != "frozen", "a moving clock that disappears is not frozen");
    g.readable[0] = true;
    auto w3 = PauseClockWindow();
    for (uint i = 0; i < 15; i++) { g.now += 16; w3.Observe(g, true); }
    w3.Observe(g, false);
    Check(!w3.started && w3.restarts == 1, "restart on a loading frame");
    """)


def test_p4_get_pause_state_samples_online(as_runner, tmp_path):
    """Review 2 GetPauseState P2: read-only, so it samples online; final values read at the end."""
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.local = false; g.loginSet = true;  // on a server: not pausable, clocks running
    auto r = GetPauseStateCore(g, SampleInput(300));
    Check(Ok(r) && OutStr(r, "verdict") == "running", "online clocks measured: " + OutStr(r, "verdict"));
    Check(!OutBool(r, "pausable") && OutStr(r, "notPausableReason").Length > 0, "but not pausable");
    Check(int(r["output"]["windowMs"]) >= 300 && !OutHas(r, "sampleStopped"), "a full window, not cut short");
    // An online menu that is up while the game runs.
    auto g2 = FakePauseGame();
    g2.local = false; g2.menu = true; g2.menuFreezes = false;
    auto r2 = GetPauseStateCore(g2, SampleInput(300));
    Check(OutStr(r2, "verdict") == "running" && OutBool(r2, "menuShown"), "menu up, still running online");
    // Locality and menu change during the sample: the reported values are the final ones.
    auto g3 = FakePauseGame();
    g3.menu = true;
    g3.At(1100, "menu", 0); g3.At(1150, "local", 0);
    auto r3 = GetPauseStateCore(g3, SampleInput(300));
    Check(!OutBool(r3, "menuShown") && OutBool(r3, "menuShownAtStart"), "menuShown read at the end");
    Check(!OutBool(r3, "pausable"), "pausable read at the end");
    Check(!bool(r3["output"]["locality"]["playgroundScriptLocal"]), "locality read at the end");
    Check(g3.shows == 0 && g3.closes == 0, "read-only");
    // A map change still ends the sample with no verdict.
    auto g4 = FakePauseGame();
    g4.At(1100, "playground", 8);
    auto r4 = GetPauseStateCore(g4, SampleInput(300));
    Check(OutStr(r4, "verdict") == "unknown" && OutHas(r4, "sampleStopped"), "context change: unknown");
    """)


# Timing probe: run a clean call first to learn the fake time at which the
# initial sample ends, so an event can be placed in the one window a check covers.
SAMPLE_END_PROBE = r"""
    auto probe = FakePauseGame();
    probe.menu = true;                   // frozen: the sample runs its full holdMs
    auto pr = ControlPauseCore(probe, PauseInput("pause"));
    Check(OutStr(pr, "plan") == "noop", "probe is a noop");
    uint64 sampleEnd = probe.now;        // a noop returns right after the sample
"""


def test_p2_locality_or_context_change_before_show_never_shows(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, SAMPLE_END_PROBE + r"""
    array<string> what = {"local", "playground", "loading", "handler"};
    array<int> value = {0, 8, 1, 10};
    array<string> code = {"ONLINE_NOT_PAUSABLE", "CONTEXT_CHANGED", "LOADING", "CONTEXT_CHANGED"};
    for (uint i = 0; i < what.Length; i++) {
        auto g = FakePauseGame();
        g.At(1100, what[i], value[i]);
        auto r = ControlPauseCore(g, PauseInput("pause"));
        Check(Code(r) == code[i] && g.shows == 0 && !g.menu, what[i] + " mid-sample: " + Code(r));
        Check(g.now <= 1100 + 16, what[i] + ": stopped on the first frame after the change, at " + g.now);
        auto g2 = FakePauseGame();
        g2.At(sampleEnd, what[i], value[i]);
        auto r2 = ControlPauseCore(g2, PauseInput("pause"));
        Check(Code(r2) == code[i] && g2.shows == 0, what[i] + " on the last sample frame: " + Code(r2));
    }
    // Changed with no yield in between, on the read immediately before Show.
    auto probe2 = FakePauseGame();
    Check(Ok(ControlPauseCore(probe2, PauseInput("pause"))), "probe pause");
    auto g3 = FakePauseGame();
    g3.goOnlineOnGateRead = int(probe2.gateReadsAtFirstShow);
    auto r3 = ControlPauseCore(g3, PauseInput("pause"));
    Check(g3.shows == 0 && Code(r3) == "ONLINE_NOT_PAUSABLE" && OutStr(r3, "stoppedAt") == "before-action",
          "read immediately before Show: " + Code(r3) + " shows=" + g3.shows);
    """)


def test_p2_dialog_before_first_show_and_before_resume(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, SAMPLE_END_PROBE + r"""
    auto g = FakePauseGame();
    g.At(1200, "dialog", 1);
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "DIALOG_BLOCKING" && g.shows == 0, "dialog during the sample: " + Code(r));
    auto probe2 = FakePauseGame();
    Check(Ok(ControlPauseCore(probe2, PauseInput("pause"))), "probe pause");
    auto g2 = FakePauseGame();
    g2.dialogOnRead = int(probe2.dialogReadsAtFirstShow);
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "DIALOG_BLOCKING" && g2.shows == 0, "dialog on the read immediately before Show: " + Code(r2));
    auto g3 = FakePauseGame();
    g3.menu = true;
    g3.At(sampleEnd, "dialog", 1);
    auto r3 = ControlPauseCore(g3, PauseInput("resume"));
    Check(Code(r3) == "DIALOG_BLOCKING" && g3.closes == 0 && g3.menu, "resume behind a dialog: " + Code(r3));
    """)


def test_p2_dialog_appearing_before_a_re_show_stops_it(as_runner, tmp_path):
    """Review 2 F9: the first Show is ignored and a blocking dialog appears on the next frame."""
    run_pause(as_runner, tmp_path, r"""
    auto probe = FakePauseGame();
    probe.showLagFrames = -1;            // Show never lands
    ControlPauseCore(probe, PauseInput("pause", 100, 1000));
    Check(probe.shows >= 3 && probe.showAt.Length >= 2, "probe re-shows");
    uint64 firstShow = probe.showAt[0];
    auto g = FakePauseGame();
    g.showLagFrames = -1;
    g.At(firstShow + 1, "dialog", 1);    // on the frame right after the first Show
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 1000));
    Check(g.shows == 1, "no Show after the dialog appeared: shows=" + g.shows);
    Check(Code(r) == "DIALOG_BLOCKING", "reported: " + Code(r));
    Check(OutBool(r, "lateShowPossible"), "the ignored Show may still land: said so");
    Check(!g.menu && OutBool(r, "menuShownAfter") == g.menu, "menuShownAfter is what was seen");
    // One Show that took effect and was closed again: no late Show to expect.
    auto g2 = FakePauseGame();
    g2.menuFreezes = false;
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "NOT_PAUSED" && g2.shows == 1 && !OutBool(r2, "lateShowPossible"), "no late show claimed");
    """)


def test_p2_context_change_after_show_never_resumes_into_new_playground(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menuFreezes = false;              // menu opens, clocks keep running
    g.At(1500, "playground", 8);        // map changes while verifying
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "CONTEXT_CHANGED", "stopped on context change: " + Code(r));
    Check(g.closes == 0 && !OutBool(r, "resumeSent"), "no Resume sent into another playground");
    Check(g.now <= 1500 + 16, "stopped on the first frame after the change, at " + g.now);
    Check(OutBool(r, "menuShownAfter") == g.menu, "menuShownAfter is the truth");
    """)


def test_p2_menu_closed_and_reopened_during_verification_is_not_ours(as_runner, tmp_path):
    """Review 2 F8: a person closes the call's menu during sampling and opens another one."""
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menuFreezes = false;              // not frozen, so the call keeps sampling
    g.At(1500, "menu", 0);              // the person closes it...
    g.At(1550, "menu", 1);              // ...and opens their own
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "MENU_CLOSED", "stopped when its menu closed: " + Code(r));
    Check(g.closes == 0 && OutStr(r, "cleanupSkipped").Length > 0, "no Resume, and says why");
    Check(g.now < 1550, "the call ended on the frame it saw the close");
    g.Idle(10);
    Check(g.menu && g.closes == 0, "the replacement menu is never closed by this call");
    // Same if the replacement shows a frozen game: never a verified pause.
    auto g2 = FakePauseGame();
    g2.showLagFrames = 1;
    g2.At(1400, "menu", 0); g2.At(1420, "menu", 1);
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(!(Ok(r2) && OutBool(r2, "paused")), "a replacement menu is never a success: " + Code(r2));
    """)


def test_p2_deadline_after_a_slow_frame(as_runner, tmp_path):
    """Review 2 F10: after a slow frame the call sends no further Show and stops near the budget."""
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.showLagFrames = -1;                // Show never lands: the call keeps re-showing
    g.slowAt = 1100; g.slowMs = 5000;    // one 5 s hitch right after the first Show
    uint64 t0 = g.now;
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 2400));
    uint budget = PauseCallBudgetMs(100, 2400);
    Check(!Ok(r), "fails");
    Check(g.showAt.Length >= 1 && !g.AnyShowAfter(t0 + uint64(budget) - uint64(PAUSE_CLEANUP_RESERVE_MS)),
          "no Show after the show deadline, even right after the slow frame");
    Check(g.shows == 1, "the slow frame ended the show phase: shows=" + g.shows);
    // Initial sample (~holdMs) + the one 5 s frame; nothing after it.
    Check(g.now - t0 <= uint64(100 + 16 + 5000), "stopped on the first check after the hitch: took " + (g.now - t0));
    Check(g.now - t0 > uint64(budget), "the hitch overran the budget by that frame (documented)");
    Check(double(r["output"]["longestFrameMs"]) >= 5000, "the hitch is reported");
    Check(OutBool(r, "lateShowPossible"), "the unanswered Show is reported as a possibility");
    Check(Code(r) == "DEADLINE", "the deadline is checked right after the yield: " + Code(r));
    // A hitch that ends past the show deadline (timeoutMs) but before the call
    // deadline: Step does not stop the call, the check before the next Show does.
    auto g3 = FakePauseGame();
    g3.showLagFrames = -1;
    g3.slowAt = 1150; g3.slowMs = 3000;   // show phase ends ~3512, call deadline ~5700
    uint64 t3 = g3.now;
    auto r3 = ControlPauseCore(g3, PauseInput("pause", 100, 2400));
    Check(g3.shows >= 1 && !g3.AnyShowAfter(1150 + 3000), "no Show after the hitch passed the show deadline");
    Check(g3.now - t3 < uint64(PauseCallBudgetMs(100, 2400)), "ended before the call deadline");
    Check(Code(r3) == "MENU_NOT_SHOWN", "reported as not shown: " + Code(r3));
    // A hitch during verification of a real (frozen) pause: no success past the
    // deadline; the one Resume closes the menu this call opened.
    auto g2 = FakePauseGame();
    g2.slowAt = 1150; g2.slowMs = 6000;
    auto r2 = ControlPauseCore(g2, PauseInput("pause", 100, 2400));
    Check(Code(r2) == "DEADLINE" && OutBool(r2, "resumeSent") && g2.closes == 1 && !g2.menu,
          "deadline after a slow frame in verification: " + Code(r2));
    // A bounded grid: every failure ends within budget + one frame on normal frames.
    array<int> holds = {100, 300, 2000};
    array<int> timeouts = {100, 3000, 10000};
    for (uint a = 0; a < holds.Length; a++) for (uint b = 0; b < timeouts.Length; b++) {
        for (uint mode = 0; mode < 4; mode++) {
            auto h = FakePauseGame();
            if (mode == 0) { h.menuFreezes = false; }                          // NOT_PAUSED + one Resume
            if (mode == 1) { h.menuFreezes = false; h.closeLagFrames = -1; }   // CLEANUP_FAILED
            if (mode == 2) { h.showLagFrames = -1; }                           // MENU_NOT_SHOWN
            if (mode == 3) { h.readable[1] = false; }                          // a clock never readable
            uint64 s0 = h.now;
            auto rr = ControlPauseCore(h, PauseInput("pause", holds[a], timeouts[b]));
            uint bud = PauseCallBudgetMs(uint(holds[a]), uint(timeouts[b]));
            Check(int(rr["output"]["budgetMs"]) == int(bud), "budget reported");
            Check(h.now - s0 <= uint64(bud) + 16, "pause " + holds[a] + "/" + timeouts[b] + " mode " + mode
                  + " took " + (h.now - s0) + " > " + bud);
            Check(!Ok(rr), "every one of these fails");
            Check(h.closes <= 1, "at most one Resume (mode " + mode + "): " + h.closes);
            Check(OutBool(rr, "menuShownAfter") == h.menu, "menuShownAfter is what was seen (mode " + mode + ")");
            if (mode == 1) Check(Code(rr) == "CLEANUP_FAILED" && h.menu, "still up after one Resume: " + Code(rr));
        }
    }
    """)


def test_p3_failure_sends_one_resume_and_reports_what_it_saw(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    g.menuFreezes = false;              // not paused
    g.closeLagFrames = 5;               // Resume lands a few frames later
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "NOT_PAUSED" && OutBool(r, "resumeSent") && g.closes == 1, "one Resume: " + Code(r));
    Check(!g.menu && !OutBool(r, "menuShownAfter") && OutBool(r, "openedByThisCall"), "closure observed");
    auto g2 = FakePauseGame();
    g2.menuFreezes = false; g2.closeLagFrames = -1;   // Resume ignored
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "CLEANUP_FAILED" && g2.closes == 1 && g2.menu, "no retry loop: " + Code(r2));
    Check(OutBool(r2, "menuShownAfter") && OutStr(r2, "cause") == "NOT_PAUSED", "truthful state");
    Check(string(r2["error"]).IndexOf("seen closed") < 0, "never claims a closure it did not see");
    g2.Idle(500);
    Check(g2.closes == 1, "nothing runs after the call");
    // A Show that lands after the call returned: reported as possible, not hidden.
    auto g3 = FakePauseGame();
    g3.showLagFrames = 1000;
    auto r3 = ControlPauseCore(g3, PauseInput("pause", 100, 100));
    Check(Code(r3) == "MENU_NOT_SHOWN" && OutBool(r3, "lateShowPossible") && g3.closes == 0, "late show possible");
    Check(string(r3["error"]).IndexOf("may still be applied later") >= 0, "the message says so");
    """)


def test_get_pause_state_is_read_only(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r"""
    auto g = FakePauseGame();
    auto r = GetPauseStateCore(g, SampleInput(300));
    Check(Ok(r) && OutStr(r, "verdict") == "running", "running");
    Check(g.shows == 0 && g.closes == 0, "read-only");
    g.menu = true;
    auto r2 = GetPauseStateCore(g, SampleInput(300));
    Check(OutStr(r2, "verdict") == "frozen", "frozen");
    auto bad = Json::Object(); bad["sampleMs"] = "x";
    Check(Code(GetPauseStateCore(g, bad)) == "INVALID_INPUT", "non-number input");
    auto inf = Json::Object(); inf["sampleMs"] = 1e309;
    auto r3 = GetPauseStateCore(g, inf);
    Check(Ok(r3) && OutInt(r3, "sampleMs") == 2000, "infinite input clamped on the plugin side");
    """)


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
    assert set(s["properties"]) == {"action", "holdMs", "timeoutMs"}


FORBIDDEN_RESULTS = ["Quit", "NormalMenu", "AdvancedMenu", "ServerSettings"]


def test_no_forbidden_close_results_in_new_code():
    code = _strip_comments(TOOLS) + _strip_comments(CORE) + _strip_comments(POLICY.read_text())
    for r in FORBIDDEN_RESULTS:
        assert f"EInGameMenuResult::{r}" not in code, f"{r} must never be used by the pause tools"
    calls = re.findall(r"\.CloseInGameMenu\(([^)]*)\)", code)
    assert calls == ["CGameScriptHandlerPlaygroundInterface::EInGameMenuResult::Resume"], calls
    assert len(re.findall(r"\.ShowInGameMenu\(\)", code)) == 1
    assert not re.search(r"\.(ShowInGameMenu|CloseInGameMenu)\(", _strip_comments(CORE)), "the core calls the host only"


def test_menu_calls_go_through_the_checked_paths():
    core = _strip_comments(CORE)
    # ShowMenu only inside ShowChecked, after a fresh Observe and the dialog + deadline checks.
    assert core.count("host.ShowMenu()") == 1
    show = core[core.index("bool ShowChecked("):core.index("void Resume()")]
    assert show.index("Observe();") < show.index("if (dialog)") < show.index("Past(deadline)") < show.index("host.ShowMenu()")
    # CloseMenuResume only inside PauseCall.Resume.
    assert core.count("host.CloseMenuResume()") == 1
    assert "host.Yield()" in core and core.count("host.Yield()") == 1, "every yield goes through PauseCall.Step"
    step = core[core.index("void Step()"):core.index("bool Past(")]
    assert step.index("host.Yield()") < step.index("Observe();")


def test_nothing_outlives_a_call():
    code = _strip_comments(TOOLS) + _strip_comments(CORE) + _strip_comments(POLICY.read_text())
    for banned in ["startnew", "g_pause", "autoResume", "StartWatcher", "PauseWatch", "Ownership"]:
        assert banned not in code, banned
    main = _strip_comments((SRC / "Main.as").read_text())
    assert "Pause" not in main


def test_verdict_never_comes_from_menu_flag():
    tools = _strip_comments(TOOLS)
    assert "IsServerOrSolo" in tools
    core = _strip_comments(CORE)
    gate_call = re.search(r"PauseRefusalCode\(([^)]*)\)", core).group(1)
    assert "serverOrSolo" not in gate_call
    assert "PauseVerdict(" in core


def test_no_os_input_mlhook_or_raw_memory():
    body = _strip_comments(TOOLS) + _strip_comments(CORE)
    for banned in ["Dev::", "MLHook::", "RunManialinkScript", "SendKey", "VirtualKey", "IO::"]:
        assert banned not in body, banned


def test_policy_and_core_have_no_game_types():
    for text in [POLICY.read_text(), CORE]:
        body = _strip_comments(text)
        for banned in ["GetApp", "CGame", "CMw", "yield", "Time::", "startnew", "GetCmdBufferCore"]:
            assert banned not in body, banned


def test_live_host_contexts_hold_no_engine_reference():
    tools = _strip_comments(TOOLS)
    assert "MwAddRef" not in tools and "MwRelease" not in tools


def test_guide_and_docs_mark_live_checks_unproven():
    guides = (SRC / "Guides.as").read_text()
    start = guides.index('_RegisterGuide("pause-bloom",')
    guide = guides[start:guides.index("_RegisterGuide(", start + 1)]
    for name in ["GetPauseState", "ControlPause", "SetDisplaySetting", "RestoreDisplaySetting", "ONLINE_NOT_PAUSABLE"]:
        assert name in guide, name
    assert re.search(
        r"Require a measured jumpMs entry for every[^;]*?clock \(clientGameTime, coreSimulationTime, coreGameTime\)",
        guide, re.S,
    )
    for doc in [guide, (ROOT / "README.md").read_text(), (ROOT / "AGENTS.md").read_text(), (ROOT / "CHANGELOG.md").read_text()]:
        assert "nproven" in doc or "NPROVEN" in doc
        for q in ["Q1", "Q2", "Q3", "Q4"]:
            assert q in doc, q
    for doc in [guide, (ROOT / "README.md").read_text(), (ROOT / "AGENTS.md").read_text()]:
        assert "autoResumeAfterMs" not in doc


def test_pause_catalog_distinguishes_observation_from_attribution():
    text = next(line for line in MCP_TOOLS.splitlines() if 'MakeTool("ControlPause",' in line)
    assert "openedByThisCall means observed open after a Show in this call, not who opened it" in text
    assert "Before dispatch, refusals like NO_PLAYGROUND, LOADING, ONLINE_NOT_PAUSABLE" in text
    assert "After Show, those same codes can be in-flight aborts; check cleanupSkipped and menuShownAfter" in text


def test_r4_late_manual_menu_requires_fresh_continuous_hold(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.clocksIdle = true;
    g.At(1280, "menu", 1);   // only the tail of the initial 300 ms sample
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(r) && OutBool(r, "paused") && OutStr(r, "plan") == "noop" && g.now >= 1580,
          "waited a full menu-up hold rather than using idle clocks before ESC");
    Check(g.shows == 0 && g.closes == 0, "never touches the existing menu");
    auto g2 = FakePauseGame(); g2.clocksIdle = true;
    g2.At(1280, "menu", 1); g2.At(1360, "menu", 0);
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "MENU_CLOSED" && g2.shows == 0 && g2.closes == 0, "late menu went away during fresh window");
    auto g3 = FakePauseGame(); g3.clocksIdle = true; g3.menu = true;
    g3.At(1160, "menu", 0); g3.At(1280, "menu", 1); g3.At(1360, "bump", 1);
    auto r3 = ControlPauseCore(g3, PauseInput("pause"));
    Check(Code(r3) == "NOT_PAUSED" && g3.shows == 0 && g3.closes == 0, "close/reopen requires a fresh frozen hold");
    ''')


def test_existing_menu_closes_at_final_observation(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.menu = true; g.closeMenuOnReport = 2;
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "MENU_CLOSED" && g.shows == 0 && g.closes == 0 && !g.menu,
          "menu closed after the full hold, before the final observation");
    ''')


def test_r5_pending_shows_warn_even_if_cleanup_ends_with_menu_up(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame();
    g.showLagFrames = 3; g.menuFreezes = false; g.closeLagFrames = -1;
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
    Check(Code(r) == "CLEANUP_FAILED" && g.shows > 1 && g.closes == 1 && OutBool(r, "menuShownAfter"), "still up");
    Check(OutBool(r, "lateShowPossible") && string(r["hint"]).IndexOf("appears closed") >= 0,
          "a remaining Show may reopen it; recheck after it looks closed");
    auto g2 = FakePauseGame(); g2.showLagFrames = 3;
    auto r2 = ControlPauseCore(g2, PauseInput("pause", 100, 100));
    Check(Ok(r2) && g2.shows > 1 && OutBool(r2, "lateShowPossible"), "several Shows still ambiguous on success");
    ''')


def test_r6_failed_pause_does_not_resume_into_invalid_gate_or_wait_through_it(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    array<string> change = {"local", "loading", "inPlayground", "handler"};
    array<int> values = {0, 1, 0, 10};
    array<string> codes = {"ONLINE_NOT_PAUSABLE", "LOADING", "NO_PLAYGROUND", "CONTEXT_CHANGED"};
    for (uint i = 0; i < change.Length; i++) {
        auto g = FakePauseGame(); g.menuFreezes = false;
        g.At(1150, change[i], values[i]);
        auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
        Check(Code(r) == codes[i] && g.shows == 1 && g.closes == 0 && OutBool(r, "menuShownAfter")
            && OutStr(r, "cleanupSkipped") == codes[i], "refuse cleanup at " + change[i] + ": " + Code(r));
    }
    auto probe = FakePauseGame(); probe.menuFreezes = false;
    ControlPauseCore(probe, PauseInput("pause", 100, 100));
    for (uint i = 0; i < change.Length; i++) {
        auto g = FakePauseGame(); g.menuFreezes = false; g.closeLagFrames = -1;
        uint64 changeAt = probe.closeAt[0] + 1;
        g.At(changeAt, change[i], values[i]);
        auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
        Check(Code(r) == "CLEANUP_FAILED" && g.closes == 1 && g.now <= changeAt + 16,
              "stop waiting on the first invalid frame: " + change[i]);
    }
    auto g = FakePauseGame(); g.menuFreezes = false;
    g.goOnlineOnGateRead = int(probe.gateReadsAtFirstResume);
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
    Check(g.closes == 0 && OutStr(r, "cleanupSkipped") == "ONLINE_NOT_PAUSABLE", "fresh gate immediately before cleanup Resume");
    ''')


def test_cleanup_retains_first_gate_refusal_even_if_gate_recovers(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.transientOnlineAfterShow = true;
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
    Check(g.gateReads > g.gateReadsAtFirstShow + 1 && g.shows == 1 && g.closes == 0 && g.menu,
          "cleanup rechecked the gate but did not Resume");
    Check(Code(r) == "ONLINE_NOT_PAUSABLE" && OutStr(r, "cleanupSkipped") == "ONLINE_NOT_PAUSABLE",
          "retain the refusal from the first invalid frame");
    ''')


def test_menu_readers_lost_after_show(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.loseMenuReadersAfterShow = true;
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
    Check(Code(r) == "NO_PLAYGROUND" && g.shows == 1 && g.closes == 0 && g.menu,
          "readers disappeared after Show without closing the menu");
    Check(OutStr(r, "menuShownAfter") == "unknown" && OutBool(r, "lateShowPossible")
          && string(r["hint"]).IndexOf("GetPauseState") >= 0 && string(r["error"]).IndexOf("observed closed") < 0,
          "unavailable after Show is unknown, not closed");
    ''')


def test_menu_readers_lost_after_cleanup_resume(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g2 = FakePauseGame(); g2.menuFreezes = false; g2.closeLagFrames = -1;
    g2.loseMenuReadersAfterResume = true;
    auto r2 = ControlPauseCore(g2, PauseInput("pause", 100, 100));
    Check(Code(r2) == "CLEANUP_FAILED" && OutStr(r2, "cause") == "NOT_PAUSED"
          && g2.shows == 1 && g2.closes == 1 && g2.menu && OutBool(r2, "resumeSent"),
          "dispatched cleanup Resume without verified closure");
    Check(OutStr(r2, "menuShownAfter") == "unknown" && OutBool(r2, "lateShowPossible")
          && string(r2["hint"]).IndexOf("GetPauseState") >= 0 && string(r2["error"]).IndexOf("observed closed") < 0,
          "unavailable after cleanup Resume is unknown, not closed");
    ''')


def test_r7_exceptions_after_show_use_one_cleanup_and_report_unknown(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.clockThrowsAfterShow = true;
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "tool_exception" && g.shows == 1 && g.closes == 1 && !g.menu, "clock threw; one cleanup Resume");
    Check(OutBool(r, "resumeAttempted") && OutBool(r, "resumeSent") && !OutBool(r, "menuShownAfter"), "closure read back");
    auto g2 = FakePauseGame(); g2.showThrowsAfterDispatch = true;
    g2.menuThrowsAfterResume = true;
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "CLEANUP_FAILED" && g2.shows == 1 && g2.closes == 1, "Show threw after dispatch");
    Check(OutStr(r2, "menuShownAfter") == "unknown" && OutBool(r2, "lateShowPossible"), "cleanup and reporting reads threw");
    Check(string(r2["error"]).IndexOf("observed closed") < 0, "must not claim closure");
    auto g3 = FakePauseGame(); g3.clockThrowsAfterShow = true; g3.resumeThrowsAfterDispatch = true;
    auto r3 = ControlPauseCore(g3, PauseInput("pause"));
    Check(g3.closes == 1 && OutBool(r3, "resumeAttempted") && !OutBool(r3, "resumeSent"), "throw after Resume dispatch is never retried");
    ''')


def test_r9_explicit_resume_rechecks_gate_at_dispatch(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto probe = FakePauseGame(); probe.menu = true;
    Check(Ok(ControlPauseCore(probe, PauseInput("resume"))), "resume boundary probe");
    auto g = FakePauseGame(); g.menu = true; g.goOnlineOnGateRead = int(probe.gateReadsAtFirstResume);
    auto r = ControlPauseCore(g, PauseInput("resume"));
    Check(Code(r) == "ONLINE_NOT_PAUSABLE" && g.closes == 0 && g.menu, "no Resume on last gate refusal");
    ''')
    # The runtime probe follows the call's actual read number. Pin the distinct
    # observation so the test does not adapt to deleting this redundant read.
    close = _strip_comments(CORE).split("Json::Value@ _PauseClose(", 1)[1]
    assert close.index("call.Observe();") < close.index("if (call.stop.Length > 0)") < close.index("call.Resume();")


def test_r10_missing_jump_is_unmeasured(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame(); g.menu = true;
    g.readable[1] = false;  // no readable baseline for all three clocks
    g.At(1700, "readable", 1);
    auto r = ControlPauseCore(g, PauseInput("resume"));
    Check(Ok(r) && g.closes == 1 && !r["output"]["jumpMs"].HasKey("coreSimulationTime"), "no fabricated jump");
    Check(OutStr(r, "jumpNote").IndexOf("unmeasured") >= 0, "explain absent measurement");
    ''')


def test_r11_pause_host_needs_no_logger(as_runner, tmp_path):
    # The fake implements the reduced interface, so the production core
    # compiles and runs with no Log method on the host.
    run_pause(as_runner, tmp_path, r'''
    auto g = FakePauseGame();
    Check(Ok(ControlPauseCore(g, PauseInput("pause"))), "pause without a logger");
    ''')
    fake = _strip_comments((ROOT / "tests/as_core_fakes.py").read_text()).split("class FakePauseGame", 1)[1]
    fake = fake.split("Json::Value@ PauseInput", 1)[0]
    assert "void Log(" not in _strip_comments(TOOLS)
    assert "void Log(" not in fake
