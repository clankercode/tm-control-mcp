"""Editor camera animation: pure policy in stock AngelScript (easing, angle
unwrap, spline sampling, path timing, drift detection, wait timeout), plus
source contracts for the game side (registration, interruption by other
camera tools, the 5-minute wait cap, the wait's tool-call budget).

Live check: tools/verify notes in CHANGELOG; run on a leased instance.
"""
import re
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "EditorCameraAnimPolicy.as"


def run_policy(runner, tmp_path, body):
    case = tmp_path / "camera_anim_case.as"
    case.write_text(
        "bool Near(float a, float b, float tol = 0.001) { float d = a - b; return d < tol && d > -tol; }\n"
        "void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_easing(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<string> names = {"linear", "in", "out", "inOut"};
    for (uint i = 0; i < names.Length; i++) {
        Check(CamEaseKnown(names[i]), "known " + names[i]);
        Check(Near(CamEase(names[i], 0.0), 0.0) && Near(CamEase(names[i], 1.0), 1.0), "endpoints " + names[i]);
        Check(Near(CamEase(names[i], -1.0), 0.0) && Near(CamEase(names[i], 2.0), 1.0), "clamped " + names[i]);
    }
    Check(!CamEaseKnown("bounce"), "unknown easing");
    Check(Near(CamEase("linear", 0.25), 0.25), "linear");
    Check(Near(CamEase("inOut", 0.5), 0.5), "inOut symmetric");
    Check(CamEase("inOut", 0.1) < 0.1 && CamEase("inOut", 0.9) > 0.9, "inOut starts and ends slow");
    Check(CamEase("in", 0.5) < 0.5 && CamEase("out", 0.5) > 0.5, "in slow start, out slow end");
    ''')


def test_angle_wrap_and_unwrap(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(Near(CamWrapAngle(0.0), 0.0), "zero");
    Check(Near(CamWrapAngle(CAM_TAU + 0.5), 0.5), "wrap +tau");
    Check(Near(CamWrapAngle(-CAM_TAU - 0.5), -0.5), "wrap -tau");
    Check(Near(CamWrapAngle(CAM_PI), CAM_PI) && Near(CamWrapAngle(-CAM_PI), CAM_PI), "(-pi, pi]");
    Check(Near(CamWrapAngle(7.0 * CAM_TAU + 1.0), 1.0), "many turns");
    // 350deg -> 10deg goes the short way: unwrap 10deg near 350deg = 370deg.
    float a = 350.0 * CAM_PI / 180.0, b = 10.0 * CAM_PI / 180.0;
    Check(Near(CamUnwrapNear(b, a), 370.0 * CAM_PI / 180.0), "short way round");
    Check(Near(CamAngleDelta(a, b), 20.0 * CAM_PI / 180.0), "delta across wrap");
    array<float> ch = {3.0, -3.0, 3.0};
    CamUnwrapChannel(ch);
    Check(Near(ch[1], 2.0 * CAM_PI - 3.0) && Near(ch[2], 3.0), "channel unwrap keeps segments short");
    ''')


def test_spline_and_linear_sampling(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<float> k = {0.0, 10.0, 20.0, 40.0};
    for (uint s = 0; s < 3; s++) {
        Check(Near(CamSampleChannel(k, s, 0.0, true), k[s]), "spline passes key " + s);
        Check(Near(CamSampleChannel(k, s, 1.0, true), k[s + 1]), "spline passes key " + (s + 1));
    }
    Check(Near(CamSampleChannel(k, 0, 0.5, false), 5.0), "linear midpoint");
    array<float> flat = {5.0, 5.0, 5.0};
    Check(Near(CamSampleChannel(flat, 0, 0.3, true), 5.0) && Near(CamSampleChannel(flat, 1, 0.7, true), 5.0), "no overshoot on flat keys");
    array<float> two = {0.0, 10.0};
    Check(Near(CamSampleChannel(two, 0, 0.5, true), 5.0), "two keys: spline is the straight segment");
    array<float> one = {7.0};
    Check(Near(CamSampleChannel(one, 0, 0.5, true), 7.0), "single key");
    Check(Near(CamSampleChannel(k, 9, 0.5, true), 40.0), "past end clamps to last key");
    ''')


def test_path_locate_and_split(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<int> seg = {1000, 0, 2000};
    uint s; float t;
    Check(CamPathLocate(seg, 0.0, s, t) && s == 0 && Near(t, 0.0), "start");
    Check(CamPathLocate(seg, 500.0, s, t) && s == 0 && Near(t, 0.5), "mid first");
    Check(CamPathLocate(seg, 1000.0, s, t) && s == 2 && Near(t, 0.0), "zero-length segment skipped");
    Check(CamPathLocate(seg, 2000.0, s, t) && s == 2 && Near(t, 0.5), "mid last");
    Check(!CamPathLocate(seg, 3000.0, s, t) && s == 2 && Near(t, 1.0), "end reached");
    Check(CamPathTotalMs(seg) == 3000, "total");
    array<float> w = {1.0, 3.0};
    auto d = CamSplitDuration(4000, w);
    Check(d.Length == 2 && d[0] == 1000 && d[1] == 3000, "proportional split");
    array<float> z = {0.0, 0.0, 0.0};
    auto e = CamSplitDuration(3000, z);
    Check(e.Length == 3 && e[0] + e[1] + e[2] == 3000 && e[0] == 1000, "even split when no weights");
    array<float> odd = {1.0, 1.0, 1.0};
    auto f = CamSplitDuration(1000, odd);
    Check(f[0] + f[1] + f[2] == 1000, "split sums exactly");
    ''')


def test_drift_detection(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(CamDriftReason(0,0,0,100,0,0.5, 0,0,0,100,0,0.5, 0.5,0.01) == "", "unchanged");
    Check(CamDriftReason(0,0,0,100,0,0.5, 0.2,0,0,100,0,0.5, 0.5,0.01) == "", "within tolerance");
    Check(CamDriftReason(0,0,0,100,0,0.5, 5,0,0,100,0,0.5, 0.5,0.01) == "target", "target moved");
    Check(CamDriftReason(0,0,0,100,0,0.5, 0,0,0,140,0,0.5, 0.5,0.01) == "distance", "zoomed");
    Check(CamDriftReason(0,0,0,100,0,0.5, 0,0,0,100,0.3,0.5, 0.5,0.01) == "angle", "rotated");
    Check(CamDriftReason(0,0,0,100,CAM_PI,0.5, 0,0,0,100,-CAM_PI,0.5, 0.5,0.01) == "", "wrapped angle is not drift");
    ''')


def test_wait_timeout(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(CamWaitTimeoutMs(true, 1000, true, 99999) == 1000, "explicit");
    Check(CamWaitTimeoutMs(true, 900000, false, 0) == 300000, "explicit capped at 5 min");
    Check(CamWaitTimeoutMs(true, -5, true, 0) == 0, "negative is an immediate check");
    Check(CamWaitTimeoutMs(false, 0, true, 4000) == 6000, "default waits out the animation plus slack");
    Check(CamWaitTimeoutMs(false, 0, true, 9999999) == 300000, "default capped");
    Check(CamWaitTimeoutMs(false, 0, false, 0) == 20000, "unbounded animation default");
    Check(CamAnimStateOk("completed") && !CamAnimStateOk("interrupted") && !CamAnimStateOk("stopped"), "only completed is ok");
    Check(CamAnimStateFinal("interrupted") && !CamAnimStateFinal("running"), "final states");
    ''')


SRC = ROOT / "src"
ANIM = (SRC / "EditorCameraAnim.as").read_text()
TOOLS = (SRC / "McpTools.as").read_text()


def _tool_schema(name):
    m = re.search(r'MakeTool\("' + name + r'", "(?:[^"\\]|\\.)*", \'([^\']*)\'\)', TOOLS)
    assert m, name
    return m.group(1)


def test_tools_registered_at_all_three_points():
    for name in ("AnimateEditorCamera", "WaitEditorCamera", "MaxFPS"):
        assert f'|| name == "{name}"' in TOOLS, f"{name} in the tool-name list"
        assert f'if (name == "{name}") return {name}(input);' in TOOLS, f"{name} dispatched"
        assert f'MakeTool("{name}"' in TOOLS, f"{name} in the catalog"
    assert '"timeoutMs":{"type":"integer"}' in _tool_schema("WaitEditorCamera")
    assert '"keyframes":{"type":"array"' in _tool_schema("AnimateEditorCamera")


def test_other_camera_tools_interrupt_a_running_animation():
    set_cam = TOOLS[TOOLS.index("Json::Value@ SetEditorCamera("):TOOLS.index("Json::Value@ ControlCamera(")]
    assert set_cam.index('CameraAnimInterrupt("SetEditorCamera")') < set_cam.index("pmt.CameraTargetPosition = target")
    control = TOOLS[TOOLS.index("Json::Value@ ControlCamera("):]
    assert 'CameraAnimInterrupt("ControlCamera " + action)' in control[:control.index("bool smooth")], \
        "every non-status ControlCamera action interrupts"
    shot = TOOLS[TOOLS.index("Json::Value@ TakeScreenshot("):]
    assert shot.index('CameraAnimInterrupt("TakeScreenshot focus")') < shot.index("pmt.CameraTargetPosition = target")
    assert 'CameraAnimInterrupt("SetEditorOrbitalTarget")' in (SRC / "BuiltinCamera.as").read_text()


def test_tick_detects_external_moves_and_mode_changes_before_writing():
    tick = ANIM[ANIM.index("bool CameraAnimTick("):ANIM.index("void CameraAnimLoop(")]
    assert tick.index("EditorCameraBlockReason") < tick.index("CamWrite(")
    assert tick.index("CamDriftReason(") < tick.index("CamWrite("), "drift is checked against the last write first"
    assert "v = Math::Clamp(v, a.vMin, a.vMax);" in tick, "the editor clamps vAngle, so writes must too"


def test_wait_is_capped_and_reports_interruptions_as_errors():
    wait = ANIM[ANIM.index("Json::Value@ WaitEditorCamera("):]
    assert "CamWaitTimeoutMs(" in wait
    assert '"CAMERA_ANIM_INTERRUPTED"' in wait and "CamAnimStateOk(a.state)" in wait
    assert 'info["timedOut"] = true;' in wait
    calls = (SRC / "ToolCalls.as").read_text()
    assert 'name == "WaitEditorCamera" ? 330000' in calls, "call budget must outlast the 5-minute wait"


def test_new_animation_replaces_the_running_one():
    start = ANIM[ANIM.index("a.id = g_camAnimNextId++;"):ANIM.index("Json::Value@ WaitEditorCamera(")]
    assert start.index("CameraAnimEnd(g_camAnimActive, \"interrupted\"") < start.index("@g_camAnimActive = a;")


def test_max_fps_bounds_and_session_only_write():
    src = (SRC / "MaxFps.as").read_text()
    assert "cfg.Display.MaxFps = uint(fps);" in src
    assert "const uint MAX_FPS_MIN = 10;" in src and "const uint MAX_FPS_MAX = 1000;" in src
    assert "if (fps == 0) return \"\";" in src, "0 means uncapped"


def test_review_fixes_are_pinned():
    control = TOOLS[TOOLS.index("Json::Value@ ControlCamera("):]
    assert "if (ControlCameraMovesCamera(action)) CameraAnimInterrupt(" in control, \
        "an unknown ControlCamera action must not kill a running animation"
    assert "ms > CAM_ANIM_MAX_MS" in ANIM, "per-key ms is bounded so the int sum cannot overflow"
    assert "a.wH = CamWrapAngle(h);" in ANIM, "drift reference stays small on long spins"
    start = ANIM[ANIM.index("if (!g_camAnimLoopRunning) {"):]
    assert start.index("g_camAnimLoopRunning = true;") < start.index("startnew(CoroutineFunc(CameraAnimLoop))"), \
        "flag set before startnew so two starts in one frame spawn one loop"
    loop = ANIM[ANIM.index("void CameraAnimLoop()"):ANIM.index("// ---- tool entry points ----")]
    assert "g_camAnimLoopRunning = true;" not in loop
    forever = ANIM[ANIM.index('a.oRate = CamNum(input, "degreesPerSecond", 20.0);'):]
    assert forever.index("degreesPerSecond must be non-zero") < forever.index("a.durationMs = -1;")
