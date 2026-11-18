namespace TmMcp {
    // GetDisplaySetting / SetDisplaySetting / RestoreDisplaySetting: the
    // game's bloom setting (Settings > Graphics > Bloom). Pure rules are in
    // DisplaySettingsPolicy.as.
    //
    // Two places hold it, both enum None/Medium/High:
    //   wrapper       app.ManiaPlanetScriptAPI.DisplaySettings (CGameDisplaySettingsWrapper)
    //                 after DisplaySettings_LoadCurrent(); written with
    //                 DisplaySettings_Apply(), released with DisplaySettings_Unload().
    //                 This is the script API the settings page is built on.
    //   systemConfig  GetApp().Viewport.SystemConfig.Display (CSystemConfigDisplay).FxBloomHdr
    //                 (DisplaySafe in safe mode).
    // The wrapper runs first; the direct write is the fallback. FxBloomHdr has
    // no _NextStart twin in the wrapper (unlike ShaderQuality, Shadows, ...),
    // which suggests it applies without a restart.
    //
    // UNPROVEN live (2026-11-18): that None removes bloom at once with no
    // restart (Q2), and that Apply neither resets the window/device nor saves
    // Default.json at once (Q3). Treat every write as persistent: the prior
    // value is recorded in the plugin storage folder BEFORE the write, and is
    // restored on plugin start, disable and unload.

    // null for an unreadable source, else "none"|"medium"|"high".
    Json::Value _BloomJson(int index) {
        Json::Value v;
        if (index < 0 || BloomName(index).Length == 0) return v;
        v = BloomName(index);
        return v;
    }

    string _DisplayRestorePath() {
        return IO::FromStorageFolder(DISPLAY_RESTORE_FILE);
    }

    bool _DisplayRestoreRecord(string &out prior, string &out setAt) {
        prior = "";
        setAt = "";
        string path = _DisplayRestorePath();
        if (!IO::FileExists(path)) return false;
        try {
            auto data = Json::FromFile(path);
            if (data.GetType() == Json::Type::Object) {
                if (data.HasKey("bloom") && data["bloom"].GetType() == Json::Type::String) prior = string(data["bloom"]);
                if (data.HasKey("setAt") && data["setAt"].GetType() == Json::Type::String) setAt = string(data["setAt"]);
            }
        } catch {
            warn("TM Control MCP: unreadable " + DISPLAY_RESTORE_FILE + ": " + getExceptionInfo());
        }
        return true;
    }

    bool _WriteDisplayRestoreRecord(const string &in prior, string &out err) {
        Json::Value data = Json::Object();
        data["bloom"] = prior;
        data["setAt"] = Time::FormatString("%Y-%m-%d %H:%M:%S");
        data["note"] = "tm-control-mcp: the user's bloom before SetDisplaySetting. RestoreDisplaySetting puts it back.";
        try {
            Json::ToFile(_DisplayRestorePath(), data);
        } catch {
            err = getExceptionInfo();
            return false;
        }
        return IO::FileExists(_DisplayRestorePath());
    }

    void _DeleteDisplayRestoreRecord() {
        string path = _DisplayRestorePath();
        if (IO::FileExists(path)) IO::Delete(path);
    }

    CSystemConfigDisplay@ _ActiveDisplayConfig(bool &out safeMode) {
        safeMode = false;
        auto app = GetApp();
        if (app is null || app.Viewport is null || app.Viewport.SystemConfig is null) return null;
        auto cfg = app.Viewport.SystemConfig;
        safeMode = cfg.IsSafeMode;
        return safeMode ? cfg.DisplaySafe : cfg.Display;
    }

    // -1 when unavailable.
    int _ReadBloomSystemConfig() {
        bool safe;
        auto d = _ActiveDisplayConfig(safe);
        if (d is null) return -1;
        return int(d.FxBloomHdr);
    }

    CGameManiaPlanetScriptAPI@ _DisplayScriptApi() {
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return null;
        return app.ManiaPlanetScriptAPI;
    }

    // The wrapper may already be loaded by someone else (the game's settings
    // page). Then it is used as-is and never unloaded under them.
    bool _WrapperBegin(CGameManiaPlanetScriptAPI@ api) {
        bool wasLoaded = api.DisplaySettings !is null;
        if (!wasLoaded) api.DisplaySettings_LoadCurrent();
        return wasLoaded;
    }

    void _WrapperEnd(CGameManiaPlanetScriptAPI@ api, bool wasLoaded) {
        if (!wasLoaded) api.DisplaySettings_Unload();
    }

    // -1 when unavailable.
    int _ReadBloomWrapper() {
        auto api = _DisplayScriptApi();
        if (api is null) return -1;
        int v = -1;
        try {
            bool wasLoaded = _WrapperBegin(api);
            if (api.DisplaySettings !is null) v = int(api.DisplaySettings.FxBloomHdr);
            _WrapperEnd(api, wasLoaded);
        } catch {
            warn("TM Control MCP: DisplaySettings read failed: " + getExceptionInfo());
            v = -1;
        }
        return v;
    }

    class DisplayWatch {
        bool ok = false;
        uint dirty = 0;
        int mode = -1;
        int winX = 0;
        int winY = 0;
    }

    DisplayWatch@ _ReadDisplayWatch() {
        auto w = DisplayWatch();
        auto api = _DisplayScriptApi();
        if (api is null) return w;
        try {
            bool wasLoaded = _WrapperBegin(api);
            auto s = api.DisplaySettings;
            if (s !is null) {
                w.ok = true;
                w.dirty = s.DirtyCounter;
                w.mode = int(s.DisplayMode);
                w.winX = s.WindowSize.x;
                w.winY = s.WindowSize.y;
            }
            _WrapperEnd(api, wasLoaded);
        } catch {
            w.ok = false;
        }
        return w;
    }

    Json::Value@ _DisplayWatchJson(DisplayWatch@ w) {
        Json::Value o = Json::Object();
        o["available"] = w.ok;
        if (w.ok) {
            o["dirtyCounter"] = double(w.dirty);
            o["displayMode"] = w.mode;
            Json::Value ws = Json::Array();
            ws.Add(w.winX);
            ws.Add(w.winY);
            o["windowSize"] = ws;
        }
        return o;
    }

    bool _WriteBloomWrapper(int index, string &out err) {
        auto api = _DisplayScriptApi();
        if (api is null) { err = "ManiaPlanetScriptAPI unavailable"; return false; }
        try {
            bool wasLoaded = _WrapperBegin(api);
            auto s = api.DisplaySettings;
            if (s is null) {
                _WrapperEnd(api, wasLoaded);
                err = "DisplaySettings is null after LoadCurrent";
                return false;
            }
            s.FxBloomHdr = CGameDisplaySettingsWrapper::EFxBloomHdr(index);
            api.DisplaySettings_Apply();
            _WrapperEnd(api, wasLoaded);
        } catch {
            err = getExceptionInfo();
            return false;
        }
        return true;
    }

    bool _WriteBloomSystemConfig(int index, string &out err) {
        bool safe;
        auto d = _ActiveDisplayConfig(safe);
        if (d is null) { err = "Viewport.SystemConfig unavailable"; return false; }
        try {
            d.FxBloomHdr = CSystemConfigDisplay::EFxBloomHdr(index);
        } catch {
            err = getExceptionInfo();
            return false;
        }
        return true;
    }

    // Reads both sources back; true when every readable one is `index`.
    bool _BloomReadsBack(int index, Json::Value &inout sources) {
        int w = _ReadBloomWrapper();
        int c = _ReadBloomSystemConfig();
        sources["wrapper"] = _BloomJson(w);
        sources["systemConfig"] = _BloomJson(c);
        uint read = 0, matching = 0;
        if (w >= 0) { read++; if (w == index) matching++; }
        if (c >= 0) { read++; if (c == index) matching++; }
        return BloomWriteVerified(read, matching);
    }

    // Wrapper first, systemConfig fallback. mechanism/notes are filled in.
    bool _ApplyBloom(int index, string &out mechanism, Json::Value &inout output, bool canYield = true) {
        Json::Value attempts = Json::Array();
        bool wrapperAvailable = _DisplayScriptApi() !is null;
        bool wrapperFailed = false;
        Json::Value sources = Json::Object();
        if (ChooseBloomMechanism(wrapperAvailable, false) == "wrapper") {
            string err;
            bool wrote = _WriteBloomWrapper(index, err);
            Json::Value a = Json::Object();
            a["mechanism"] = "wrapper";
            a["wrote"] = wrote;
            if (err.Length > 0) a["error"] = err;
            if (canYield) yield(); // let the apply land before reading back
            a["verified"] = wrote && _BloomReadsBack(index, sources);
            attempts.Add(a);
            wrapperFailed = !bool(a["verified"]);
        }
        mechanism = ChooseBloomMechanism(wrapperAvailable, wrapperFailed);
        if (mechanism == "systemConfig") {
            string err;
            bool wrote = _WriteBloomSystemConfig(index, err);
            Json::Value a = Json::Object();
            a["mechanism"] = "systemConfig";
            a["wrote"] = wrote;
            if (err.Length > 0) a["error"] = err;
            if (canYield) yield();
            a["verified"] = wrote && _BloomReadsBack(index, sources);
            attempts.Add(a);
        }
        output["attempts"] = attempts;
        output["sources"] = sources;
        return bool(attempts[attempts.Length - 1]["verified"]);
    }

    Json::Value@ _BloomStateJson() {
        Json::Value o = Json::Object();
        int w = _ReadBloomWrapper();
        int c = _ReadBloomSystemConfig();
        bool safe;
        _ActiveDisplayConfig(safe);
        Json::Value sources = Json::Object();
        sources["wrapper"] = _BloomJson(w);
        sources["systemConfig"] = _BloomJson(c);
        o["sources"] = sources;
        o["bloom"] = _BloomJson(c >= 0 ? c : w);
        o["sourcesAgree"] = w < 0 || c < 0 || w == c;
        o["isSafeMode"] = safe;
        string prior, setAt;
        if (_DisplayRestoreRecord(prior, setAt)) {
            Json::Value r = Json::Object();
            r["prior"] = prior;
            r["setAt"] = setAt;
            o["pendingRestore"] = r;
        } else {
            o["pendingRestore"] = Json::Value();
        }
        return o;
    }

    Json::Value@ GetDisplaySetting(Json::Value &in input) {
        auto o = _BloomStateJson();
        o["note"] = "Display settings are saved to the user's config. After SetDisplaySetting always call RestoreDisplaySetting.";
        return MakeSuccess(o);
    }

    Json::Value@ SetDisplaySetting(Json::Value &in input) {
        if (!input.HasKey("bloom") || input["bloom"].GetType() != Json::Type::String) {
            return MakeError("bloom is required: none, medium or high", "INVALID_INPUT");
        }
        string wanted = NormalizeBloom(string(input["bloom"]));
        if (wanted.Length == 0) return MakeError("bloom must be none, medium or high", "INVALID_INPUT");
        int index = BloomIndex(wanted);

        Json::Value output = Json::Object();
        int current = _ReadBloomSystemConfig();
        if (current < 0) current = _ReadBloomWrapper();
        if (current < 0) return MakeError("no display config available (no viewport / script API)", "NOT_AVAILABLE", true);
        string prior = BloomName(current);
        output["prior"] = prior;
        output["requested"] = wanted;

        // The restore record goes to disk BEFORE any write; keep the oldest.
        string recPrior, recAt;
        bool recordExists = _DisplayRestoreRecord(recPrior, recAt);
        if (ShouldWriteRestoreRecord(recordExists)) {
            string err;
            if (!_WriteDisplayRestoreRecord(prior, err)) {
                return MakeError("could not write the restore record (" + err + "); nothing was changed", "RESTORE_RECORD_FAILED");
            }
            output["restoreRecord"] = "written";
            output["restoreTo"] = prior;
        } else {
            output["restoreRecord"] = "kept";
            output["restoreTo"] = recPrior;
        }

        if (current == index) {
            output["now"] = wanted;
            output["changed"] = false;
            output["mechanism"] = "none";
            output["restoreWith"] = "RestoreDisplaySetting";
            return MakeSuccess(output);
        }

        auto watchBefore = _ReadDisplayWatch();
        string mechanism;
        bool ok = _ApplyBloom(index, mechanism, output);
        auto watchAfter = _ReadDisplayWatch();
        output["mechanism"] = mechanism;
        output["displayBefore"] = _DisplayWatchJson(watchBefore);
        output["displayAfter"] = _DisplayWatchJson(watchAfter);
        string sideEffects = (watchBefore.ok && watchAfter.ok)
            ? DisplaySideEffects(watchBefore.dirty, watchAfter.dirty, watchBefore.mode, watchAfter.mode,
                                 watchBefore.winX, watchBefore.winY, watchAfter.winX, watchAfter.winY)
            : "unknown";
        output["sideEffects"] = sideEffects;
        output["persisted"] = "assumed";
        output["restoreWith"] = "RestoreDisplaySetting";
        int nowIdx = _ReadBloomSystemConfig();
        output["now"] = _BloomJson(nowIdx);
        output["changed"] = nowIdx >= 0 && nowIdx != current;
        output["runtimeEffect"] = "UNPROVEN: whether the renderer drops bloom immediately is not verified; compare screenshots.";
        if (!ok) {
            auto err = MakeError("bloom write did not read back as " + wanted + " from every source",
                "APPLY_UNVERIFIED", true, "", "The restore record is kept: RestoreDisplaySetting still puts the prior value back.");
            err["output"] = output;
            return err;
        }
        return MakeSuccess(output);
    }

    // Shared by the tool and by plugin start / disable / unload.
    // canYield=false for OnDisabled/OnDestroyed: callbacks, not coroutines.
    Json::Value@ RestoreDisplaySettingCore(bool canYield = true) {
        Json::Value output = Json::Object();
        string prior, setAt;
        bool exists = _DisplayRestoreRecord(prior, setAt);
        int current = _ReadBloomSystemConfig();
        if (current < 0) current = _ReadBloomWrapper();
        string action = RestoreAction(exists, prior, current < 0 ? "" : BloomName(current));
        output["action"] = action;
        if (action == "none") {
            output["restored"] = false;
            output["reason"] = "no record";
            return output;
        }
        output["prior"] = prior;
        output["setAt"] = setAt;
        if (action == "bad") {
            output["restored"] = false;
            output["reason"] = "the restore record is unreadable; kept for a person to inspect: " + _DisplayRestorePath();
            return output;
        }
        if (current < 0) {
            output["restored"] = false;
            output["reason"] = "no display config available yet; record kept";
            return output;
        }
        if (action == "clear") {
            _DeleteDisplayRestoreRecord();
            output["restored"] = true;
            output["changed"] = false;
            output["now"] = BloomName(current);
            return output;
        }
        string mechanism;
        bool ok = _ApplyBloom(BloomIndex(prior), mechanism, output, canYield);
        output["mechanism"] = mechanism;
        int nowIdx = _ReadBloomSystemConfig();
        output["now"] = _BloomJson(nowIdx);
        output["restored"] = ok;
        output["changed"] = ok;
        if (ok) _DeleteDisplayRestoreRecord();
        else output["reason"] = "write did not read back; record kept";
        return output;
    }

    Json::Value@ RestoreDisplaySetting(Json::Value &in input) {
        auto o = RestoreDisplaySettingCore();
        if (o.HasKey("restored") && !bool(o["restored"]) && string(o["action"]) != "none") {
            auto err = MakeError("restore did not complete: " + string(o["reason"]), "RESTORE_FAILED", true);
            err["output"] = o;
            return err;
        }
        return MakeSuccess(o);
    }

    // Plugin lifecycle: never leave the user's bloom changed.
    void RestoreDisplaySettingOnLifecycle(const string &in when) {
        try {
            if (!IO::FileExists(_DisplayRestorePath())) return;
            auto o = RestoreDisplaySettingCore(when == "start");
            trace("TM Control MCP: display restore on " + when + ": " + Json::Write(o));
        } catch {
            warn("TM Control MCP: display restore on " + when + " failed: " + getExceptionInfo());
        }
    }
}
