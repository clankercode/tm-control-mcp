"""Fake game hosts for running the production PauseCore.as / DisplaySettingsCore.as
in stock AngelScript (tests/test_pause_tools.py, tests/test_display_settings_tools.py).

The cores reach the game only through the PauseHost / DisplayHost interfaces, so
these fakes drive the real orchestration: clocks, menu, gate, context ids, yields,
wrapper and disk are all scripted per test. Nothing here reimplements policy.
"""
import subprocess
from pathlib import Path

from as_json_mocks import JSON_MOCKS

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"

# Extra Json::Value surface the cores use beyond as_json_mocks (kept local so the
# shared mock other tests rely on stays unchanged).
JSON_EXTRA = r'''
namespace Json {
    void AddValue(Value@ arr, Value@ v) { arr.values.InsertLast(v); }
}
'''

SHIM = r'''
namespace TmMcp {
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
    Json::Value@ MakeError(const string &in err, const string &in code = "", bool retryable = false,
                           const string &in mode = "", const string &in hint = "") {
        auto v = Json::Object(); v["success"] = false; v["error"] = err; v["code"] = code;
        v["retryable"] = retryable; return v;
    }
    bool Ok(Json::Value@ r) { return bool(r["success"]); }
    string Code(Json::Value@ r) { return r.HasKey("code") ? string(r["code"]) : ""; }
    bool OutBool(Json::Value@ r, const string &in key) {
        return r["output"].HasKey(key) && r["output"][key].GetType() == Json::Type::Boolean && bool(r["output"][key]);
    }
    string OutStr(Json::Value@ r, const string &in key) {
        return r["output"].HasKey(key) && r["output"][key].GetType() == Json::Type::String ? string(r["output"][key]) : "";
    }
}
'''

PAUSE_FAKE = r'''
namespace TmMcp {
    // One scripted change at a fake time.
    class FakeEvent {
        uint64 at; string what; int value;
        FakeEvent() {}
        FakeEvent(uint64 a, const string &in w, int v) { at = a; what = w; value = v; }
    }

    class FakePauseGame : PauseHost {
        uint64 now = 1000;
        uint frameMs = 16;
        // game
        bool inPlayground = true, loading = false, local = true, loginSet = false, spectator = false;
        uint64 playgroundId = 7, handlerId = 9;
        bool menu = false;
        bool dialog = false;
        array<uint> clocks = {100000, 200000, 300000};
        array<bool> readable = {true, true, true};
        // how the game reacts
        bool menuFreezes = true;      // menu up => clocks stop (local play)
        int showLagFrames = 0;        // frames before a show takes effect (-1 = never)
        int closeLagFrames = 0;       // frames before a close takes effect (-1 = never)
        int pendingShow = -1, pendingClose = -1;
        // calls seen
        uint shows = 0, closes = 0, yields = 0, watchersStarted = 0;
        array<uint64> showAt;
        array<FakeEvent@> events;
        array<string> log;
        // Go online on the Nth clock report (ExtraState runs between a sample
        // and the check that follows it, with no yield in between).
        int goOnlineOnReport = -1;
        int reports = 0;
        // Flip locality off on the Nth gate read after arming (no yield needed).
        int gateFlipAfterReads = -1;
        bool armGateFlipAtSampleEnd = false;
        bool gateArmed = false;
        int gateReadsSinceArm = 0;

        void At(uint64 t, const string &in what, int value = 0) { events.InsertLast(FakeEvent(t, what, value)); }

        void Apply(const string &in what, int value) {
            if (what == "menu") menu = value != 0;
            else if (what == "loading") loading = value != 0;
            else if (what == "local") local = value != 0;
            else if (what == "login") loginSet = value != 0;
            else if (what == "playground") playgroundId = uint64(value);
            else if (what == "handler") handlerId = uint64(value);
            else if (what == "inPlayground") inPlayground = value != 0;
            else if (what == "dialog") dialog = value != 0;
            else if (what == "freezes") menuFreezes = value != 0;
            else if (what == "unreadable") readable[uint(value)] = false;
            else if (what == "readable") readable[uint(value)] = true;
            else if (what == "bump") clocks[uint(value)] += 1;
            else Check(false, "unknown fake event " + what);
        }

        void Frame() {
            now += frameMs;
            for (uint i = 0; i < events.Length; i++) {
                if (events[i] !is null && events[i].at <= now) { Apply(events[i].what, events[i].value); @events[i] = null; }
            }
            if (pendingShow > 0) pendingShow--;
            if (pendingShow == 0) { menu = true; pendingShow = -1; }
            if (pendingClose > 0) pendingClose--;
            if (pendingClose == 0) { menu = false; pendingClose = -1; }
            bool frozen = menu && menuFreezes;
            if (!frozen && !loading) for (uint i = 0; i < 3; i++) clocks[i] += frameMs;
        }

        uint64 NowMs() { return now; }
        void Yield() { yields++; Frame(); }
        PauseGate@ ReadGate() {
            if (gateArmed) {
                gateReadsSinceArm++;
                if (gateReadsSinceArm > gateFlipAfterReads) { local = false; gateArmed = false; }
            }
            auto g = PauseGate();
            g.inPlayground = inPlayground; g.loading = loading; g.local = local;
            g.serverLoginSet = loginSet; g.spectatorClient = spectator;
            g.playgroundId = inPlayground ? playgroundId : 0;
            g.handlerId = inPlayground ? handlerId : 0;
            return g;
        }
        bool MenuShown() { return menu; }
        bool ReadClock(uint i, uint &out v) { v = clocks[i]; return inPlayground && readable[i]; }
        // Called by the test fake when the initial sample is over: the core
        // reads the dialog state right after the post-sample gate check.
        bool ShowMenu() {
            shows++; showAt.InsertLast(now);
            if (!inPlayground) return false;
            if (showLagFrames == 0) menu = true;
            else if (showLagFrames > 0 && pendingShow < 0) pendingShow = showLagFrames;
            return true;
        }
        bool CloseMenuResume() {
            closes++;
            if (closeLagFrames == 0) menu = false;
            else if (closeLagFrames > 0 && pendingClose < 0) pendingClose = closeLagFrames;
            return true;
        }
        bool DialogBlocking() {
            // DialogBlocking is first read by the post-sample recheck: arm the
            // flip there, so the next gate read (the pre-show check) sees it.
            if (armGateFlipAtSampleEnd) { armGateFlipAtSampleEnd = false; gateArmed = true; gateReadsSinceArm = 0; }
            return dialog;
        }
        void StartWatcher() { watchersStarted++; }
        void Log(const string &in m) { log.InsertLast(m); }
        Json::Value@ ExtraState() {
            reports++;
            if (reports == goOnlineOnReport) local = false;
            return null;
        }

        // Run the ownership watcher for n frames (the live coroutine does this).
        void Watch(uint n) {
            for (uint i = 0; i < n; i++) { if (!PauseWatchStep(this)) break; Frame(); }
        }
    }

    Json::Value@ PauseInput(const string &in action, int hold = -1, int timeout = -1, int autoResume = -1) {
        auto v = Json::Object();
        v["action"] = action;
        if (hold >= 0) v["holdMs"] = hold;
        if (timeout >= 0) v["timeoutMs"] = timeout;
        if (autoResume >= 0) v["autoResumeAfterMs"] = autoResume;
        return v;
    }

    Json::Value@ SampleInput(int ms) { auto v = Json::Object(); v["sampleMs"] = ms; return v; }

    void ResetPause() { g_pause = PauseOwnership(); }
}
'''

DISPLAY_FAKE = r'''
namespace TmMcp {
    class FakeDisk {
        array<string> names;
        array<string> texts;
        // failure injection by operation + file name ("write:display-restore.next.txt")
        array<string> fail;
        // write text, but store a truncated copy (simulates a short write)
        bool truncateWrites = false;

        int Find(const string &in n) { return names.Find(n); }
        bool Has(const string &in n) { return Find(n) >= 0; }
        string Get(const string &in n) { int i = Find(n); return i < 0 ? "" : texts[i]; }
        void Put(const string &in n, const string &in t) {
            int i = Find(n);
            if (i < 0) { names.InsertLast(n); texts.InsertLast(t); } else texts[i] = t;
        }
        void Remove(const string &in n) { int i = Find(n); if (i >= 0) { names.RemoveAt(i); texts.RemoveAt(i); } }
        bool Fails(const string &in op, const string &in n) { return fail.Find(op + ":" + n) >= 0; }
    }

    class FakeDisplayGame : DisplayHost {
        FakeDisk disk;
        string identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        int systemConfig = 2;       // high
        bool systemConfigAvailable = true;
        bool scriptApi = true;
        // The game's settings: the wrapper LoadCurrent copies systemConfig.
        bool otherLoaded = false;   // someone else has the wrapper loaded
        int otherWrapperValue = 2;  // what their (maybe edited) wrapper holds
        int otherPendingMode = 0;   // their unsaved edit to another field
        bool ourLoaded = false;
        int ourWrapperValue = -1;
        // effects
        bool applyWritesSystemConfig = true;  // Apply pushes the wrapper into systemConfig
        bool wrapperApplyFails = false;
        bool systemConfigWriteIgnored = false;
        int appliedMode = 0;        // the display mode the game runs (Apply of an edited wrapper changes it)
        uint loads = 0, unloads = 0, applies = 0, scWrites = 0, yields = 0;
        bool applyOnOtherWrapper = false;     // set if anything ever applied someone else's wrapper
        // false = model a game whose LoadCurrent does not refuse when someone
        // else has the wrapper loaded (then only the core's policy protects it)
        bool strictLoad = true;
        // a source that reverts after the restore's own read-back (e.g. a late
        // Apply from the settings page re-saving the tool's value)
        int revertSystemConfigOnReadsAfter = -1;
        int scReads = 0;
        int revertTo = -1;
        array<string> log;

        void Yield() { yields++; }
        string Now() { return "2026-11-18 20:00:00"; }
        string InstallIdentity() { return identity; }
        Json::Value@ IdentityJson() { auto o = Json::Object(); o["fingerprint"] = identity; return o; }
        bool SafeMode() { return false; }
        int ReadSystemConfig() {
            scReads++;
            if (revertSystemConfigOnReadsAfter >= 0 && scReads > revertSystemConfigOnReadsAfter) {
                systemConfig = revertTo; revertSystemConfigOnReadsAfter = -1;
            }
            return systemConfigAvailable ? systemConfig : -1;
        }
        bool WriteSystemConfig(int index, string &out err) {
            if (!systemConfigAvailable) { err = "unavailable"; return false; }
            scWrites++;
            if (!systemConfigWriteIgnored) systemConfig = index;
            return true;
        }
        bool ScriptApiAvailable() { return scriptApi; }
        bool WrapperLoadedByOther() { return scriptApi && otherLoaded; }
        bool WrapperLoad(string &out err) {
            if (!scriptApi) { err = "no api"; return false; }
            if (otherLoaded && strictLoad) { err = "already loaded by someone else"; return false; }
            loads++; ourLoaded = true; ourWrapperValue = systemConfigAvailable ? systemConfig : 2;
            return true;
        }
        int WrapperRead() {
            if (otherLoaded && !ourLoaded) return otherWrapperValue;
            return ourLoaded ? ourWrapperValue : -1;
        }
        bool WrapperWriteApply(int index, string &out err) {
            if (otherLoaded) { applyOnOtherWrapper = true; appliedMode = otherPendingMode; }
            if (!ourLoaded) { err = "not loaded"; return false; }
            if (wrapperApplyFails) { err = "apply failed"; return false; }
            ourWrapperValue = index; applies++;
            if (applyWritesSystemConfig) systemConfig = index;
            return true;
        }
        void WrapperUnload() { if (ourLoaded) { ourLoaded = false; unloads++; } }
        DisplayWatch@ WrapperWatch() {
            auto w = DisplayWatch();
            string err;
            if (!WrapperLoad(err)) return w;
            w.ok = true; w.dirty = 1; w.mode = appliedMode; w.winX = 800; w.winY = 450;
            WrapperUnload();
            return w;
        }
        bool FileExists(const string &in n) { return disk.Has(n); }
        bool FileRead(const string &in n, string &out text, string &out err) {
            text = "";
            if (disk.Fails("read", n)) { err = "read failed"; return false; }
            if (!disk.Has(n)) { err = "missing"; return false; }
            text = disk.Get(n); return true;
        }
        bool FileWrite(const string &in n, const string &in text, string &out err) {
            if (disk.Fails("write", n)) { err = "write failed"; return false; }
            disk.Put(n, disk.truncateWrites ? text.SubStr(0, text.Length / 2) : text);
            return true;
        }
        bool FileMove(const string &in from, const string &in to, string &out err) {
            if (disk.Fails("move", from)) { err = "move failed"; return false; }
            if (!disk.Has(from)) { err = "missing"; return false; }
            disk.Put(to, disk.Get(from)); disk.Remove(from); return true;
        }
        bool FileDelete(const string &in n, string &out err) {
            if (disk.Fails("delete", n)) { err = "delete failed"; return false; }
            disk.Remove(n); return true;
        }
        string FilePath(const string &in n) { return "storage/" + n; }
        void Log(const string &in m) { log.InsertLast(m); }

        string Record() { return disk.Get(DISPLAY_RESTORE_FILE); }
        bool HasRecord() { return disk.Has(DISPLAY_RESTORE_FILE); }
    }

    Json::Value@ BloomInput(const string &in v) { auto o = Json::Object(); o["bloom"] = v; return o; }
    Json::Value@ NoInput() { return Json::Object(); }
    Json::Value@ ForceInput(bool f) { auto o = Json::Object(); o["force"] = f; return o; }

    string MakeRecordText(const string &in prior, const string &in applied, const string &in identity) {
        auto r = DisplayRecord();
        r.prior = prior;
        auto parts = applied.Split(",");
        for (uint i = 0; i < parts.Length; i++) r.applied.InsertLast(parts[i]);
        r.identity = identity;
        r.setAt = "2026-11-18 19:00:00";
        return DisplayRecordText(r);
    }
}
'''


def _json_mocks_full():
    # as_json_mocks has Add(string) only; the cores also Add Values and ints.
    extra = JSON_MOCKS.replace(
        "        void Add(const string &in value) {",
        "        void Add(Value@ v) { values.InsertLast(v); }\n"
        "        void Add(int v) { auto row = Value(); row = v; values.InsertLast(row); }\n"
        "        void Add(const string &in value) {",
    )
    assert extra != JSON_MOCKS
    return extra + JSON_EXTRA


def run_core(runner, tmp_path, sources, fake, body, name="core_case.as"):
    case = tmp_path / name
    case.write_text(_json_mocks_full() + SHIM + fake
                    + "\nvoid RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), *[str(SRC / s) for s in sources], str(case)],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr


def run_pause(runner, tmp_path, body):
    run_core(runner, tmp_path, ["PausePolicy.as", "PauseCore.as"], PAUSE_FAKE, body, "pause_core_case.as")


def run_display(runner, tmp_path, body):
    run_core(runner, tmp_path, ["DisplaySettingsPolicy.as", "DisplaySettingsCore.as"], DISPLAY_FAKE, body,
             "display_core_case.as")
