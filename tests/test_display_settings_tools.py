"""Get/Set/RestoreDisplaySetting (bloom): pure policy in stock AngelScript + source contracts.

No live game. DisplaySettingsPolicy.as runs in the stock AngelScript runner,
checked against the Python port below.

UNPROVEN live (2026-11-18): that FxBloomHdr=None applied at runtime removes
bloom without a restart (Q2), and that DisplaySettings_Apply neither resets the
window/device nor saves Default.json at once (Q3).
"""
import json
import re
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
POLICY = SRC / "DisplaySettingsPolicy.as"
TOOLS = (SRC / "DisplaySettingsTools.as").read_text()
MCP_TOOLS = (SRC / "McpTools.as").read_text()
MAIN = (SRC / "Main.as").read_text()

DISPLAY_TOOLS = ["GetDisplaySetting", "SetDisplaySetting", "RestoreDisplaySetting"]

# --- Python port of DisplaySettingsPolicy.as ---------------------------------

NAMES = ["none", "medium", "high"]


def normalize(raw):
    s = raw.strip()
    if s in ("none", "None", "NONE", "off", "Off"):
        return "none"
    if s in ("medium", "Medium", "MEDIUM"):
        return "medium"
    if s in ("high", "High", "HIGH"):
        return "high"
    return ""


def index(name):
    n = normalize(name)
    return NAMES.index(n) if n else -1


def restore_action(exists, recorded, current):
    if not exists:
        return "none"
    if not normalize(recorded):
        return "bad"
    if normalize(recorded) == normalize(current):
        return "clear"
    return "apply"


def mechanism(available, failed):
    return "wrapper" if available and not failed else "systemConfig"


def side_effects(db, da, mb, ma, xb, yb, xa, ya):
    out = []
    if db != da:
        out.append("dirtyCounter")
    if mb != ma:
        out.append("displayMode")
    if xb != xa or yb != ya:
        out.append("windowSize")
    return ",".join(out)


class RestoreRecordSim:
    """Keep-oldest record, as SetDisplaySetting uses ShouldWriteRestoreRecord."""

    def __init__(self):
        self.record = None

    def set(self, current, wanted):
        if self.record is None:  # ShouldWriteRestoreRecord(recordExists)
            self.record = current
        return wanted

    def restore(self, current):
        act = restore_action(self.record is not None, self.record or "", current)
        value = self.record if act == "apply" else current
        if act in ("apply", "clear"):
            self.record = None
        return act, value


# --- AngelScript runner --------------------------------------------------------


def run_policy(runner, tmp_path, body):
    case = tmp_path / "display_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def s(v):
    return json.dumps(v)


def b(v):
    return "true" if v else "false"


RAW = ["none", "None", "NONE", "off", "Off", "medium", "Medium", "MEDIUM", "high", "High", "HIGH",
       " high ", "", "low", "ultra", "1", "nOne"]


def test_bloom_names_and_indices(as_runner, tmp_path):
    lines = []
    for raw in RAW:
        lines.append(f"Check(NormalizeBloom({s(raw)}) == {s(normalize(raw))}, {s('norm ' + raw)});")
        lines.append(f"Check(BloomIndex({s(raw)}) == {index(raw)}, {s('index ' + raw)});")
    for i in range(-2, 5):
        exp = NAMES[i] if 0 <= i < 3 else ""
        lines.append(f"Check(BloomName({i}) == {s(exp)}, \"name {i}\");")
    # Both game enums are None, Medium, High in that order (checked in the 1.29.14 dump).
    lines.append('Check(BloomIndex("none") == 0 && BloomIndex("medium") == 1 && BloomIndex("high") == 2, "enum order");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_restore_record_keeps_oldest(as_runner, tmp_path):
    sim = RestoreRecordSim()
    cur = sim.set("high", "none")      # user's high recorded
    cur = sim.set(cur, "medium")       # second Set must not record the tool's own "none"
    assert sim.record == "high"
    act, cur = sim.restore(cur)
    assert (act, cur, sim.record) == ("apply", "high", None)
    assert sim.restore(cur) == ("none", "high")
    lines = [
        "Check(ShouldWriteRestoreRecord(false), \"first Set writes the record\");",
        "Check(!ShouldWriteRestoreRecord(true), \"later Sets keep the oldest\");",
    ]
    for exists in [False, True]:
        for recorded in ["high", "none", "medium", "", "garbage"]:
            for current in ["high", "none", "medium", ""]:
                exp = restore_action(exists, recorded, current)
                lines.append(f"Check(RestoreAction({b(exists)}, {s(recorded)}, {s(current)}) == {s(exp)}, "
                             f"{s(f'restore {exists}/{recorded}/{current}')});")
    lines.append('Check(RestoreAction(true, "garbage", "high") == "bad", "unreadable record is kept, nothing written");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_mechanism_and_verification(as_runner, tmp_path):
    lines = []
    for avail in [False, True]:
        for failed in [False, True]:
            lines.append(f"Check(ChooseBloomMechanism({b(avail)}, {b(failed)}) == {s(mechanism(avail, failed))}, "
                         f"\"mech {avail}/{failed}\");")
    lines.append('Check(ChooseBloomMechanism(true, false) == "wrapper", "wrapper first");')
    for read in range(0, 3):
        for matching in range(0, read + 1):
            exp = read > 0 and matching == read
            lines.append(f"Check(BloomWriteVerified({read}, {matching}) == {b(exp)}, \"verified {read}/{matching}\");")
    cases = [
        (1, 1, 1, 1, 800, 450, 800, 450),
        (1, 2, 1, 1, 800, 450, 800, 450),
        (1, 1, 0, 1, 800, 450, 800, 450),
        (1, 1, 1, 1, 800, 450, 1024, 450),
        (1, 2, 0, 2, 800, 450, 800, 576),
    ]
    for c in cases:
        exp = side_effects(*c)
        lines.append(f"Check(DisplaySideEffects({', '.join(str(x) for x in c)}) == {s(exp)}, {s('side ' + str(c))});")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


# --- Source contracts -----------------------------------------------------------


def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in text.splitlines())


def test_tools_registered_at_all_three_points():
    for name in DISPLAY_TOOLS:
        assert f'name == "{name}"' in MCP_TOOLS, f"{name} missing from IsToolName"
        assert f'if (name == "{name}") return {name}(input);' in MCP_TOOLS, f"{name} missing dispatch"
        assert f'MakeTool("{name}"' in MCP_TOOLS, f"{name} missing MakeTool"


def _schema(name):
    line = next(l for l in MCP_TOOLS.splitlines() if f'MakeTool("{name}"' in l)
    m = re.search(r"'(\{.*\})'\)\);\s*$", line)
    assert m, f"could not extract schema for {name}"
    return json.loads(m.group(1))


def test_schemas_are_closed():
    for name in DISPLAY_TOOLS:
        assert _schema(name)["additionalProperties"] is False, name
    s_ = _schema("SetDisplaySetting")
    assert s_["required"] == ["bloom"]
    assert set(s_["properties"]) == {"bloom"}
    assert s_["properties"]["bloom"]["enum"] == ["none", "medium", "high"]
    assert _schema("GetDisplaySetting")["properties"] == {}
    assert _schema("RestoreDisplaySetting")["properties"] == {}


def test_restore_record_written_before_any_bloom_write():
    body = _strip_comments(TOOLS)
    fn = body[body.index("Json::Value@ SetDisplaySetting("):body.index("Json::Value@ RestoreDisplaySettingCore(")]
    record = fn.index("_WriteDisplayRestoreRecord(")
    write = fn.index("_ApplyBloom(")
    assert record < write
    # A failed record write returns before anything is changed.
    between = fn[record:write]
    assert "RESTORE_RECORD_FAILED" in between
    # The only FxBloomHdr writes live in the two writer helpers, which only _ApplyBloom calls.
    writes = re.findall(r"FxBloomHdr\s*=(?!=)", body)
    assert len(writes) == 2, writes
    for helper in ["_WriteBloomWrapper(", "_WriteBloomSystemConfig("]:
        callers = [m.start() for m in re.finditer(re.escape(helper), body)]
        defs = [m.start() for m in re.finditer(r"bool " + re.escape(helper), body)]
        assert len(callers) - len(defs) == 1, helper  # called once, from _ApplyBloom
    apply_fn = body[body.index("bool _ApplyBloom("):body.index("Json::Value@ _BloomStateJson(")]
    assert "_WriteBloomWrapper(" in apply_fn and "_WriteBloomSystemConfig(" in apply_fn


def test_wrapper_first_with_system_config_fallback():
    body = _strip_comments(TOOLS)
    apply_fn = body[body.index("bool _ApplyBloom("):body.index("Json::Value@ _BloomStateJson(")]
    assert apply_fn.index("_WriteBloomWrapper(") < apply_fn.index("_WriteBloomSystemConfig(")
    assert "ChooseBloomMechanism(" in apply_fn
    assert 'output["mechanism"] = mechanism;' in body


def test_wrapper_apply_and_side_effect_watch():
    body = _strip_comments(TOOLS)
    w = body[body.index("bool _WriteBloomWrapper("):body.index("bool _WriteBloomSystemConfig(")]
    assert w.index("_WrapperBegin(") < w.index("FxBloomHdr =") < w.index("DisplaySettings_Apply()") < w.rindex("_WrapperEnd(")
    setfn = body[body.index("Json::Value@ SetDisplaySetting("):body.index("Json::Value@ RestoreDisplaySettingCore(")]
    assert setfn.index("_ReadDisplayWatch()") < setfn.index("_ApplyBloom(") < setfn.rindex("_ReadDisplayWatch()")
    for key in ["dirtyCounter", "displayMode", "windowSize"]:
        assert f'"{key}"' in body
    assert "DisplaySideEffects(" in setfn


def test_wrapper_never_unloaded_under_another_user():
    body = _strip_comments(TOOLS)
    assert body.count("DisplaySettings_LoadCurrent()") == 1
    assert body.count("DisplaySettings_Unload()") == 1
    begin = body[body.index("bool _WrapperBegin("):body.index("void _WrapperEnd(")]
    assert "if (!wasLoaded) api.DisplaySettings_LoadCurrent();" in begin
    assert "if (!wasLoaded) api.DisplaySettings_Unload();" in body


def test_restore_called_on_start_disable_and_unload():
    main = _strip_comments(MAIN)

    def fn_body(name):
        start = main.index(f"void {name}()")
        return main[start:main.index("}", start)]

    assert 'RestoreDisplaySettingOnLifecycle("start")' in fn_body("Main")
    assert 'RestoreDisplaySettingOnLifecycle("disable")' in fn_body("OnDisabled")
    assert 'RestoreDisplaySettingOnLifecycle("unload")' in fn_body("OnDestroyed")
    # Callbacks are not coroutines: only start may yield.
    assert 'RestoreDisplaySettingCore(when == "start")' in _strip_comments(TOOLS)


def test_restore_record_is_in_plugin_storage():
    assert 'const string DISPLAY_RESTORE_FILE = "display-restore.json";' in POLICY.read_text()
    assert "IO::FromStorageFolder(DISPLAY_RESTORE_FILE)" in TOOLS


def test_failed_apply_keeps_record():
    body = _strip_comments(TOOLS)
    core = body[body.index("Json::Value@ RestoreDisplaySettingCore("):body.index("Json::Value@ RestoreDisplaySetting(Json")]
    assert "if (ok) _DeleteDisplayRestoreRecord();" in core


def test_policy_file_has_no_game_types():
    policy = _strip_comments(POLICY.read_text())
    for banned in ["GetApp", "CGame", "CSystem", "yield", "IO::"]:
        assert banned not in policy, banned
