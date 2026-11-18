"""GetPauseState / ControlPause: policy, orchestration and source contracts.

No live game. The production PausePolicy.as runs in the stock AngelScript
runner against a Python port of the same rules. The production orchestration
(PauseCore.as: clock window, gate, ownership, cleanup, deadline) runs in the
same runner against a scripted fake game (tests/as_core_fakes.py), with a
regression for each review-1 finding F5-F10 (test_f5_..., test_f6_..., ...).

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


def watch_action(owned, call_active, same, menu, close_due, attempts):
    if not owned:
        return "stop"
    if call_active:
        return "skip"
    if not same:
        return "forget-context"
    if not menu:
        return "forget-closed"
    if not close_due:
        return "wait"
    return "give-up" if attempts >= 10 else "close"


def noop_timer(given, ms, owned):
    if not given:
        return "keep"
    if owned:
        return "update"
    return "refuse" if ms > 0 else "keep"


def budget(hold, timeout):
    return 3 * hold + timeout + 2000


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
    # The ownership watcher: ownership ends with the menu and with the context.
    for owned, active, same, menu, due, attempts in itertools.product(
            [False, True], [False, True], [False, True], [False, True], [False, True], [0, 10]):
        exp = watch_action(owned, active, same, menu, due, attempts)
        lines.append(f"Check(PauseWatchAction({as_bool(owned)}, {as_bool(active)}, {as_bool(same)}, {as_bool(menu)}, "
                     f"{as_bool(due)}, {attempts}) == {as_str(exp)}, \"watch {owned}/{active}/{same}/{menu}/{due}/{attempts}\");")
    for given, ms, owned in itertools.product([False, True], [0, 5000], [False, True]):
        exp = noop_timer(given, ms, owned)
        lines.append(f"Check(PauseNoopTimerAction({as_bool(given)}, {ms}, {as_bool(owned)}) == {as_str(exp)}, "
                     f"\"noop timer {given}/{ms}/{owned}\");")
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
    for hold in [100, 300, 2000]:
        for timeout in [100, 3000, 10000]:
            lines.append(f"Check(PauseCallBudgetMs({hold}, {timeout}) == {budget(hold, timeout)}, \"budget {hold}/{timeout}\");")
    lines.append("Check(PauseCallBudgetMs(2000, 10000) == 18000, \"worst-case budget\");")
    lines.append("Check(ClampAutoResumeMs(0, false) == 0, \"auto-resume is off by default\");")
    lines.append("Check(ClampAutoResumeMs(999999999, true) == 600000, \"auto-resume cap\");")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


# --- Production orchestration (PauseCore.as) on a fake game ---------------------
# Each scenario runs the real ControlPauseCore / GetPauseStateCore / PauseWatchStep
# with a scripted fake game: per-frame clocks, menu, gate, playground/handler ids.


def test_core_pause_resume_round_trip(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(r) && OutBool(r, "paused") && OutBool(r, "changed"), "paused: " + Code(r));
    Check(g.menu && g_pause.owned && g.shows >= 1, "menu up and owned");
    Check(g.closes == 0, "a good pause sends no Resume");
    auto again = ControlPauseCore(g, PauseInput("pause"));
    Check(Ok(again) && OutStr(again, "plan") == "noop" && !OutBool(again, "changed"), "idempotent pause");
    auto r2 = ControlPauseCore(g, PauseInput("resume"));
    Check(Ok(r2) && !g.menu && !g_pause.owned, "resumed and ownership ended: " + Code(r2));
    Check(r2["output"]["jumpMs"].HasKey("clientGameTime"), "jumpMs reported");
    ''')


def test_f5_clock_first_seen_late_is_not_frozen(as_runner, tmp_path):
    """Review 1 F5 case 1: a clock unreadable at the start and seen only at the end."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menu = true;                 // frozen by a menu
    g.readable[0] = false;         // client clock unreadable at the window start
    g.At(1500, "readable", 0);     // back with less than 300 ms of the 700 ms limit left
    auto r = GetPauseStateCore(g, SampleInput(300));
    Check(OutStr(r, "verdict") != "frozen", "a late clock never counts for the elapsed window");
    Check(int(r["output"]["windowMs"]) < 300, "the window only covers time with all three clocks");
    // The reviewer's exact probe, on the production window.
    auto w = PauseClockWindow();
    g.readable[0] = false; w.Observe(g, true);
    g.now += 300; g.readable[0] = true; w.Observe(g, true);
    Check(w.Verdict(300) != "frozen", "BUG F5a must not reproduce: late clock counted for the window");
    // A clock that comes back early enough gets a genuine full window.
    auto g2 = FakePauseGame();
    g2.menu = true; g2.readable[0] = false; g2.At(1050, "readable", 0);
    auto r2 = GetPauseStateCore(g2, SampleInput(300));
    Check(OutStr(r2, "verdict") == "frozen" && int(r2["output"]["windowMs"]) >= 300, "full coverage after it returns");
    ''')


def test_f5_moving_clock_that_disappears_is_not_frozen(as_runner, tmp_path):
    """Review 1 F5 case 2: a clock that changed, then became unreadable."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menu = true; g.menuFreezes = true;
    auto w = PauseClockWindow();
    w.Observe(g, true);
    g.now += 100; g.clocks[0] += 10; w.Observe(g, true);
    g.now += 200; g.readable[0] = false; w.Observe(g, true);
    Check(w.Verdict(300) != "frozen", "BUG F5b must not reproduce: moving clock excluded then frozen");
    g.readable[0] = true;
    for (uint i = 0; i < 40; i++) { g.now += 16; w.Observe(g, true); }
    Check(w.Verdict(300) == "frozen" && w.WindowMs() >= 300, "frozen again only after a fresh full window");
    ''')


def test_f5_loading_or_context_change_restarts_window(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menu = true;
    auto w = PauseClockWindow();
    for (uint i = 0; i < 15; i++) { g.now += 16; w.Observe(g, true); }
    w.Observe(g, false); // a loading frame / context change
    Check(!w.started && w.restarts == 1, "restart on a loading frame");
    g.now += 16; w.Observe(g, true);
    Check(w.WindowMs() == 0 && w.Verdict(300) != "frozen", "coverage starts again from zero");
    ''')


# Timing probes: run a clean call first to learn the fake time at which a
# phase ends, so an event can be placed in the one window a check covers.
SAMPLE_END_PROBE = r'''
    ResetPause();
    auto probe = FakePauseGame();
    probe.menu = true;                   // frozen: the sample runs its full holdMs
    auto pr = ControlPauseCore(probe, PauseInput("pause"));
    Check(OutStr(pr, "plan") == "noop", "probe is a noop");
    uint64 sampleEnd = probe.now;        // a noop returns right after the sample
'''


def test_f6_locality_change_during_initial_sample_never_shows(as_runner, tmp_path):
    """Review 1 F6: local -> online during the initial sample must not reach ShowInGameMenu."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.At(1100, "local", 0);
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "ONLINE_NOT_PAUSABLE", "stopped: " + Code(r));
    Check(g.shows == 0 && !g.menu && !g_pause.owned, "no menu call was made");
    ResetPause();
    auto g2 = FakePauseGame();
    g2.At(1100, "playground", 8);   // map change mid-sample
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(Code(r2) == "CONTEXT_CHANGED" && g2.shows == 0, "context change stops before any show");
    ResetPause();
    auto g3 = FakePauseGame();
    g3.At(1100, "loading", 1);
    auto r3 = ControlPauseCore(g3, PauseInput("pause"));
    Check(Code(r3) == "LOADING" && g3.shows == 0, "loading stops before any show");
    ''')


def test_f6_menu_closed_during_sample_is_not_a_noop(as_runner, tmp_path):
    """Review 1 F6: a menu closed during the initial sample must not take noop and claim paused."""
    run_pause(as_runner, tmp_path, SAMPLE_END_PROBE + r'''
    // Someone else's pause, frozen for the whole sample; the menu closes on
    // the sample's last frame, after the clocks already proved frozen.
    ResetPause();
    auto g = FakePauseGame();
    g.menu = true;
    g.At(sampleEnd, "menu", 0);
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!OutBool(r, "menuShownBefore"), "menu state is read after the sample");
    Check(OutStr(r, "plan") != "noop", "no noop for a menu that already closed: " + OutStr(r, "plan"));
    Check(!(Ok(r) && OutBool(r, "paused") && !g.menu), "never claims paused with no menu up");
    ''')


def test_f6_change_after_the_sample_is_caught_by_the_post_sample_recheck(as_runner, tmp_path):
    """The post-sample recheck alone. In the game nothing can change between the
    sampler's last per-frame check and this one (no yield between them), so the
    change is injected at the clock report that runs in between."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.goOnlineOnReport = 1;              // clocksBefore is the first report
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "ONLINE_NOT_PAUSABLE" && g.shows == 0, "stopped before any show: " + Code(r));
    Check(OutStr(r, "stoppedAt") == "before-action", "stopped before acting");
    ''')


def test_f6_change_on_last_sample_frame_never_shows(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, SAMPLE_END_PROBE + r'''
    ResetPause();
    auto g = FakePauseGame();
    g.At(sampleEnd, "local", 0);         // goes online on the last sample frame
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(Code(r) == "ONLINE_NOT_PAUSABLE" && g.shows == 0, "stopped before any show: " + Code(r));
    ''')


def test_f6_change_between_plan_and_show_is_caught_before_show(as_runner, tmp_path):
    """The check directly before ShowInGameMenu: nothing yields in between, so the
    change is injected through the host's own read, on the read just before the show."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.gateFlipAfterReads = 0;            // the first gate read after the post-sample dialog check = the pre-show check
    g.armGateFlipAtSampleEnd = true;
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(g.shows == 0, "no ShowInGameMenu after the gate changed: " + Code(r) + " shows=" + g.shows);
    Check(OutStr(r, "stoppedAt") == "before-action", "stopped before acting");
    Check(Code(r) == "ONLINE_NOT_PAUSABLE", "refused: " + Code(r));
    ''')


def test_f6_context_change_after_show_never_resumes_into_new_playground(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menuFreezes = false;              // menu opens, clocks keep running
    g.At(1500, "playground", 8);        // map changes while verifying
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "CONTEXT_CHANGED", "stopped on context change: " + Code(r));
    Check(g.closes == 0, "no Resume sent into another playground");
    Check(OutBool(r, "menuShown") == g.menu, "menuShown is the truth");
    g.Watch(3);
    Check(!g_pause.owned && g_pause.endedReason == "context-changed", "watcher drops ownership");
    ''')


def test_f6_success_return_rechecks_the_context(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    // Learn when a clean pause would finish, then flip the handler on the
    // frame before that, so only the final recheck can catch it.
    ResetPause();
    auto probe = FakePauseGame();
    uint64 t0 = probe.now;
    Check(Ok(ControlPauseCore(probe, PauseInput("pause"))), "probe pause");
    uint64 endAt = probe.now;
    ResetPause();
    auto g = FakePauseGame();
    g.At(endAt, "handler", 10);
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!(Ok(r) && OutBool(r, "paused")), "no success after the handler changed: " + Code(r));
    Check(Code(r) == "CONTEXT_CHANGED", "context change reported: " + Code(r));
    Check(g.closes == 0, "no Resume into the changed context");
    // The final recheck alone: the change is injected at the clock report
    // between the last window and the success return (reports: clocksBefore,
    // then the window's own).
    ResetPause();
    auto g2 = FakePauseGame();
    g2.goOnlineOnReport = 2;
    auto r2 = ControlPauseCore(g2, PauseInput("pause"));
    Check(!(Ok(r2) && OutBool(r2, "paused")), "no success claimed after the gate changed: " + Code(r2));
    Check(Code(r2) == "ONLINE_NOT_PAUSABLE", "reported: " + Code(r2));
    ''')


def test_f7_failed_cleanup_returns_cleanup_failed_with_truthful_state(as_runner, tmp_path):
    """Review 1 F7: an ignored Resume must not be reported as a rollback."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menuFreezes = false;     // not paused
    g.closeLagFrames = -1;     // Resume is ignored
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "CLEANUP_FAILED", "distinct code: " + Code(r));
    Check(OutBool(r, "menuShown") && g.menu, "menuShown is the truth");
    Check(!OutBool(r, "menuClosedAgain"), "no rollback claimed");
    Check(string(r["error"]).IndexOf("closed again") < 0, "message never says closed");
    Check(g_pause.owned && g_pause.closing, "ownership and pending recovery kept");
    Check(int(r["output"]["cleanupResumeCalls"]) >= 2, "Resume was retried");
    // The watcher keeps retrying; once the game answers, ownership ends.
    uint before = g.closes;
    g.Watch(40);
    Check(g.closes > before, "background Resume retries");
    g.closeLagFrames = 0;
    g.Watch(80);
    Check(!g.menu && !g_pause.owned, "closed by the retry, ownership ended");
    ''')


def test_f7_late_close_is_observed_before_reporting(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.menuFreezes = false;
    g.closeLagFrames = 5;      // Resume lands a few frames later
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "NOT_PAUSED", "not paused: " + Code(r));
    Check(OutBool(r, "menuClosedAgain") && !g.menu && !OutBool(r, "menuShown"), "closure observed");
    Check(!g_pause.owned, "ownership ended after the observed close");
    ''')


def test_f7_late_show_is_closed(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    g.showLagFrames = 1000;    // effectively never within timeoutMs
    auto r = ControlPauseCore(g, PauseInput("pause", 100, 100));
    Check(!Ok(r) && Code(r) == "MENU_NOT_SHOWN", "menu not shown: " + Code(r));
    Check(!g.menu, "nothing left open");
    ResetPause();
    auto g2 = FakePauseGame();
    g2.showLagFrames = 20;     // lands after timeoutMs but within the grace
    auto r2 = ControlPauseCore(g2, PauseInput("pause", 100, 100));
    Check(!g2.menu, "a late menu is closed: " + Code(r2));
    Check(g2.closes >= 1, "with Resume");
    ''')


def test_f7_shutdown_closes_owned_menu(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    Check(Ok(ControlPauseCore(g, PauseInput("pause"))), "paused");
    uint y = g.yields;
    Check(PauseCloseOwnedOnShutdown(g) == "closed", "closed on disable/unload");
    Check(g.yields == y, "lifecycle path never yields");
    Check(!g.menu && !g_pause.owned, "closed and forgotten");
    ResetPause();
    auto g2 = FakePauseGame();
    Check(Ok(ControlPauseCore(g2, PauseInput("pause"))), "paused 2");
    g2.closeLagFrames = -1;
    Check(PauseCloseOwnedOnShutdown(g2) == "resume-sent-unconfirmed", "unconfirmed is reported as such");
    ResetPause();
    auto g3 = FakePauseGame();
    g3.menu = true;            // someone else's menu
    Check(PauseCloseOwnedOnShutdown(g3) == "none" && g3.closes == 0, "never closes a menu it did not open");
    ''')


def test_f7_aborted_call_hands_menu_to_watcher(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    PauseGate@ ctx = g.ReadGate();
    PauseOwnershipBegin(g, ctx, g.now + 18000);
    g.ShowMenu();                       // the call died right after the show
    PauseCallAborted();
    g.Watch(5);
    Check(!g.menu && !g_pause.owned, "the watcher closed it");
    ResetPause();
    auto g2 = FakePauseGame();
    PauseOwnershipBegin(g2, g2.ReadGate(), g2.now + 500);
    g2.ShowMenu();                      // a worker killed without unwinding
    g2.Watch(60);                       // past the call's deadline
    Check(!g2.menu && !g_pause.owned, "expired call: menu closed");
    ''')


def test_f8_manual_resume_then_other_menu_is_never_closed_by_old_timer(as_runner, tmp_path):
    """Review 1 F8: the timer belongs to the menu it was set for."""
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    auto r = ControlPauseCore(g, PauseInput("pause", 300, 3000, 1000));
    Check(Ok(r) && g_pause.autoResumeMs == 1000, "paused with a 1s timer");
    g.menu = false;              // the player pressed ESC to resume
    g.Watch(2);
    Check(!g_pause.owned && g_pause.endedReason == "menu-closed", "ownership ends with the menu");
    g.menu = true;               // the player opens the menu again later
    uint c = g.closes;
    g.Watch(200);                // well past the old timer
    Check(g.menu && g.closes == c, "the old timer never closes someone else's menu");
    ''')


def test_f8_map_change_drops_timer(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    Check(Ok(ControlPauseCore(g, PauseInput("pause", 300, 3000, 1000))), "paused");
    g.playgroundId = 8; g.menu = true;   // a new map, a menu up there
    uint c = g.closes;
    g.Watch(200);
    Check(!g_pause.owned && g.closes == c && g.menu, "no close in the new playground");
    ''')


def test_f8_timer_fires_for_its_own_menu(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    Check(Ok(ControlPauseCore(g, PauseInput("pause", 300, 3000, 500))), "paused");
    g.Watch(20);
    Check(g.menu, "not before the timer");
    g.Watch(40);
    Check(!g.menu && !g_pause.owned, "timer resumed its own pause");
    ''')


def test_f8_noop_pause_updates_or_refuses_timer(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    Check(Ok(ControlPauseCore(g, PauseInput("pause"))), "paused, no timer");
    auto r = ControlPauseCore(g, PauseInput("pause", 300, 3000, 700));
    Check(Ok(r) && OutStr(r, "autoResume") == "update" && g_pause.autoResumeMs == 700, "noop installs the timer");
    auto off = ControlPauseCore(g, PauseInput("pause", 300, 3000, 0));
    Check(Ok(off) && g_pause.autoResumeMs == 0, "0 cancels it");
    ResetPause();
    auto o = FakePauseGame();
    o.menu = true;                       // someone else's pause
    auto r2 = ControlPauseCore(o, PauseInput("pause", 300, 3000, 700));
    Check(!Ok(r2) && Code(r2) == "AUTO_RESUME_NOT_OWNED", "refused on someone else's menu");
    Check(!g_pause.owned && o.menu && o.closes == 0, "nothing changed");
    auto r3 = ControlPauseCore(o, PauseInput("pause"));
    Check(Ok(r3) && OutStr(r3, "plan") == "noop", "a plain pause noop is still fine");
    ''')


def test_f9_dialog_after_initial_sample_refuses_before_show(as_runner, tmp_path):
    """Review 1 F9: a dialog that comes up during the sample is checked after it."""
    run_pause(as_runner, tmp_path, SAMPLE_END_PROBE + r'''
    ResetPause();
    auto g = FakePauseGame();
    g.At(1200, "dialog", 1);
    auto r = ControlPauseCore(g, PauseInput("pause"));
    Check(!Ok(r) && Code(r) == "DIALOG_BLOCKING" && g.shows == 0, "dialog after the sample: " + Code(r));
    // A resume is refused too (nothing closed behind a dialog).
    ResetPause();
    auto g2 = FakePauseGame();
    g2.menu = true;
    g2.At(sampleEnd, "dialog", 1);
    auto r2 = ControlPauseCore(g2, PauseInput("resume"));
    Check(Code(r2) == "DIALOG_BLOCKING" && g2.closes == 0 && g2.menu, "resume behind a dialog: " + Code(r2));
    ''')


def test_f10_one_deadline_bounds_every_failure_path(as_runner, tmp_path):
    """Review 1 F10: nothing in a call waits past budgetMs."""
    run_pause(as_runner, tmp_path, r'''
    array<int> holds = {100, 300, 2000};
    array<int> timeouts = {100, 3000, 10000};
    for (uint a = 0; a < holds.Length; a++) for (uint b = 0; b < timeouts.Length; b++) {
        for (uint mode = 0; mode < 4; mode++) {
            ResetPause();
            auto g = FakePauseGame();
            if (mode == 0) { g.menuFreezes = false; }                          // NOT_PAUSED + cleanup
            if (mode == 1) { g.menuFreezes = false; g.closeLagFrames = -1; }   // CLEANUP_FAILED
            if (mode == 2) { g.showLagFrames = -1; }                           // MENU_NOT_SHOWN
            if (mode == 3) { g.readable[1] = false; }                          // a clock never readable
            uint64 t0 = g.now;
            auto r = ControlPauseCore(g, PauseInput("pause", holds[a], timeouts[b]));
            uint budget = PauseCallBudgetMs(uint(holds[a]), uint(timeouts[b]));
            Check(int(r["output"]["budgetMs"]) == int(budget), "budget reported");
            Check(g.now - t0 <= uint64(budget) + 32, "pause " + holds[a] + "/" + timeouts[b] + " mode " + mode
                  + " took " + (g.now - t0) + " > " + budget);
            Check(!Ok(r), "every one of these fails");
            if (mode != 1) Check(!g.menu, "failure leaves no menu open (mode " + mode + ")");
        }
        ResetPause();
        auto rg = FakePauseGame();
        Check(Ok(ControlPauseCore(rg, PauseInput("pause", holds[a], timeouts[b]))), "pause ok");
        rg.closeLagFrames = -1;
        uint64 t1 = rg.now;
        auto rr = ControlPauseCore(rg, PauseInput("resume", holds[a], timeouts[b]));
        Check(Code(rr) == "MENU_SUBPAGE_OPEN", "resume stuck: " + Code(rr));
        Check(rg.now - t1 <= uint64(PauseCallBudgetMs(uint(holds[a]), uint(timeouts[b]))) + 32, "resume bounded");
    }
    ''')


def test_get_pause_state_is_read_only(as_runner, tmp_path):
    run_pause(as_runner, tmp_path, r'''
    ResetPause();
    auto g = FakePauseGame();
    auto r = GetPauseStateCore(g, SampleInput(300));
    Check(Ok(r) && OutStr(r, "verdict") == "running", "running");
    Check(g.shows == 0 && g.closes == 0, "read-only");
    g.menu = true;
    auto r2 = GetPauseStateCore(g, SampleInput(300));
    Check(OutStr(r2, "verdict") == "frozen" && string(r2["output"]["ownership"]["openedBy"]) == "other", "frozen, other");
    ''')


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
    code = _strip_comments(TOOLS) + _strip_comments(CORE) + _strip_comments(POLICY.read_text())
    for r in FORBIDDEN_RESULTS:
        assert f"EInGameMenuResult::{r}" not in code, f"{r} must never be used by the pause tools"
    # Exactly one close call and one show call, both in the live host.
    calls = re.findall(r"\.CloseInGameMenu\(([^)]*)\)", code)
    assert calls == ["CGameScriptHandlerPlaygroundInterface::EInGameMenuResult::Resume"], calls
    assert len(re.findall(r"\.ShowInGameMenu\(\)", code)) == 1
    assert not re.search(r"\.(ShowInGameMenu|CloseInGameMenu)\(", _strip_comments(CORE)), "the core calls the host only"


def test_locality_gate_runs_before_show_in_game_menu():
    core = _strip_comments(CORE)
    fn = core[core.index("Json::Value@ ControlPauseCore("):]
    assert fn.index("ctx.Refusal()") < fn.index("if (refusal.Length > 0)") < fn.index("PauseSampleWindow(")
    opener = core[core.index("Json::Value@ _PauseOpen("):]
    assert opener.index("PauseContextStop(host, ctx, true)") < opener.index("host.ShowMenu()")
    assert opener.index("PauseOwnershipBegin(") < opener.index("host.ShowMenu()"), "ownership before the show (F7)"


def test_verdict_never_comes_from_menu_flag():
    """IsServerOrSolo is reported only; the pause verdict is the clocks."""
    tools = _strip_comments(TOOLS)
    assert "IsServerOrSolo" in tools
    core = _strip_comments(CORE)
    gate_call = re.search(r"PauseRefusalCode\(([^)]*)\)", core).group(1)
    assert "serverOrSolo" not in gate_call
    assert "PauseVerdict(" in core


def test_auto_resume_is_off_by_default_and_watched():
    tools = _strip_comments(TOOLS)
    assert "while (PauseWatchStep(g_livePauseHost)) yield();" in tools
    assert "void StartWatcher() { startnew(_PauseWatchCoro); }" in tools


def test_no_os_input_mlhook_or_raw_memory():
    body = _strip_comments(TOOLS) + _strip_comments(CORE)
    for banned in ["Dev::", "MLHook::", "RunManialinkScript", "SendKey", "VirtualKey", "IO::"]:
        assert banned not in body, banned


def test_policy_and_core_have_no_game_types():
    for text in [POLICY.read_text(), CORE]:
        body = _strip_comments(text)
        for banned in ["GetApp", "CGame", "CMw", "yield", "Time::", "startnew", "GetCmdBufferCore"]:
            assert banned not in body, banned


def test_lifecycle_closes_owned_menu():
    main = _strip_comments((SRC / "Main.as").read_text())
    for fn, when in [("OnDisabled", "disable"), ("OnDestroyed", "unload")]:
        start = main.index(f"void {fn}()")
        assert f'ClosePauseOnLifecycle("{when}")' in main[start:main.index("}", start)]
    assert "PauseCloseOwnedOnShutdown(" in _strip_comments(TOOLS)


def test_live_host_contexts_hold_no_engine_reference():
    tools = _strip_comments(TOOLS)
    assert "MwAddRef" not in tools and "MwRelease" not in tools


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
