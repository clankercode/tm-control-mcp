"""Get/Set/RestoreDisplaySetting (bloom): policy, orchestration and source contracts.

No live game. DisplaySettingsPolicy.as runs in the stock AngelScript runner
against the Python port below. The production orchestration
(DisplaySettingsCore.as: one record slot, identity, the non-yielding Set and
Restore sections, wrapper ownership) runs in the same runner against a fake game
and a fake disk (tests/as_core_fakes.py). Fix round 2 cut the automatic
machinery (lifecycle restore, keep-oldest priors, side-file journal); the
regressions here are named after the review-2 findings that still apply.

UNPROVEN live (2026-11-18): that FxBloomHdr=None applied at runtime removes
bloom without a restart (Q2), and that DisplaySettings_Apply neither resets the
window/device nor saves Default.json at once (Q3): persistence is "assumed".
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
REC = "bloom-restore.txt"

# --- Python port of DisplaySettingsPolicy.as ---------------------------------

NAMES = ["none", "medium", "high"]


def index(name):
    return NAMES.index(name) if name in NAMES else -1


def restore_decision(readable, all_prior, all_target, unreadable_known, force):
    if readable == 0:
        return "unavailable"
    if not unreadable_known and all_prior:
        return "clear"
    if not unreadable_known and all_target:
        return "apply"
    return "apply" if force else "conflict"


def wrapper_owner(loaded, claim, same):
    if not loaded:
        return 0
    return 1 if claim and same else 2


def mechanism(loaded_without_yield, busy):
    return "wrapper" if loaded_without_yield and not busy else "systemConfig"


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


RAW = ["none", "medium", "high", "None", "NONE", "off", "Off", "Medium", "HIGH", " high ", "high ", "",
       "low", "ultra", "1", "nOne", "-1"]


def test_bloom_tokens_are_canonical_only(as_runner, tmp_path):
    lines = []
    for raw in RAW:
        lines.append(f"Check(BloomIndex({s(raw)}) == {index(raw)}, {s('index ' + raw)});")
    for i in range(-2, 5):
        exp = NAMES[i] if 0 <= i < 3 else ""
        lines.append(f"Check(BloomName({i}) == {s(exp)}, \"name {i}\");")
    # Both game enums are None, Medium, High in that order (checked in the 1.29.14 dump).
    lines.append('Check(BloomIndex("none") == 0 && BloomIndex("medium") == 1 && BloomIndex("high") == 2, "enum order");')
    lines.append('Check(DisplayConfigName(false) == "display" && DisplayConfigName(true) == "safe", "config names");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


def test_restore_decision_and_owner_tables(as_runner, tmp_path):
    lines = []
    for readable, ap, at, uk, force in itertools.product([0, 1, 2], [False, True], [False, True], [False, True],
                                                         [False, True]):
        exp = restore_decision(readable, ap, at, uk, force)
        lines.append(f"Check(RestoreDecision({readable}, {b(ap)}, {b(at)}, {b(uk)}, {b(force)}) == {s(exp)},"
                     f" {s(f'decide {readable}/{ap}/{at}/{uk}/{force}')});")
    for loaded, claim, same in itertools.product([False, True], repeat=3):
        lines.append(f"Check(DisplayWrapperOwner({b(loaded)}, {b(claim)}, {b(same)}) == {wrapper_owner(loaded, claim, same)},"
                     f" {s(f'owner {loaded}/{claim}/{same}')});")
    for loaded, busy in itertools.product([False, True], repeat=2):
        lines.append(f"Check(ChooseBloomMechanism({b(loaded)}, {b(busy)}) == {s(mechanism(loaded, busy))},"
                     f" {s(f'mech {loaded}/{busy}')});")
    # Said plainly: a known-unreadable source is always a conflict without force.
    lines.append('Check(RestoreDecision(1, true, false, true, false) == "conflict", "unreadable busy wrapper");')
    lines.append('Check(RestoreDecision(2, false, false, false, false) == "conflict", "neither target nor prior");')
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))
    assert restore_decision(1, True, True, False, False) == "clear"


def test_record_format_is_strict(as_runner, tmp_path):
    ident = "ab" * 32
    run_policy(as_runner, tmp_path, rf'''
    auto r = DisplayRecord();
    r.prior = "high"; r.target = "none"; r.config = "display";
    r.identity = "{ident}"; r.setAt = "2026-11-19 00:00:00";
    string text = DisplayRecordText(r);
    string why;
    auto back = ParseDisplayRecord(text, why);
    Check(back !is null && DisplayRecordsEqual(back, r), "round trip: " + why);
    Check(ParseDisplayRecord(text.SubStr(0, text.Length - 1), why) is null, "missing final newline");
    Check(ParseDisplayRecord(text.SubStr(0, text.Length / 2), why) is null, "half a file");
    Check(ParseDisplayRecord("", why) is null, "empty");
    // Empty or non-canonical prior / target tokens (review 2: prior= passed before).
    Check(ParseDisplayRecord(text.Replace("prior=high", "prior="), why) is null, "empty prior");
    Check(ParseDisplayRecord(text.Replace("target=none", "target="), why) is null, "empty target");
    Check(ParseDisplayRecord(text.Replace("prior=high", "prior=High"), why) is null, "capitalised prior");
    Check(ParseDisplayRecord(text.Replace("prior=high", "prior= high"), why) is null, "spaced prior");
    Check(ParseDisplayRecord(text.Replace("target=none", "target=off"), why) is null, "alias target");
    Check(ParseDisplayRecord(text.Replace("target=none", "target=high"), why) is null, "prior == target");
    Check(ParseDisplayRecord(text.Replace("config=display", "config=Display"), why) is null, "bad config");
    Check(ParseDisplayRecord(text.Replace("schema=3", "schema=2"), why) is null, "old schema");
    Check(ParseDisplayRecord(text.Replace("identity={ident}", "identity=C:/users/x"), why) is null, "raw path identity");
    Check(ParseDisplayRecord(text + "prior=none\n", why) is null, "content after end");
    Check(ParseDisplayRecord(text.Replace("setting=bloom\n", "setting=bloom\nextra=1\n"), why) is null, "extra key");
    Check(ParseDisplayRecord(text.Replace("setAt=2026-11-19 00:00:00\n", ""), why) is null, "missing key");
    Check(ParseDisplayRecord(text.Replace("setting=bloom\n", "setting=bloom\nprior=none\n"), why) is null, "duplicate key");
    Check(ParseDisplayRecord(text.Replace("\n", "\r\n"), why) is null, "CRLF is not canonical");
    Check(ParseDisplayRecord("# note\n" + text, why) is null, "comment line");
    Check(ParseDisplayRecord("{{\"bloom\":\"high\"}}", why) is null, "the schema-1 JSON record is not valid here");
    ''')


def test_legacy_record_bloom_is_read_for_reporting_only(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(LegacyRecordBloom("display-restore.json", "{\"bloom\": \"high\", \"setAt\":\"x\"}") == "high", "json");
    Check(LegacyRecordBloom("display-restore.json", "{\"bloom\":\"ultra\"}") == "", "json bad value");
    Check(LegacyRecordBloom("display-restore.json", "{\"bloom\":") == "", "json truncated");
    Check(LegacyRecordBloom("display-restore.txt", "schema=2\nprior=medium\napplied=none\n") == "medium", "schema 2");
    Check(LegacyRecordBloom("display-restore.next.txt", "garbage") == "", "unparseable");
    auto names = DisplayLegacyRecordFiles();
    Check(names.Length == 3 && names.Find("display-restore.json") >= 0, "legacy names");
    Check(names.Find(DISPLAY_RESTORE_FILE) < 0, "the current record is not a legacy name");
    ''')


def test_side_effects(as_runner, tmp_path):
    lines = []
    cases = [
        (1, 1, 1, 1, 800, 450, 800, 450),
        (1, 2, 1, 1, 800, 450, 800, 450),
        (1, 1, 0, 1, 800, 450, 800, 450),
        (1, 1, 1, 1, 800, 450, 1024, 450),
        (1, 2, 0, 2, 800, 450, 800, 576),
    ]
    for c in cases:
        lines.append(f"Check(DisplaySideEffects({', '.join(str(x) for x in c)}) == {s(side_effects(*c))}, {s('side ' + str(c))});")
    run_policy(as_runner, tmp_path, "\n".join("    " + l for l in lines))


# --- Production orchestration (DisplaySettingsCore.as) on a fake game + disk ----


def test_core_set_restore_round_trip(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();               // user's bloom: high
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Ok(r) && g.systemConfig == 0 && OutStr(r, "restoreRecord") == "written", "set none: " + Code(r));
    Check(OutStr(r, "mechanism") == "wrapper" && OutStr(r, "persisted") == "assumed", "wrapper, assumed");
    Check(g.Record() == MakeRecordText("high", "none", g.Id()).Replace("2026-11-18 23:00:00", "2026-11-19 00:00:00"),
          "record holds prior, target, config, identity: " + g.Record());
    Check(g.Clean() && g.loads == g.unloads, "every wrapper this tool loaded was released");
    Check(g.yields == 0, "Set never yields");
    auto get = GetDisplaySettingCore(g);
    Check(string(get["output"]["restoreRecord"]["restoreWouldDo"]) == "apply", "Get says what Restore would do");
    auto o = RestoreDisplaySettingTool(g, NoInput());
    Check(Ok(o) && OutBool(o, "restored") && OutStr(o, "action") == "apply" && g.systemConfig == 2, "restored: " + Code(o));
    Check(!g.HasRecord() && g.Clean() && g.yields == 0, "record gone, nothing held, no yield");
    auto none = RestoreDisplaySettingTool(g, NoInput());
    Check(Ok(none) && OutStr(none, "action") == "none" && OutStr(none, "reason") == "no record", "nothing left");
    // Same value: no record needed, nothing written.
    auto same = SetDisplaySettingCore(g, BloomInput("high"));
    Check(Ok(same) && !g.HasRecord() && OutStr(same, "mechanism") == "none", "no-op set");
    ''')


def test_b1_record_is_never_overwritten(as_runner, tmp_path):
    """B1 / review 2 F1, F2: one slot. Any record, valid or not, refuses Set and changes nothing."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    string rec = g.Record();
    uint writes = g.scWrites, applies = g.applies;
    auto r = SetDisplaySettingCore(g, BloomInput("medium"));
    Check(!Ok(r) && Code(r) == "RESTORE_PENDING", "second set refused: " + Code(r));
    Check(g.Record() == rec && g.systemConfig == 0 && g.scWrites == writes && g.applies == applies, "nothing changed");
    // The user picked something else meanwhile: still refused, never adopted as a new prior.
    g.systemConfig = 1;
    Check(Code(SetDisplaySettingCore(g, BloomInput("none"))) == "RESTORE_PENDING" && g.Record() == rec, "user value not adopted");
    // An invalid record.
    auto g2 = FakeDisplayGame();
    g2.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("medium", "none", g2.Id()).SubStr(0, 40));
    string bad = g2.Record();
    auto r2 = SetDisplaySettingCore(g2, BloomInput("none"));
    Check(Code(r2) == "RESTORE_RECORD_INVALID" && g2.Record() == bad && g2.systemConfig == 2 && g2.scWrites == 0, "invalid kept");
    auto o2 = RestoreDisplaySettingTool(g2, ForceInput(true));
    Check(Code(o2) == "RESTORE_RECORD_INVALID" && g2.Record() == bad && g2.systemConfig == 2, "even force never applies it");
    // An unreadable record.
    auto g3 = FakeDisplayGame();
    g3.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("medium", "none", g3.Id()));
    g3.disk.fail.InsertLast("read:" + DISPLAY_RESTORE_FILE);
    Check(Code(SetDisplaySettingCore(g3, BloomInput("none"))) == "RESTORE_RECORD_INVALID" && g3.systemConfig == 2, "unreadable");
    // Another install's record.
    auto g4 = FakeDisplayGame();
    g4.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("medium", "none", "cccccccccccccccccccccccccccccccc"));
    Check(Code(SetDisplaySettingCore(g4, BloomInput("none"))) == "RESTORE_CONFLICT" && g4.systemConfig == 2, "foreign");
    auto o4 = RestoreDisplaySettingTool(g4, ForceInput(true));
    Check(Code(o4) == "RESTORE_CONFLICT" && g4.HasRecord() && g4.systemConfig == 2, "force never crosses identity");
    ''')


def test_b1_record_write_is_verified_before_any_bloom_write(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.disk.truncateWrites = true;             // the disk stores a short copy
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(r) == "RESTORE_RECORD_FAILED" && g.systemConfig == 2 && g.applies == 0 && g.scWrites == 0, "read-back caught it");
    Check(!g.HasRecord(), "the bad record was deleted");
    auto g2 = FakeDisplayGame();
    g2.disk.fail.InsertLast("write:" + DISPLAY_RESTORE_FILE);
    Check(Code(SetDisplaySettingCore(g2, BloomInput("none"))) == "RESTORE_RECORD_FAILED" && g2.systemConfig == 2, "write failure");
    auto g3 = FakeDisplayGame();
    g3.disk.fail.InsertLast("read:" + DISPLAY_RESTORE_FILE);
    Check(Code(SetDisplaySettingCore(g3, BloomInput("none"))) == "RESTORE_RECORD_FAILED" && g3.systemConfig == 2, "read failure");
    // A bad record that cannot be deleted stays, and it never parses: Set keeps refusing.
    auto g4 = FakeDisplayGame();
    g4.disk.truncateWrites = true;
    g4.disk.fail.InsertLast("delete:" + DISPLAY_RESTORE_FILE);
    Check(Code(SetDisplaySettingCore(g4, BloomInput("none"))) == "RESTORE_RECORD_FAILED" && g4.systemConfig == 2, "stuck half record");
    g4.disk.truncateWrites = false;
    Check(Code(SetDisplaySettingCore(g4, BloomInput("none"))) == "RESTORE_RECORD_INVALID" && g4.systemConfig == 2, "then refused");
    ''')


HOOKS = r"""
namespace TmMcp {
    void HookReenterSet(FakeDisplayGame@ h) {
        @h.onBeforeBloomWrite = null;
        auto rr = RestoreDisplaySettingTool(h, NoInput());
        Check(!Ok(rr) && Code(rr) == "DISPLAY_BUSY", "restore inside set refused: " + Code(rr));
        auto rs = SetDisplaySettingCore(h, BloomInput("medium"));
        Check(Code(rs) == "DISPLAY_BUSY", "nested set refused: " + Code(rs));
        auto rg = GetDisplaySettingCore(h);
        Check(Code(rg) == "DISPLAY_BUSY", "get refused too");
        Check(h.HasRecord(), "record still on disk while set runs");
    }
    void HookReenterRestore(FakeDisplayGame@ h) {
        @h.onBeforeBloomWrite = null;
        Check(Code(SetDisplaySettingCore(h, BloomInput("medium"))) == "DISPLAY_BUSY", "set inside restore refused");
    }
    void HookRestoreOnYield(FakeDisplayGame@ h) { RestoreDisplaySettingTool(h, NoInput()); }
    void HookCrash(FakeDisplayGame@ h) { array<int> a; a[5] = 1; }  // the process dies here
}
"""


def test_b2_set_and_restore_cannot_interleave(as_runner, tmp_path):
    """Review 2 F11: a real reentry hook in the fake's Yield and at the record/write boundary."""
    run_display(as_runner, tmp_path, r"""
    // 1. Hooks at the window between the record and the bloom write: a Restore
    //    or Set entering there is refused DISPLAY_BUSY and changes nothing.
    auto g = FakeDisplayGame();
    @g.onBeforeBloomWrite = HookReenterSet;
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Ok(r) && g.systemConfig == 0 && g.HasRecord() && g.hookRuns == 1, "set finished: " + Code(r));
    Check(!g_displayBusy, "busy flag released");
    // 2. And the other way round: a Set entering a Restore at its write.
    @g.onBeforeBloomWrite = HookReenterRestore;
    auto o = RestoreDisplaySettingTool(g, NoInput());
    Check(Ok(o) && OutBool(o, "restored") && g.systemConfig == 2 && !g.HasRecord(), "restore finished: " + Code(o));
    Check(g.hookRuns == 2, "the hook ran inside restore");
    // 3. A hook in Yield would run another call between any two steps:
    //    neither Set nor Restore (nor Get) ever reaches it.
    @g.onYield = HookRestoreOnYield;
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set with a yield hook armed");
    Check(Ok(RestoreDisplaySettingTool(g, NoInput())), "restore with a yield hook armed");
    GetDisplaySettingCore(g);
    Check(g.yields == 0, "no display tool yields, so nothing can interleave");
    """, prelude=HOOKS)


def test_b4_crash_between_record_and_write_restores_cleanly(as_runner, tmp_path):
    """B2/B4: the record is on disk, the target was never written (crash at the write)."""
    run_display(as_runner, tmp_path, r"""
    auto g = FakeDisplayGame();
    @g.onBeforeBloomWrite = HookCrash;
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(!Ok(r) && g.HasRecord() && g.systemConfig == 2 && g.applies == 0, "crashed before the write: " + Code(r));
    Check(g.Clean(), "the wrapper it loaded was still released, busy flag cleared");
    @g.onBeforeBloomWrite = null;
    // Next call: Set refuses (the record is the slot); Restore sees prior everywhere.
    Check(Code(SetDisplaySettingCore(g, BloomInput("none"))) == "RESTORE_PENDING", "set refuses");
    auto o = RestoreDisplaySettingTool(g, NoInput());
    Check(Ok(o) && !OutBool(o, "restored") && OutStr(o, "reason") == "already at prior", "already at prior: " + Code(o));
    Check(!g.HasRecord() && g.scWrites == 0 && g.applies == 0, "record deleted, nothing written");
    """, prelude=HOOKS)


def test_b4_restore_conflicts_and_force(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    g.systemConfig = 1;                       // the user picked medium in the settings page
    uint w = g.scWrites + g.applies;
    auto o = RestoreDisplaySettingTool(g, NoInput());
    Check(Code(o) == "RESTORE_CONFLICT" && g.systemConfig == 1 && g.HasRecord() && g.scWrites + g.applies == w, "kept");
    auto get = GetDisplaySettingCore(g);
    Check(string(get["output"]["restoreRecord"]["restoreWouldDo"]) == "conflict", "Get reports the conflict");
    auto f = RestoreDisplaySettingTool(g, ForceInput(true));
    Check(Ok(f) && OutBool(f, "restored") && g.systemConfig == 2 && !g.HasRecord(), "force writes the prior: " + Code(f));
    // The user already reverted to the prior: delete, nothing written.
    auto g2 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g2, BloomInput("none"))), "set none 2");
    g2.systemConfig = 2;
    uint w2 = g2.scWrites + g2.applies;
    auto c = RestoreDisplaySettingTool(g2, NoInput());
    Check(Ok(c) && OutStr(c, "reason") == "already at prior" && !g2.HasRecord() && g2.scWrites + g2.applies == w2, "cleared");
    // A write that does not read back keeps the record.
    auto g3 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g3, BloomInput("none"))), "set none 3");
    g3.systemConfigWriteIgnored = true; g3.applyWritesSystemConfig = false;
    auto u = RestoreDisplaySettingTool(g3, NoInput());
    Check(Code(u) == "RESTORE_UNVERIFIED" && g3.HasRecord(), "unverified keeps the record: " + Code(u));
    // Display vs safe mode are different configs: no cross restore.
    auto g4 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g4, BloomInput("none"))), "set in display");
    g4.safeMode = true;
    Check(Code(RestoreDisplaySettingTool(g4, ForceInput(true))) == "RESTORE_CONFLICT" && g4.HasRecord(), "safe mode: conflict");
    ''')


def test_b4_unreadable_busy_wrapper_is_a_conflict(as_runner, tmp_path):
    """Review 2 F4 P2: Graphics holds the wrapper but it cannot be read."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set none");
    g.systemConfig = 2;                       // runtime already back at the prior...
    g.OtherLoads(0, false);                   // ...but the settings page holds a wrapper that won't read
    auto o = RestoreDisplaySettingTool(g, NoInput());
    Check(Code(o) == "RESTORE_CONFLICT" && g.HasRecord(), "kept while a known source is unreadable: " + Code(o));
    Check(!g.applyOnOtherWrapper && g.applies == 1 && g.scWrites == 0, "nothing written, their wrapper never applied");
    g.systemConfig = 0;                       // runtime at target, wrapper still unreadable
    Check(Code(RestoreDisplaySettingTool(g, NoInput())) == "RESTORE_CONFLICT" && g.HasRecord(), "still a conflict");
    auto f = RestoreDisplaySettingTool(g, ForceInput(true));
    Check(!g.applyOnOtherWrapper, "even force never applies someone else's wrapper");
    Check(g.systemConfig == 2 && g.scWrites == 1, "force writes systemConfig directly");
    Check(Code(f) == "RESTORE_UNVERIFIED" && g.HasRecord(), "and keeps the record while the wrapper is unreadable");
    g.OtherUnloads();
    auto c = RestoreDisplaySettingTool(g, NoInput());
    Check(Ok(c) && OutStr(c, "reason") == "already at prior" && !g.HasRecord(), "cleared once the page closed");
    ''')


def test_b2_invalid_index_is_refused_at_the_write_boundary(as_runner, tmp_path):
    """Review 2 F1 P1: an invalid index is rejected again where bloom is written."""
    run_display(as_runner, tmp_path, r"""
    auto g = FakeDisplayGame();
    string err;
    bool pending;
    Check(!DisplayWriteBloom(g, "wrapper", -1, err, pending), "wrapper: refused");
    Check(!DisplayWriteBloom(g, "wrapper", 3, err, pending), "wrapper: out of range refused");
    Check(g.applies == 0 && g.loads == 0 && g.apiWrapperValue == -1, "nothing loaded or applied");
    Check(!DisplayWriteBloom(g, "systemConfig", -1, err, pending) && g.scWrites == 0, "systemConfig: refused");
    Check(DisplayWriteBloom(g, "systemConfig", 0, err, pending) && g.systemConfig == 0, "a real index writes");
    """)


def test_b3_identity_fails_closed(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.identityKnown = false;                  // no port.override: the primary prefix
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(r) == "IDENTITY_UNKNOWN" && g.systemConfig == 2 && !g.HasRecord() && g.loads == 0, "refused: " + Code(r));
    // A valid record from this install, but the identity cannot be read now: kept.
    g.identityKnown = true;
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set with identity");
    g.identityKnown = false;
    auto o = RestoreDisplaySettingTool(g, ForceInput(true));
    Check(Code(o) == "RESTORE_CONFLICT" && g.HasRecord() && g.systemConfig == 0, "unknown identity never restores");
    // Same identity string but the record names the other display config: the core checks it too.
    auto g2 = FakeDisplayGame();
    g2.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("high", "none", g2.Id(), "safe"));
    g2.systemConfig = 0;
    Check(Code(RestoreDisplaySettingTool(g2, ForceInput(true))) == "RESTORE_CONFLICT" && g2.systemConfig == 0, "config mismatch");
    Check(Code(SetDisplaySettingCore(g2, BloomInput("medium"))) == "RESTORE_CONFLICT" && g2.systemConfig == 0, "set too");
    ''')


def test_b2_sources_must_agree_and_one_mechanism(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.loadValue = 1;                          // the wrapper says medium, systemConfig high
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(r) == "SOURCES_DISAGREE" && !g.HasRecord() && g.scWrites == 0 && g.applies == 0, "refused: " + Code(r));
    // The wrapper would need a frame to load: systemConfig is chosen up front, with no yield.
    auto g2 = FakeDisplayGame();
    g2.loadNeedsFrame = true;
    auto r2 = SetDisplaySettingCore(g2, BloomInput("none"));
    Check(Ok(r2) && OutStr(r2, "mechanism") == "systemConfig" && g2.systemConfig == 0 && g2.yields == 0, "direct: " + Code(r2));
    // The chosen wrapper fails: no fallback write, APPLY_UNVERIFIED, record kept.
    auto g3 = FakeDisplayGame();
    g3.wrapperApplyFails = true;
    auto r3 = SetDisplaySettingCore(g3, BloomInput("none"));
    Check(Code(r3) == "APPLY_UNVERIFIED" && OutStr(r3, "mechanism") == "wrapper" && g3.scWrites == 0, "no fallback");
    Check(g3.HasRecord() && g3.Clean(), "record kept, wrapper released");
    // Wrote but the read-back disagrees.
    auto g4 = FakeDisplayGame();
    g4.applyWritesSystemConfig = false;
    auto r4 = SetDisplaySettingCore(g4, BloomInput("none"));
    Check(Code(r4) == "APPLY_UNVERIFIED" && g4.HasRecord(), "read-back mismatch keeps the record");
    ''')


def test_b5_legacy_record_is_visible_and_blocks_set(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.systemConfig = 0;                       // an older build left bloom at none
    g.disk.Put("display-restore.json", "{\"bloom\":\"high\",\"setAt\":\"2026-11-18 19:50:00\"}");
    auto get = GetDisplaySettingCore(g);
    auto legacy = get["output"]["legacyRecord"];
    Check(legacy.GetType() == Json::Type::Object && string(legacy["path"]) == "storage/display-restore.json", "path shown");
    Check(string(legacy["bloom"]) == "high", "its bloom shown");
    auto r = SetDisplaySettingCore(g, BloomInput("medium"));
    Check(Code(r) == "LEGACY_RECORD_PRESENT" && g.systemConfig == 0 && !g.HasRecord(), "set refused: " + Code(r));
    auto o = RestoreDisplaySettingTool(g, ForceInput(true));
    Check(Ok(o) && OutStr(o, "action") == "none" && g.systemConfig == 0, "restore never applies it");
    Check(g.disk.Has("display-restore.json"), "never migrated or deleted");
    // Schema 2 leftovers too; a garbled one is still visible.
    auto g2 = FakeDisplayGame();
    g2.disk.Put("display-restore.next.txt", "%%garbage");
    auto get2 = GetDisplaySettingCore(g2);
    Check(get2["output"]["legacyRecord"].GetType() == Json::Type::Object
          && !get2["output"]["legacyRecord"].HasKey("bloom"), "unparseable legacy shown without bloom");
    Check(Code(SetDisplaySettingCore(g2, BloomInput("none"))) == "LEGACY_RECORD_PRESENT", "and blocks set");
    ''')


def test_b6_wrapper_busy_and_release_ownership(as_runner, tmp_path):
    """B6 / review 2 F3 P2: someone else's wrapper; our own wrapper's release fails."""
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.OtherLoads(2); g.otherPendingMode = 3;
    auto r = SetDisplaySettingCore(g, BloomInput("none"));
    Check(Code(r) == "WRAPPER_BUSY" && !g.applyOnOtherWrapper && g.scWrites == 0 && !g.HasRecord(), "busy: " + Code(r));
    g.OtherUnloads();
    // Our release throws after the write (the read's release worked): the
    // claim is kept, not dropped.
    g.releaseOkFirst = 1; g.releaseFailures = 3;
    auto r2 = SetDisplaySettingCore(g, BloomInput("none"));
    Check(g.applies == 1 && g.HasRecord(), "the write ran");
    Check(g.ownWrapper != 0 && g.WrapperOwner() == DISPLAY_WRAPPER_OURS, "ownership kept until the release is confirmed");
    Check(OutBool(r2, "wrapperReleasePending"), "the result says so");
    Check(!Ok(r2) && Code(r2) == "APPLY_UNVERIFIED", "a stale own wrapper is an unknown source: " + Code(r2));
    // A release that fails while Set reads the prior: nothing written.
    auto g5 = FakeDisplayGame();
    g5.releaseFailures = 2;
    auto r5 = SetDisplaySettingCore(g5, BloomInput("none"));
    Check(Code(r5) == "WRAPPER_BUSY" && !g5.HasRecord() && g5.scWrites == 0 && g5.applies == 0, "read-phase: " + Code(r5));
    Check(g5.ownWrapper != 0, "claim kept");
    // A later call retries that release first; it is not mistaken for someone else's.
    g.releaseFailures = 0;
    auto get = GetDisplaySettingCore(g);
    Check(g.Clean() && g.apiWrapper == 0, "released on the next call");
    // If the API now exposes a different wrapper, it is someone else's: never unloaded or applied.
    auto g2 = FakeDisplayGame();
    g2.releaseFailures = 2;
    SetDisplaySettingCore(g2, BloomInput("none"));
    Check(g2.ownWrapper != 0, "claim held");
    g2.apiWrapper = 0;                        // ours went away...
    g2.OtherLoads(1);                         // ...and the settings page loaded its own
    uint unloads = g2.unloads;
    auto r3 = RestoreDisplaySettingTool(g2, NoInput());
    Check(g2.ownWrapper == 0 && g2.apiWrapper != 0 && g2.unloads == unloads, "their wrapper untouched, our claim dropped");
    Check(!g2.applyOnOtherWrapper, "never applied");
    // Release fails before Restore can read: nothing written, record kept.
    auto g3 = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g3, BloomInput("none"))), "set g3");
    g3.releaseFailures = 5;
    g3.loadNeedsFrame = false;
    auto r4 = RestoreDisplaySettingTool(g3, NoInput());
    Check(!Ok(r4) && g3.HasRecord(), "a pending release never lets restore delete the record: " + Code(r4));
    ''')


def test_lifecycle_never_restores(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    Check(Ok(SetDisplaySettingCore(g, BloomInput("none"))), "set");
    string rec = g.Record();
    array<string> whens = {"start", "disable", "unload"};
    for (uint i = 0; i < whens.Length; i++) {
        string done = DisplayLifecycleCore(g, whens[i]);
        Check(done.IndexOf("record pending") >= 0, "reported on " + whens[i]);
    }
    Check(g.Record() == rec && g.systemConfig == 0 && g.yields == 0, "never restored, never yields");
    Check(g.log.Length == 3, "logged each time");
    ''')


def test_get_display_setting_is_read_only(as_runner, tmp_path):
    run_display(as_runner, tmp_path, r'''
    auto g = FakeDisplayGame();
    g.disk.Put(DISPLAY_RESTORE_FILE, MakeRecordText("medium", "high", g.Id()));
    auto r = GetDisplaySettingCore(g);
    Check(Ok(r) && string(r["output"]["bloom"]) == "high", "read");
    Check(string(r["output"]["restoreRecord"]["state"]) == "valid", "record shown");
    Check(g.scWrites == 0 && g.applies == 0 && g.HasRecord() && g.Clean(), "Get writes nothing");
    ''')


# --- Source contracts -----------------------------------------------------------


def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in text.splitlines())


def _fn(text, sig, end_marker):
    start = text.index(sig)
    return text[start:text.index(end_marker, start)]


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
    for banned in ["GetApp", "CGame", "CSystem", "IO::", "yield", "Json::FromFile", "Json::ToFile", "Crypto::",
                   "host.Yield("]:
        assert banned not in core, banned
    tools = _strip_comments(TOOLS)
    # The only FxBloomHdr writes live in the host's two writers.
    assert len(re.findall(r"FxBloomHdr\s*=(?!=)", tools)) == 2
    assert tools.count("DisplaySettings_Apply()") == 1
    assert tools.count("DisplaySettings_LoadCurrent()") == 1
    # The live host's only yield is Yield(), which the core never calls.
    assert tools.count("yield()") == 1 and "void Yield() { yield(); }" in tools


def test_live_wrapper_owner_predicate_contract():
    """Review 2 F3 survivor: the live 'loaded by someone else' predicate, pinned to the policy."""
    tools = _strip_comments(TOOLS)
    owner = " ".join(_fn(tools, "int WrapperOwner()", "bool WrapperLoad(").split())
    # The whole body, pinned: the pure policy (truth-tabled above) on the live handles.
    assert owner == ("int WrapperOwner() { auto api = _DisplayScriptApi();"
                     " if (api is null) return DISPLAY_WRAPPER_NONE;"
                     " return DisplayWrapperOwner(api.DisplaySettings !is null, ownWrapper !is null,"
                     " ownWrapper !is null && api.DisplaySettings is ownWrapper); }"), owner
    # Load refuses while anything is loaded and claims what it loaded at once.
    load = _fn(tools, "bool WrapperLoad(", "int WrapperRead()")
    assert load.index("api.DisplaySettings !is null") < load.index("DisplaySettings_LoadCurrent()")
    assert load.index("DisplaySettings_LoadCurrent()") < load.index("@ownWrapper = api.DisplaySettings;")
    # Apply only on the wrapper this host loaded.
    wa = _fn(tools, "bool WrapperWriteApply(", "bool WrapperRelease(")
    assert "api.DisplaySettings !is ownWrapper" in wa.split("DisplaySettings_Apply()")[0]
    # Release drops the claim only after the wrapper is seen gone, and never unloads someone else's.
    rel = _fn(tools, "bool WrapperRelease(", "DisplayWatch@ WrapperWatch()")
    unload_at = rel.index("DisplaySettings_Unload()")
    assert rel.index("if (api.DisplaySettings !is ownWrapper) {") < unload_at
    tail = rel[unload_at:]
    assert tail.index("if (api.DisplaySettings is ownWrapper) {") < tail.index("@ownWrapper = null;")


def test_record_written_flushed_and_closed():
    tools = _strip_comments(TOOLS)
    w = _fn(tools, "bool FileWrite(", "bool FileDelete(")
    assert w.index("f.Write(text)") < w.index("f.Flush()") < w.index("f.Close()")


def test_identity_fails_closed_and_includes_instance_mark_and_config():
    tools = _strip_comments(TOOLS)
    ident = _fn(tools, "bool InstallIdentity(", "Json::Value@ IdentityJson()")
    for part in ["IO::FromUserGameFolder(", "IO::FromAppFolder(", "IO::FromStorageFolder(", "_ProfileName()",
                 "DisplayConfigName(SafeMode())", "Crypto::Sha256("]:
        assert part in ident, part
    assert ident.index("if (!_PortMark(mark, why)) return false;") < ident.index("Crypto::Sha256(")
    mark = _fn(tools, "bool _PortMark(", "bool InstallIdentity(")
    assert '"port.override"' in mark and "return false;" in mark


def test_nothing_restores_on_lifecycle():
    main = _strip_comments(MAIN)
    assert "RestoreDisplaySetting" not in main
    for fn, when in [("Main", "start"), ("OnDisabled", "disable"), ("OnDestroyed", "unload")]:
        start = main.index(f"void {fn}()")
        assert f'DisplaySettingsOnLifecycle("{when}")' in main[start:main.index("}", start)]
    life = _fn(_strip_comments(CORE), "string DisplayLifecycleCore(", "\n    }\n")
    for banned in ["WriteSystemConfig", "WrapperWriteApply", "FileDelete", "FileWrite", "_DisplayRestore"]:
        assert banned not in life, banned


def test_restore_record_is_in_plugin_storage():
    policy = POLICY.read_text()
    assert f'const string DISPLAY_RESTORE_FILE = "{REC}";' in policy
    assert "IO::FromStorageFolder(name)" in TOOLS


def test_policy_file_has_no_game_types():
    policy = _strip_comments(POLICY.read_text())
    for banned in ["GetApp", "CGame", "CSystem", "yield", "IO::"]:
        assert banned not in policy, banned
