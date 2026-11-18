namespace TmMcp {
    // GetDisplaySetting / SetDisplaySetting / RestoreDisplaySetting: the live
    // game side. The orchestration is in DisplaySettingsCore.as and the pure
    // rules in DisplaySettingsPolicy.as; this file only maps DisplayHost onto
    // the game and the plugin storage folder.
    //
    // Install identity (review 1 F2): SHA-256 over
    //   IO::FromUserGameFolder("")   the game's user folder (Documents/Trackmania)
    //   IO::FromAppFolder("")        the game install folder
    //   IO::FromStorageFolder("")    this plugin's storage folder
    //   SystemConfig.GameProfileName the active config profile
    //   PluginStorage/tm-control-mcp/port.override  (contents, "" if absent)
    // All cheap, stable reads. Only the hash is stored. On x-boss every
    // overlay instance reports the same Windows paths (C:/users/steamuser/...),
    // so the paths alone cannot tell the primary from instance N; tmc writes a
    // per-instance port.override into each instance's private upper dir, and
    // plugin storage written on one can show through on another. Hence the
    // override file is part of the identity: a record from a different
    // instance does not match and is never applied automatically.

    string _DisplayStoragePath(const string &in name) {
        return IO::FromStorageFolder(name);
    }

    CSystemConfigDisplay@ _ActiveDisplayConfig(bool &out safeMode) {
        safeMode = false;
        auto app = GetApp();
        if (app is null || app.Viewport is null || app.Viewport.SystemConfig is null) return null;
        auto cfg = app.Viewport.SystemConfig;
        safeMode = cfg.IsSafeMode;
        return safeMode ? cfg.DisplaySafe : cfg.Display;
    }

    CGameManiaPlanetScriptAPI@ _DisplayScriptApi() {
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return null;
        return app.ManiaPlanetScriptAPI;
    }

    string _ReadSmallFile(const string &in path) {
        if (!IO::FileExists(path)) return "";
        try {
            IO::File f(path, IO::FileMode::Read);
            string text = f.ReadToEnd();
            f.Close();
            return text.Length > 256 ? text.SubStr(0, 256) : text;
        } catch {
            return "<unreadable>";
        }
    }

    class LiveDisplayHost : DisplayHost {
        // True only between a WrapperLoad that loaded it and WrapperUnload.
        bool loadedByUs = false;

        void Yield() { yield(); }
        string Now() { return Time::FormatString("%Y-%m-%d %H:%M:%S"); }

        string _ProfileName() {
            auto app = GetApp();
            if (app is null || app.Viewport is null || app.Viewport.SystemConfig is null) return "";
            return app.Viewport.SystemConfig.GameProfileName;
        }

        string InstallIdentity() {
            string user = IO::FromUserGameFolder("");
            string appDir = IO::FromAppFolder("");
            string storage = IO::FromStorageFolder("");
            if (user.Length == 0 && appDir.Length == 0) return "";
            string portMark = _ReadSmallFile(IO::FromStorageFolder("port.override")).Trim();
            return Crypto::Sha256("tm-control-mcp display identity v1\n" + user + "\n" + appDir + "\n" + storage
                + "\n" + _ProfileName() + "\n" + portMark).ToLower();
        }

        Json::Value@ IdentityJson() {
            Json::Value o = Json::Object();
            o["fingerprint"] = InstallIdentity();
            o["from"] = "sha256(user game folder, app folder, plugin storage folder, SystemConfig.GameProfileName, port.override)";
            o["portOverridePresent"] = IO::FileExists(IO::FromStorageFolder("port.override"));
            return o;
        }

        bool SafeMode() {
            bool safe;
            _ActiveDisplayConfig(safe);
            return safe;
        }

        int ReadSystemConfig() {
            bool safe;
            auto d = _ActiveDisplayConfig(safe);
            if (d is null) return -1;
            return int(d.FxBloomHdr);
        }

        bool WriteSystemConfig(int index, string &out err) {
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

        bool ScriptApiAvailable() { return _DisplayScriptApi() !is null; }

        bool WrapperLoadedByOther() {
            auto api = _DisplayScriptApi();
            return api !is null && api.DisplaySettings !is null && !loadedByUs;
        }

        bool WrapperLoad(string &out err) {
            auto api = _DisplayScriptApi();
            if (api is null) { err = "ManiaPlanetScriptAPI unavailable"; return false; }
            if (api.DisplaySettings !is null) { err = "already loaded by someone else"; return false; }
            try {
                api.DisplaySettings_LoadCurrent();
                loadedByUs = true;
            } catch {
                err = getExceptionInfo();
                loadedByUs = api.DisplaySettings !is null;
                if (loadedByUs) WrapperUnload();
                return false;
            }
            if (api.DisplaySettings is null) {
                err = "DisplaySettings is null after LoadCurrent";
                WrapperUnload();
                return false;
            }
            return true;
        }

        int WrapperRead() {
            auto api = _DisplayScriptApi();
            if (api is null || api.DisplaySettings is null) return -1;
            try {
                return int(api.DisplaySettings.FxBloomHdr);
            } catch {
                return -1;
            }
        }

        // Only on a wrapper this host loaded (DisplaySettingsCore checks).
        bool WrapperWriteApply(int index, string &out err) {
            auto api = _DisplayScriptApi();
            if (api is null || api.DisplaySettings is null || !loadedByUs) { err = "no wrapper loaded by this tool"; return false; }
            try {
                api.DisplaySettings.FxBloomHdr = CGameDisplaySettingsWrapper::EFxBloomHdr(index);
                api.DisplaySettings_Apply();
            } catch {
                err = getExceptionInfo();
                return false;
            }
            return true;
        }

        void WrapperUnload() {
            if (!loadedByUs) return;
            loadedByUs = false;
            auto api = _DisplayScriptApi();
            if (api is null) return;
            try { api.DisplaySettings_Unload(); } catch { warn("TM Control MCP: DisplaySettings_Unload failed: " + getExceptionInfo()); }
        }

        // DirtyCounter / DisplayMode / WindowSize, from a wrapper this host
        // loads (never someone else's: Set refuses those before this runs).
        DisplayWatch@ WrapperWatch() {
            auto w = DisplayWatch();
            string err;
            if (!WrapperLoad(err)) return w;
            try {
                auto s = _DisplayScriptApi().DisplaySettings;
                w.ok = true;
                w.dirty = s.DirtyCounter;
                w.mode = int(s.DisplayMode);
                w.winX = s.WindowSize.x;
                w.winY = s.WindowSize.y;
            } catch {
                w.ok = false;
            }
            WrapperUnload();
            return w;
        }

        bool FileExists(const string &in name) { return IO::FileExists(_DisplayStoragePath(name)); }

        bool FileRead(const string &in name, string &out text, string &out err) {
            text = "";
            string path = _DisplayStoragePath(name);
            if (!IO::FileExists(path)) { err = "missing"; return false; }
            try {
                IO::File f(path, IO::FileMode::Read);
                if (f.Size() > DISPLAY_RECORD_MAX_BYTES) {
                    f.Close();
                    text = "";
                    err = "larger than " + DISPLAY_RECORD_MAX_BYTES + " bytes";
                    return false;
                }
                text = f.ReadToEnd();
                f.Close();
            } catch {
                err = getExceptionInfo();
                return false;
            }
            return true;
        }

        bool FileWrite(const string &in name, const string &in text, string &out err) {
            try {
                IO::File f(_DisplayStoragePath(name), IO::FileMode::Write);
                f.Write(text);
                f.Flush();
                f.Close();
            } catch {
                err = getExceptionInfo();
                return false;
            }
            return true;
        }

        bool FileMove(const string &in from, const string &in to, string &out err) {
            try {
                IO::Move(_DisplayStoragePath(from), _DisplayStoragePath(to));
            } catch {
                err = getExceptionInfo();
                return false;
            }
            return IO::FileExists(_DisplayStoragePath(to));
        }

        bool FileDelete(const string &in name, string &out err) {
            string path = _DisplayStoragePath(name);
            try {
                if (IO::FileExists(path)) IO::Delete(path);
            } catch {
                err = getExceptionInfo();
                return false;
            }
            if (IO::FileExists(path)) { err = "still present after delete"; return false; }
            return true;
        }

        string FilePath(const string &in name) { return _DisplayStoragePath(name); }
        void Log(const string &in message) { trace(message); }
    }

    LiveDisplayHost g_liveDisplayHost;

    Json::Value@ GetDisplaySetting(Json::Value &in input) {
        return GetDisplaySettingCore(g_liveDisplayHost);
    }

    Json::Value@ SetDisplaySetting(Json::Value &in input) {
        Json::Value@ r;
        try {
            @r = SetDisplaySettingCore(g_liveDisplayHost, input);
        } catch {
            @r = MakeError("SetDisplaySetting threw: " + getExceptionInfo(), "tool_exception", true);
        }
        g_liveDisplayHost.WrapperUnload(); // a wrapper this tool loaded never outlives the call
        return r;
    }

    Json::Value@ RestoreDisplaySetting(Json::Value &in input) {
        Json::Value@ r;
        try {
            @r = RestoreDisplaySettingTool(g_liveDisplayHost, input);
        } catch {
            @r = MakeError("RestoreDisplaySetting threw: " + getExceptionInfo(), "tool_exception", true);
        }
        g_liveDisplayHost.WrapperUnload();
        return r;
    }

    // Plugin lifecycle: start (a coroutine), disable and unload (callbacks).
    void RestoreDisplaySettingOnLifecycle(const string &in when) {
        try {
            auto o = RestoreDisplaySettingOnLifecycleCore(g_liveDisplayHost, when);
            if (o !is null) trace("TM Control MCP: display restore on " + when + ": " + Json::Write(o));
        } catch {
            warn("TM Control MCP: display restore on " + when + " failed: " + getExceptionInfo());
        }
        g_liveDisplayHost.WrapperUnload();
    }
}
