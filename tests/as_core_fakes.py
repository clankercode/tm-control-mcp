"""Fake game hosts for running the production PauseCore.as / DisplaySettingsCore.as
in stock AngelScript (tests/test_pause_tools.py, tests/test_display_settings_tools.py).

The cores reach the game only through the PauseHost / DisplayHost interfaces, so
these fakes drive the real orchestration: clocks, menu, gate, context, yields,
dialogs, wrapper and disk are all scripted per test. Nothing here reimplements
policy. Both fakes carry reentry hooks: a test can make the fake call back into
the production core from inside Yield or from inside a host operation, the way
another coroutine would run if the core ever yielded there.
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
string getExceptionInfo() { return "fake exception"; }
namespace TmMcp {
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
    Json::Value@ MakeError(const string &in err, const string &in code = "", bool retryable = false,
                           const string &in mode = "", const string &in hint = "") {
        auto v = Json::Object(); v["success"] = false; v["error"] = err; v["code"] = code;
        v["retryable"] = retryable; v["hint"] = hint; return v;
    }
    bool Ok(Json::Value@ r) { return bool(r["success"]); }
    string Code(Json::Value@ r) { return r.HasKey("code") ? string(r["code"]) : ""; }
    bool OutHas(Json::Value@ r, const string &in key) { return r.HasKey("output") && r["output"].HasKey(key); }
    bool OutBool(Json::Value@ r, const string &in key) {
        return OutHas(r, key) && r["output"][key].GetType() == Json::Type::Boolean && bool(r["output"][key]);
    }
    string OutStr(Json::Value@ r, const string &in key) {
        return OutHas(r, key) && r["output"][key].GetType() == Json::Type::String ? string(r["output"][key]) : "";
    }
    int OutInt(Json::Value@ r, const string &in key) {
        return OutHas(r, key) && r["output"][key].GetType() == Json::Type::Number ? int(r["output"][key]) : -999;
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

    class FakePauseContext : PauseContext {
        uint64 playground = 0;
        uint64 handler = 0;
    }

    class FakePauseGame : PauseHost {
        uint64 now = 1000;
        uint frameMs = 16;
        // Frame hitches: the frame that starts at or after slowAt takes slowMs.
        uint64 slowAt = 0;
        uint slowMs = 0;
        // game
        bool inPlayground = true, loading = false, local = true, loginSet = false, spectator = false;
        uint64 playgroundId = 7, handlerId = 9;
        bool menu = false;
        bool dialog = false;
        array<uint> clocks = {100000, 200000, 300000};
        array<bool> readable = {true, true, true};
        // how the game reacts
        bool clocksIdle = false;      // frozen for a reason unrelated to the menu
        bool menuFreezes = true;      // menu up => clocks stop (local play)
        int showLagFrames = 0;        // frames before a show takes effect (-1 = never)
        int closeLagFrames = 0;       // frames before a close takes effect (-1 = never)
        int pendingShow = -1, pendingClose = -1;
        // calls seen
        uint shows = 0, closes = 0, yields = 0, gateReads = 0;
        array<uint64> showAt;
        array<uint64> closeAt;
        array<FakeEvent@> events;
        bool clockThrowsAfterShow = false, menuThrowsAfterResume = false;
        bool showThrowsAfterDispatch = false, resumeThrowsAfterDispatch = false;
        // Go online on the Nth clock report (ExtraState runs between a sample
        // and the read that follows it, with no yield in between).
        int goOnlineOnReport = -1, closeMenuOnReport = -1;
        int reports = 0;
        // Flip locality off on gate read number N (counted from 1), no yield needed.
        int goOnlineOnGateRead = -1;
        bool transientOnlineAfterShow = false;
        bool loseMenuReadersAfterShow = false, loseMenuReadersAfterResume = false;
        // A dialog comes up on DialogBlocking read number N, no yield needed.
        int dialogOnRead = -1;
        int dialogReads = 0;
        // Probes: reads done before the first ShowMenu (the last one is the
        // read immediately before it).
        uint gateReadsAtFirstShow = 0, gateReadsAtFirstResume = 0;
        uint dialogReadsAtFirstShow = 0;

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
            else if (what == "unbump") clocks[uint(value)] -= 1;
            else Check(false, "unknown fake event " + what);
        }

        void Frame() {
            uint step = frameMs;
            if (slowMs > 0 && now >= slowAt) { step = slowMs; slowMs = 0; }
            now += step;
            for (uint i = 0; i < events.Length; i++) {
                if (events[i] !is null && events[i].at <= now) { Apply(events[i].what, events[i].value); @events[i] = null; }
            }
            if (pendingShow > 0) pendingShow--;
            if (pendingShow == 0) { menu = true; pendingShow = -1; }
            if (pendingClose > 0) pendingClose--;
            if (pendingClose == 0) { menu = false; pendingClose = -1; }
            bool frozen = menu && menuFreezes;
            if (!clocksIdle && !frozen && !loading) for (uint i = 0; i < 3; i++) clocks[i] += step;
        }

        uint64 NowMs() { return now; }
        void Yield() { yields++; Frame(); }
        PauseContext@ CaptureContext() {
            auto c = FakePauseContext();
            c.playground = inPlayground ? playgroundId : 0;
            c.handler = inPlayground ? handlerId : 0;
            return c;
        }
        PauseGate@ ReadGate(PauseContext@ ctx) {
            gateReads++;
            if (goOnlineOnGateRead > 0 && int(gateReads) == goOnlineOnGateRead) local = false;
            auto g = PauseGate();
            bool readersLost = MenuReadersLost();
            g.inPlayground = inPlayground && !readersLost; g.loading = loading; g.local = local;
            if (transientOnlineAfterShow && shows == 1 && gateReads == gateReadsAtFirstShow + 1) g.local = false;
            g.serverLoginSet = loginSet; g.spectatorClient = spectator;
            auto c = cast<FakePauseContext>(ctx);
            g.sameContext = c !is null && inPlayground && c.playground != 0
                && c.playground == playgroundId && c.handler == handlerId;
            return g;
        }
        bool MenuReadersLost() {
            return (loseMenuReadersAfterShow && shows > 0) || (loseMenuReadersAfterResume && closes > 0);
        }
        bool TryMenuShown(bool &out shown) {
            if (menuThrowsAfterResume && closes > 0) { array<int> a; a[3] = 1; }
            if (MenuReadersLost()) return false;
            shown = menu;
            return true;
        }
        bool ReadClock(uint i, uint &out v) {
            if (clockThrowsAfterShow && shows > 0) { array<int> a; a[3] = 1; }
            v = clocks[i]; return inPlayground && readable[i];
        }
        bool ShowMenu() {
            if (shows == 0) { gateReadsAtFirstShow = gateReads; dialogReadsAtFirstShow = dialogReads; }
            shows++; showAt.InsertLast(now);
            if (!inPlayground) return false;
            if (showLagFrames == 0) menu = true;
            else if (showLagFrames > 0 && pendingShow < 0) pendingShow = showLagFrames;
            if (showThrowsAfterDispatch) { array<int> a; a[3] = 1; }
            return true;
        }
        bool CloseMenuResume() {
            if (closes == 0) gateReadsAtFirstResume = gateReads;
            closes++; closeAt.InsertLast(now);
            if (closeLagFrames == 0) menu = false;
            else if (closeLagFrames > 0 && pendingClose < 0) pendingClose = closeLagFrames;
            if (resumeThrowsAfterDispatch) { array<int> a; a[3] = 1; }
            return true;
        }
        bool DialogBlocking() {
            dialogReads++;
            if (dialogOnRead > 0 && int(dialogReads) == dialogOnRead) dialog = true;
            return dialog;
        }
        Json::Value@ ExtraState() {
            reports++;
            if (reports == goOnlineOnReport) local = false;
            if (reports == closeMenuOnReport) menu = false;
            return null;
        }
        // Frames with nobody calling (after a call returned).
        void Idle(uint n) { for (uint i = 0; i < n; i++) Frame(); }
        bool AnyShowAfter(uint64 t) {
            for (uint i = 0; i < showAt.Length; i++) if (showAt[i] > t) return true;
            return false;
        }
    }

    Json::Value@ PauseInput(const string &in action, int hold = -1, int timeout = -1) {
        auto v = Json::Object();
        v["action"] = action;
        if (hold >= 0) v["holdMs"] = hold;
        if (timeout >= 0) v["timeoutMs"] = timeout;
        return v;
    }

    Json::Value@ SampleInput(int ms) { auto v = Json::Object(); v["sampleMs"] = ms; return v; }
}
'''

DISPLAY_FAKE = r'''
namespace TmMcp {
    funcdef void FakeDisplayHook(FakeDisplayGame@ g);

    class FakeDisk {
        array<string> names;
        array<string> texts;
        // failure injection by operation + file name ("write:bloom-restore.txt")
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
        // identity: unknown without a port.override; display and safe mode differ
        bool identityKnown = true;
        bool safeMode = false;
        int systemConfig = 2;       // high
        bool systemConfigAvailable = true;
        bool systemConfigWriteIgnored = false;
        bool scriptApi = true;
        // The script API's loaded wrapper (0 = none) and the one this tool claims.
        uint apiWrapper = 0;
        uint ownWrapper = 0;
        uint nextWrapper = 1;
        int apiWrapperValue = -1;
        bool apiWrapperReadable = true;
        int otherPendingMode = 0;   // an edit someone else's wrapper holds
        // how LoadCurrent behaves
        int loadValue = -1;         // -1: copies systemConfig
        bool partialLoad = false;   // attaches the wrapper but returns failure
        bool loadNeedsFrame = false;// LoadCurrent leaves DisplaySettings null this frame
        bool wrapperApplyFails = false;
        bool applyThrows = false;
        bool watchThrows = false;
        bool applyWritesSystemConfig = true;
        // Model persistent writes only via Apply. A direct write is runtime-only.
        int persistedConfig = 2;
        bool deferApply = false;
        int pendingApply = -1;
        void LandApply() {
            if (pendingApply < 0) return;
            persistedConfig = systemConfig = pendingApply;
            pendingApply = -1;
        }
        void Reload() { apiWrapper = ownWrapper = 0; systemConfig = persistedConfig; }
        bool releaseThrows = false, logThrows = false;
        int releaseFailures = 0;    // the next N releases do not take...
        int releaseOkFirst = 0;     // ...after this many more succeed
        int appliedMode = 0;
        uint loads = 0, unloads = 0, applies = 0, scWrites = 0, yields = 0;
        bool applyOnOtherWrapper = false;
        array<int> scWritten;
        array<string> log;
        // Reentry hooks: run production code from inside Yield or right after
        // the record is written (where a yield would let another call in).
        FakeDisplayHook@ onYield = null;
        FakeDisplayHook@ onRecordWritten = null;
        // Right before a bloom write (wrapper Apply or systemConfig): the
        // window between the record and the write, where review 2 F11 let a
        // Restore in. A hook that throws models a crash there.
        FakeDisplayHook@ onBeforeBloomWrite = null;
        FakeDisplayHook@ onRelease = null;
        uint hookRuns = 0;

        void Yield() {
            yields++;
            if (onYield !is null) { hookRuns++; onYield(this); }
        }
        string Now() { return "2026-11-19 00:00:00"; }
        string Id() { return safeMode ? "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
        bool InstallIdentity(string &out identity, string &out why) {
            identity = ""; why = "";
            if (!identityKnown) { why = "no port.override in plugin storage"; return false; }
            identity = Id();
            return true;
        }
        Json::Value@ IdentityJson() { auto o = Json::Object(); o["known"] = identityKnown; return o; }
        bool SafeMode() { return safeMode; }
        int ReadSystemConfig() { return systemConfigAvailable ? systemConfig : -1; }
        bool WriteSystemConfig(int index, string &out err) {
            if (onBeforeBloomWrite !is null) { hookRuns++; onBeforeBloomWrite(this); }
            if (!systemConfigAvailable) { err = "unavailable"; return false; }
            if (BloomName(index).Length == 0) { err = "bad index"; return false; }
            scWrites++; scWritten.InsertLast(index);
            if (!systemConfigWriteIgnored) systemConfig = index;
            return true;
        }
        bool ScriptApiAvailable() { return scriptApi; }
        int WrapperOwner() {
            if (!scriptApi) return DISPLAY_WRAPPER_NONE;
            return DisplayWrapperOwner(apiWrapper != 0, ownWrapper != 0, ownWrapper != 0 && apiWrapper == ownWrapper);
        }
        // Someone else (the settings page) loads the wrapper.
        void OtherLoads(int value, bool readable = true) {
            apiWrapper = 1000 + nextWrapper++; apiWrapperValue = value; apiWrapperReadable = readable;
        }
        void OtherUnloads() { if (apiWrapper != 0 && apiWrapper != ownWrapper) apiWrapper = 0; }
        bool WrapperLoad(string &out err) {
            if (!scriptApi) { err = "no api"; return false; }
            if (apiWrapper != 0) { err = "already loaded"; return false; }
            loads++;
            if (loadNeedsFrame) { ownWrapper = 0; err = "null after LoadCurrent"; return false; }
            apiWrapper = nextWrapper++;
            ownWrapper = apiWrapper;
            apiWrapperValue = loadValue >= 0 ? loadValue : (systemConfigAvailable ? systemConfig : 2);
            apiWrapperReadable = true;
            if (partialLoad) { err = "LoadCurrent threw after exposing a wrapper"; return false; }
            return true;
        }
        int WrapperRead() {
            if (apiWrapper == 0 || !apiWrapperReadable) return -1;
            return apiWrapperValue;
        }
        bool WrapperWriteApply(int index, string &out err) {
            if (onBeforeBloomWrite !is null) { hookRuns++; onBeforeBloomWrite(this); }
            if (apiWrapper != 0 && apiWrapper != ownWrapper) { applyOnOtherWrapper = true; appliedMode = otherPendingMode; }
            if (ownWrapper == 0 || apiWrapper != ownWrapper) { err = "not ours"; return false; }
            if (applyThrows) { array<int> a; a[3] = 1; }
            if (wrapperApplyFails) { err = "apply failed"; return false; }
            apiWrapperValue = index; applies++;
            if (deferApply) pendingApply = index;
            else if (applyWritesSystemConfig && !systemConfigWriteIgnored) persistedConfig = systemConfig = index;
            return true;
        }
        bool WrapperRelease(string &out err) {
            if (onRelease !is null) {
                FakeDisplayHook@ hook = onRelease;
                @onRelease = null;
                hookRuns++; hook(this);
            }
            if (ownWrapper == 0) return true;
            if (apiWrapper != ownWrapper) { ownWrapper = 0; return true; }
            if (releaseThrows) { array<int> a; a[3] = 1; }
            if (releaseOkFirst > 0) releaseOkFirst--;
            else if (releaseFailures > 0) { releaseFailures--; err = "unload threw"; return false; }
            apiWrapper = 0; ownWrapper = 0; unloads++;
            return true;
        }
        DisplayWatch@ WrapperWatch() {
            auto w = DisplayWatch();
            if (ownWrapper == 0 || apiWrapper != ownWrapper) return w;
            if (watchThrows) { array<int> a; a[3] = 1; }
            w.ok = true; w.dirty = 1; w.mode = appliedMode; w.winX = 800; w.winY = 450;
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
            if (n == DISPLAY_RESTORE_FILE && onRecordWritten !is null) { hookRuns++; onRecordWritten(this); }
            return true;
        }
        bool FileDelete(const string &in n, string &out err) {
            if (disk.Fails("delete", n)) { err = "delete failed"; return false; }
            disk.Remove(n); return true;
        }
        string FilePath(const string &in n) { return "storage/" + n; }
        void Log(const string &in m) {
            if (logThrows) { array<int> a; a[3] = 1; }
            log.InsertLast(m);
        }

        string Record() { return disk.Get(DISPLAY_RESTORE_FILE); }
        bool HasRecord() { return disk.Has(DISPLAY_RESTORE_FILE); }
        bool Clean() { return ownWrapper == 0 && !g_displayBusy; }
    }

    Json::Value@ BloomInput(const string &in v) { auto o = Json::Object(); o["bloom"] = v; return o; }
    Json::Value@ NoInput() { return Json::Object(); }
    Json::Value@ ForceInput(bool f) { auto o = Json::Object(); o["force"] = f; return o; }
    Json::Value@ RetireInput() { auto o = Json::Object(); o["retire"] = true; return o; }

    string MakeRecordText(const string &in prior, const string &in target, const string &in identity,
                          const string &in config = "display") {
        auto r = DisplayRecord();
        r.prior = prior;
        r.target = target;
        r.config = config;
        r.identity = identity;
        r.setAt = "2026-11-18 23:00:00";
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


def run_core(runner, tmp_path, sources, fake, body, name="core_case.as", prelude=""):
    case = tmp_path / name
    case.write_text(_json_mocks_full() + SHIM + fake + "\n" + prelude
                    + "\nvoid RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), *[str(SRC / s) for s in sources], str(case)],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr


def run_pause(runner, tmp_path, body, prelude=""):
    run_core(runner, tmp_path, ["PausePolicy.as", "PauseCore.as"], PAUSE_FAKE, body, "pause_core_case.as", prelude)


def run_display(runner, tmp_path, body, prelude=""):
    run_core(runner, tmp_path, ["DisplaySettingsPolicy.as", "DisplaySettingsCore.as"], DISPLAY_FAKE, body,
             "display_core_case.as", prelude)
