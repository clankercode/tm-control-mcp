"""Get/Set/RestoreDisplaySetting (bloom): policy, orchestration and source contracts.

No live game. DisplaySettingsPolicy.as runs in the stock AngelScript runner
against the Python port below. The production orchestration
(DisplaySettingsCore.as: record IO, identity, wrapper ownership, restore) runs
in the same runner against a fake game and a fake disk (tests/as_core_fakes.py),
with a regression for each review-1 finding F1-F4 (test_f1_..., ...).

UNPROVEN live (2026-11-18): that FxBloomHdr=None applied at runtime removes
bloom without a restart (Q2), and that DisplaySettings_Apply neither resets the
window/device nor saves Default.json at once (Q3).
"""
import itertools
import json
import re
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)
from as_core_fakes import run_display

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
POLICY = SRC / "DisplaySettingsPolicy.as"
TOOLS = (SRC / "DisplaySettingsTools.as").read_text()
CORE = (SRC / "DisplaySettingsCore.as").read_text()
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


def restore_decision(identity_ok, sources, prior, applied, force):
    readable = [v for v in sources if v in NAMES]
    if not readable:
        return "unavailable"
    if not identity_ok and not force:
        return "conflict-identity"
    if all(v == prior for v in readable):
        return "clear"
    if any(v != prior and v not in applied for v in readable) and not force:
        return "conflict-value"
    return "apply"


def set_conflict(identity_ok, current, prior, applied):
    if not identity_ok:
        return "identity"
    if current != prior and current not in applied:
        return "value"
    return ""


def mechanism(available, busy, failed):
    return "wrapper" if available and not busy and not failed else "systemConfig"


def side_effects(db, da, mb, ma, xb, yb, xa, ya):
    out = []
    if db != da:
        out.append("dirtyCounter")
    if mb != ma:
        out.append("displayMode")
    if xb != xa or yb != ya:
        out.append("windowSize")
    return ",".join(out)


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


def as_arr(values):
    return "{" + ", ".join(s(v) for v in values) + "}"


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


def test_restore_decision_matrix(as_runner, tmp_path):
    lines = []
    values = ["none", "medium", "high", ""]
    applied_sets = [["none"], ["none", "medium"]]
    for ident, w, c, prior, applied, force in itertools.product(
            [False, True], values, values, ["high", "none"], applied_sets, [False, True]):
        exp = restore_decision(ident, [w, c], prior, applied, force)
        lines.append(f"{{ array<string> src = {as_arr([w, c])}; array<string> ap = {as_arr(applied)};"
                     f" Check(RestoreDecision({b(ident)}, src, {s(prior)}, ap, {b(force)}) == {s(exp)},"
                     f" {s(f'decide {ident}/{w}/{c}/{prior}/{applied}/{force}')}); }}")
    for ident, cur, prior, applied in itertools.product([False, True], ["none", "medium", "high"], ["high", "none"],
                                                        applied_sets):
        exp = set_conflict(ident, cur, prior, applied)
        lines.append(f"{{ array<string> ap = {as_arr(applied)};"
                     f" Check(SetRecordConflict({b(ident)}, {s(cur)}, {s(prior)}, ap) == {s(exp)},"
                     f" {s(f'set {ident}/{cur}/{prior}/{applied}')}); }}")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_record_format_round_trip_and_rejects(as_runner, tmp_path):
    ident = "ab" * 32
    run_policy(as_runner, tmp_path, rf'''
    auto r = DisplayRecord();
    r.prior = "high"; r.applied.InsertLast("none"); r.applied.InsertLast("medium");
    r.identity = "{ident}"; r.setAt = "2026-11-18 19:00:00";
    string text = DisplayRecordText(r);
    string why;
    auto back = ParseDisplayRecord(text, why);
    Check(back !is null && DisplayRecordsEqual(back, r), "round trip: " + why);
    Check(ParseDisplayRecord(text.SubStr(0, text.Length - 7), why) is null, "truncated: no end=ok");
    Check(ParseDisplayRecord(text.SubStr(0, text.Length / 2), why) is null, "half a file");
    Check(ParseDisplayRecord("", why) is null, "empty");
    Check(ParseDisplayRecord(text.Replace("prior=high", "prior=ultra"), why) is null, "bad prior");
    Check(ParseDisplayRecord(text.Replace("schema=2", "schema=1"), why) is null, "old schema");
    Check(ParseDisplayRecord(text.Replace("applied=none,medium", "applied="), why) is null, "empty applied");
    Check(ParseDisplayRecord(text.Replace("identity={ident}", "identity=C:/users/x"), why) is null, "raw path identity");
    Check(ParseDisplayRecord(text + "prior=none\n", why) is null, "content after end");
    Check(ParseDisplayRecord(text.Replace("setting=bloom", "setting=bloom\nprior=none"), why) is null, "duplicate key");
    Check(ParseDisplayRecord("{{\"bloom\":\"high\"}}", why) is null, "the old JSON record is not valid here");
    ''')


def test_mechanism_and_verification(as_runner, tmp_path):
    lines = []
    for avail, busy, failed in itertools.product([False, True], repeat=3):
        lines.append(f"Check(ChooseBloomMechanism({b(avail)}, {b(busy)}, {b(failed)}) == {s(mechanism(avail, busy, failed))}, "
                     f"\"mech {avail}/{busy}/{failed}\");")
    lines.append('Check(ChooseBloomMechanism(true, false, false) == "wrapper", "wrapper first");')
    lines.append('Check(ChooseBloomMechanism(true, true, false) == "systemConfig", "never someone else\'s wrapper");')
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


# --- Production orchestration (DisplaySettingsCore.as) on a fake game + disk ----

ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_ID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


def test_core_set_restore_round_trip_keeps_oldest(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();               // user's bloom: high
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Ok(r) && g.systemConfig == 0 && OutStr(r, "restoreRecord") == "written", "set none: " + Code(r));
    Check(g.unloads == g.loads, "every wrapper this tool loaded was unloaded");
    auto r2 = SetDisplaySettingCore(g, BloomInput("medium"));
    Check(Ok(r2) && g.systemConfig == 1 && OutStr(r2, "restoreTo") == "high", "second set keeps the oldest prior");
    Check(g.Record().IndexOf("applied=none,medium") >= 0, "applied values recorded");
    auto o = RestoreDisplaySettingCore(g, true, false);
    Check(bool(o["restored"]) && string(o["action"]) == "apply" && g.systemConfig == 2, "restored to high");
    Check(!g.HasRecord() && !g.disk.Has(DISPLAY_RESTORE_NEXT_FILE), "record and side file gone");
    auto none = RestoreDisplaySettingCore(g, true, false);
    Check(string(none["action"]) == "none", "nothing left to restore");
    ''')


def test_f1_corrupt_record_refuses_set_and_changes_nothing(as_runner, tmp_path):
    """Review 1 F1: a truncated record must not become permission to write."""
    run_display(as_runner, tmp_path, rf'''
    auto g = FakeDisplayGame();
    string good = MakeRecordText("medium", "none", "{ID}");
    g.disk.Put(DISPLAY_RESTORE_FILE, good.SubStr(0, good.Length / 2));
    string before = g.Record();
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(!Ok(r) && Code(r) == "RESTORE_RECORD_INVALID", "refused: " + Code(r));
    Check(g.systemConfig == 2 && g.applies == 0 && g.scWrites == 0, "bloom untouched");
    Check(g.Record() == before, "the record is untouched for a person to inspect");
    g.disk.Put(DISPLAY_RESTORE_FILE, "{{\"bloom\":\"high\",\"setAt\"");
    auto r2 = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(r2) == "RESTORE_RECORD_INVALID" && g.systemConfig == 2, "truncated JSON too");
    auto o = RestoreDisplaySettingCore(g, true, false);
    Check(string(o["action"]) == "invalid" && !bool(o["restored"]) && g.HasRecord(), "restore keeps it");
    ''')


def test_f1_new_record_is_verified_before_the_bloom_write(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.disk.truncateWrites = true;             // the disk stores a short copy
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(!Ok(r) && Code(r) == "RESTORE_RECORD_FAILED", "read-back caught it: " + Code(r));
    Check(g.systemConfig == 2 && g.applies == 0 && g.scWrites == 0, "no bloom write");
    Check(!g.HasRecord() && !g.disk.Has(DISPLAY_RESTORE_NEXT_FILE), "nothing half-written left behind");
    auto g2 = FakeDisplayGame();
    g2.disk.fail.InsertLast("write:" + DISPLAY_RESTORE_NEXT_FILE);
    Check(Code(SetDisplaySettingCore(g2, BloomInput("none"))) == "RESTORE_RECORD_FAILED" && g2.systemConfig == 2, "write failure");
    auto g3 = FakeDisplayGame();
    g3.disk.fail.InsertLast("move:" + DISPLAY_RESTORE_NEXT_FILE);
    Check(Code(SetDisplaySettingCore(g3, BloomInput("none"))) == "RESTORE_RECORD_FAILED" && g3.systemConfig == 2, "move failure");
    // A crash after the old record was deleted but before the move: the checked
    // side file is adopted, so recovery is not lost.
    auto g4 = FakeDisplayGame();
    g4.systemConfig = 0;
    g4.disk.Put(DISPLAY_RESTORE_NEXT_FILE, MakeRecordText("high", "none", g4.identity));
    auto o = RestoreDisplaySettingCore(g4, true, false);
    Check(bool(o["restored"]) && g4.systemConfig == 2, "side file adopted and restored");
    ''')


def test_f2_record_from_another_install_is_never_applied_automatically(as_runner, tmp_path):
    """Review 1 F2: plugin storage copied/overlaid from another install or profile."""
    run_display(as_runner, tmp_path, rf'''
    auto g = FakeDisplayGame();
    g.systemConfig = 0;                       // this user's own choice: none
    g.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("high", "none", "{OTHER_ID}"));
    auto o = RestoreDisplaySettingOnLifecycleCore(g, "start");
    Check(string(o["action"]) == "conflict-identity" && !bool(o["restored"]), "conflict");
    Check(g.systemConfig == 0 && g.scWrites == 0 && g.applies == 0, "this user's value untouched");
    Check(g.HasRecord(), "record kept");
    auto get = GetDisplaySettingCore(g);
    Check(string(get["output"]["pendingRestore"]["restoreWouldDo"]) == "conflict-identity", "reported by Get");
    auto t = RestoreDisplaySettingTool(g, NoInput());
    Check(!Ok(t) && Code(t) == "RESTORE_CONFLICT" && g.systemConfig == 0, "explicit restore also refuses");
    auto s1 = SetDisplaySettingCore(g, BloomInput("medium"));
    Check(!Ok(s1) && Code(s1) == "RESTORE_CONFLICT" && g.systemConfig == 0, "set refuses too");
    auto f = RestoreDisplaySettingTool(g, ForceInput(true));
    Check(Ok(f) && g.systemConfig == 2 && !g.HasRecord(), "force:true applies it on request");
    ''')


def test_f2_value_changed_by_someone_else_is_a_conflict(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    g.systemConfig = 1;                       // the user picked medium in the settings page
    auto o = RestoreDisplaySettingOnLifecycleCore(g, "unload");
    Check(string(o["action"]) == "conflict-value" && g.systemConfig == 1, "never overwritten");
    Check(g.HasRecord(), "record kept");
    auto s1 = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(s1) == "RESTORE_CONFLICT" && g.systemConfig == 1, "set refuses on a changed value");
    ''')


def test_f2_lifecycle_restore_never_yields_on_callbacks(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set");
    uint y = g.yields;
    auto o = RestoreDisplaySettingOnLifecycleCore(g, "disable");
    Check(bool(o["restored"]) && g.systemConfig == 2, "restored on disable");
    Check(g.yields == y, "disable/unload are callbacks: no yield");
    Check(RestoreDisplaySettingOnLifecycleCore(g, "unload") is null, "nothing pending");
    ''')


def test_f3_wrapper_loaded_by_someone_else_is_never_applied(as_runner, tmp_path):
    """Review 1 F3: the settings page has the wrapper loaded with unsaved edits."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.otherLoaded = true; g.otherWrapperValue = 2; g.otherPendingMode = 3;
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(!Ok(r) && Code(r) == "WRAPPER_BUSY", "refused: " + Code(r));
    Check(!g.applyOnOtherWrapper && g.appliedMode == 0 && g.scWrites == 0 && !g.HasRecord(), "nothing written");
    // Restore while someone else holds it: the direct path, never their Apply.
    g.otherLoaded = false;
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set when free");
    g.otherLoaded = true; g.otherWrapperValue = 2;   // their copy already shows high
    auto o = RestoreDisplaySettingCore(g, true, false);
    Check(!g.applyOnOtherWrapper && g.appliedMode == 0, "their wrapper was never applied");
    Check(string(o["mechanism"]) == "systemConfig" && g.systemConfig == 2, "direct write used");
    Check(bool(o["restored"]) && !g.HasRecord(), "both sources read high: done");
    ''')


def test_f3_restore_never_applies_a_busy_wrapper_even_if_load_would_allow(as_runner, tmp_path):
    """The core's own rule, with no help from the host refusing the load."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    g.otherLoaded = true; g.otherWrapperValue = 2; g.otherPendingMode = 3;
    g.strictLoad = false;                // LoadCurrent would not refuse here
    uint appliesBefore = g.applies;      // Set's own apply ran before anyone else loaded it
    auto o = RestoreDisplaySettingCore(g, true, false);
    Check(!g.applyOnOtherWrapper && g.appliedMode == 0, "someone else's wrapper never applied");
    Check(g.applies == appliesBefore && g.loads == g.unloads, "restore applied no wrapper at all");
    Check(string(o["mechanism"]) == "systemConfig", "direct write only");
    ''')


def test_f3_wrapper_released_on_error_paths(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.wrapperApplyFails = true;
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(g.loads == g.unloads && !g.ourLoaded, "unloaded after a failed apply");
    Check(string(r["output"]["mechanism"]) == "systemConfig", "fell back");
    ''')


def test_f4_restore_keeps_record_until_every_source_agrees(as_runner, tmp_path):
    """Review 1 F4: runtime already back but the loaded wrapper still holds the tool's value."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    g.systemConfig = 2;                        // runtime is back to high
    g.otherLoaded = true; g.otherWrapperValue = 0;   // a loaded wrapper still says none
    auto o = RestoreDisplaySettingCore(g, true, false);
    Check(!bool(o["restored"]) && g.HasRecord(), "record kept while the wrapper disagrees");
    Check(!g.applyOnOtherWrapper, "their wrapper never applied");
    auto t = RestoreDisplaySettingTool(g, NoInput());
    Check(!Ok(t) && Code(t) == "RESTORE_FAILED", "explicit restore reports RESTORE_FAILED: " + Code(t));
    g.otherLoaded = false;                     // the settings page closed
    auto o2 = RestoreDisplaySettingCore(g, true, false);
    Check(bool(o2["restored"]) && string(o2["action"]) == "clear" && !g.HasRecord(), "now cleared");
    // The write reads back, then a source reverts before the final check:
    // the record must stay (only the last read decides the delete).
    auto g3 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g3, BloomInput("none"))), "set none 3");
    g3.revertTo = 0;
    g3.revertSystemConfigOnReadsAfter = g3.scReads + 2;   // after the apply's own read-back
    auto o4 = RestoreDisplaySettingCore(g3, true, false);
    Check(!bool(o4["restored"]) && g3.HasRecord(), "record kept when the final read disagrees");
    // A write that does not read back keeps the record too.
    auto g2 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g2, BloomInput("none"))), "set none 2");
    g2.applyWritesSystemConfig = false; g2.systemConfigWriteIgnored = true;
    auto o3 = RestoreDisplaySettingCore(g2, true, false);
    Check(!bool(o3["restored"]) && g2.HasRecord(), "unverified restore keeps the record");
    ''')


def test_get_display_setting_is_read_only(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.disk.Put(DISPLAY_RESTORE_NEXT_FILE, MakeRecordText("high", "none", g.identity));
    auto r = GetDisplaySettingCore(g);
    Check(Ok(r) && string(r["output"]["bloom"]) == "high", "read");
    Check(g.disk.Has(DISPLAY_RESTORE_NEXT_FILE) && !g.HasRecord(), "Get moves no files");
    Check(g.scWrites == 0 && g.applies == 0, "Get writes nothing");
    ''')


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
    assert _schema("RestoreDisplaySetting")["properties"] == {"force": {"type": "boolean"}}


def test_only_the_live_host_touches_the_game():
    core = _strip_comments(CORE)
    for banned in ["GetApp", "CGame", "CSystem", "IO::", "yield", "Json::FromFile", "Json::ToFile", "Crypto::"]:
        assert banned not in core, banned
    tools = _strip_comments(TOOLS)
    # The only FxBloomHdr writes live in the host's two writers.
    assert len(re.findall(r"FxBloomHdr\s*=(?!=)", tools)) == 2
    assert tools.count("DisplaySettings_Apply()") == 1
    assert tools.count("DisplaySettings_LoadCurrent()") == 1
    # Apply only on a wrapper this host loaded.
    wa = tools[tools.index("bool WrapperWriteApply("):tools.index("void WrapperUnload()")]
    assert "!loadedByUs" in wa.split("DisplaySettings_Apply()")[0]
    wl = tools[tools.index("bool WrapperLoad("):tools.index("int WrapperRead()")]
    assert wl.index("api.DisplaySettings !is null") < wl.index("DisplaySettings_LoadCurrent()")


def test_record_written_flushed_and_closed():
    tools = _strip_comments(TOOLS)
    w = tools[tools.index("bool FileWrite("):tools.index("bool FileMove(")]
    assert w.index("f.Write(text)") < w.index("f.Flush()") < w.index("f.Close()")


def test_identity_is_hashed_and_includes_instance_mark():
    tools = _strip_comments(TOOLS)
    ident = tools[tools.index("string InstallIdentity()"):tools.index("Json::Value@ IdentityJson()")]
    for part in ["IO::FromUserGameFolder(", "IO::FromAppFolder(", "IO::FromStorageFolder(", "_ProfileName()",
                 '"port.override"', "Crypto::Sha256("]:
        assert part in ident, part


def test_restore_called_on_start_disable_and_unload():
    main = _strip_comments(MAIN)

    def fn_body(name):
        start = main.index(f"void {name}()")
        return main[start:main.index("}", start)]

    assert 'RestoreDisplaySettingOnLifecycle("start")' in fn_body("Main")
    assert 'RestoreDisplaySettingOnLifecycle("disable")' in fn_body("OnDisabled")
    assert 'RestoreDisplaySettingOnLifecycle("unload")' in fn_body("OnDestroyed")
    # Callbacks are not coroutines: only start may yield.
    assert 'RestoreDisplaySettingCore(host, when == "start", false)' in _strip_comments(CORE)


def test_restore_record_is_in_plugin_storage():
    policy = POLICY.read_text()
    assert 'const string DISPLAY_RESTORE_FILE = "display-restore.txt";' in policy
    assert 'const string DISPLAY_RESTORE_NEXT_FILE = "display-restore.next.txt";' in policy
    assert "IO::FromStorageFolder(name)" in TOOLS


def test_policy_file_has_no_game_types():
    policy = _strip_comments(POLICY.read_text())
    for banned in ["GetApp", "CGame", "CSystem", "yield", "IO::"]:
        assert banned not in policy, banned
