namespace TmMcp {
    // GetDisplaySetting / SetDisplaySetting / RestoreDisplaySetting: the live
    // game side. The orchestration is in DisplaySettingsCore.as and the pure
    // rules in DisplaySettingsPolicy.as; this file only maps DisplayHost onto
    // the game and the plugin storage folder. Nothing here yields.
    //
    // Install identity (B3): SHA-256 over
    //   IO::FromUserGameFolder("")   the game's user folder (Documents/Trackmania)
    //   IO::FromAppFolder("")        the game install folder
    //   IO::FromStorageFolder("")    this plugin's storage folder
    //   SystemConfig.GameProfileName the active config profile
    //   PluginStorage/tm-control-mcp/port.override  (trimmed contents)
    //   display | safe               the config block in effect (IsSafeMode)
    // Only the hash is stored. It fails closed: with no readable, non-empty
    // port.override the identity is unknown and SetDisplaySetting refuses
    // (IDENTITY_UNKNOWN). tmc writes a port.override into every leased
    // instance's private upper dir; the primary prefix (Max's own game) has
    // none, so it never gets a Set. On x-boss every overlay instance reports
    // the same Windows paths (C:/users/steamuser/...), which is why the
    // override is the part that tells instances apart. Two prefixes with the
    // same override contents still collide (documented limit).

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

    class LiveDisplayHost : DisplayHost {
        // The wrapper this host loaded, kept until it is seen released. The
        // handle is only compared, never dereferenced (writes go through
        // api.DisplaySettings after an `is` check). Limit: if an Unload that
        // reported failure did free it and a new wrapper later reused the
        // address before the next call, that wrapper would be taken for ours.
        CGameDisplaySettingsWrapper@ ownWrapper = null;

        void Yield() { yield(); }
        string Now() { return Time::FormatString("%Y-%m-%d %H:%M:%S"); }

        string _ProfileName() {
            auto app = GetApp();
            if (app is null || app.Viewport is null || app.Viewport.SystemConfig is null) return "";
            return app.Viewport.SystemConfig.GameProfileName;
        }

        // false + why when port.override is absent, unreadable or empty.
        bool _PortMark(string &out mark, string &out why) {
            mark = "";
            why = "";
            string path = IO::FromStorageFolder("port.override");
            if (!IO::FileExists(path)) { why = "no port.override in plugin storage (not a leased tmc instance)"; return false; }
            try {
                IO::File f(path, IO::FileMode::Read);
                mark = f.ReadToEnd().Trim();
                f.Close();
            } catch {
                why = "port.override is unreadable: " + getExceptionInfo();
                return false;
            }
            if (mark.Length == 0 || mark.Length > 64) { why = "port.override is empty or too long"; return false; }
            return true;
        }

        bool InstallIdentity(string &out identity, string &out why) {
            identity = "";
            string mark;
            if (!_PortMark(mark, why)) return false;
            string user = IO::FromUserGameFolder("");
            string appDir = IO::FromAppFolder("");
            string storage = IO::FromStorageFolder("");
            if (user.Length == 0 && appDir.Length == 0) { why = "the game folders are unknown"; return false; }
            identity = Crypto::Sha256("tm-control-mcp display identity v2\n" + user + "\n" + appDir + "\n" + storage
                + "\n" + _ProfileName() + "\n" + mark + "\n" + DisplayConfigName(SafeMode())).ToLower();
            return true;
        }

        Json::Value@ IdentityJson() {
            Json::Value o = Json::Object();
            string identity, why;
            bool known = InstallIdentity(identity, why);
            o["known"] = known;
            if (known) o["fingerprint"] = identity;
            else o["unknownBecause"] = why;
            o["from"] = "sha256(user game folder, app folder, plugin storage folder, SystemConfig.GameProfileName,"
                + " port.override, display|safe)";
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
            if (BloomName(index).Length == 0) { err = "not a bloom index: " + index; return false; }
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

        int WrapperOwner() {
            auto api = _DisplayScriptApi();
            if (api is null) return DISPLAY_WRAPPER_NONE;
            return DisplayWrapperOwner(api.DisplaySettings !is null, ownWrapper !is null,
                                       ownWrapper !is null && api.DisplaySettings is ownWrapper);
        }

        bool WrapperLoad(string &out err) {
            auto api = _DisplayScriptApi();
            if (api is null) { err = "ManiaPlanetScriptAPI unavailable"; return false; }
            if (api.DisplaySettings !is null) { err = "a DisplaySettings wrapper is already loaded"; return false; }
            try {
                api.DisplaySettings_LoadCurrent();
            } catch {
                err = getExceptionInfo();
            }
            // Claim whatever this call loaded, at once, so it is released.
            @ownWrapper = api.DisplaySettings;
            if (ownWrapper is null) {
                // Not there without a frame: the wrapper path is not used this
                // call (no yield). Undo the request in case it lands later.
                if (err.Length == 0) err = "DisplaySettings is null after LoadCurrent (it would need a frame)";
                try { api.DisplaySettings_Unload(); } catch {}
                return false;
            }
            return err.Length == 0;
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

        bool WrapperWriteApply(int index, string &out err) {
            if (BloomName(index).Length == 0) { err = "not a bloom index: " + index; return false; }
            auto api = _DisplayScriptApi();
            if (api is null || ownWrapper is null || api.DisplaySettings !is ownWrapper) {
                err = "no wrapper loaded by this tool";
                return false;
            }
            try {
                api.DisplaySettings.FxBloomHdr = CGameDisplaySettingsWrapper::EFxBloomHdr(index);
                api.DisplaySettings_Apply();
            } catch {
                err = getExceptionInfo();
                return false;
            }
            return true;
        }

        // Releases only the wrapper this host loaded; the claim is dropped
        // only once the API no longer exposes that wrapper.
        bool WrapperRelease(string &out err) {
            err = "";
            if (ownWrapper is null) return true;
            auto api = _DisplayScriptApi();
            if (api is null) { err = "ManiaPlanetScriptAPI unavailable"; return false; }
            if (api.DisplaySettings !is ownWrapper) {
                // Gone, or replaced by someone else's (never unloaded here).
                @ownWrapper = null;
                return true;
            }
            try { api.DisplaySettings_Unload(); } catch { err = getExceptionInfo(); }
            if (api.DisplaySettings is ownWrapper) {
                if (err.Length == 0) err = "still loaded after DisplaySettings_Unload";
                return false;
            }
            @ownWrapper = null;
            return true;
        }

        // DirtyCounter / DisplayMode / WindowSize from the wrapper this host
        // has loaded right now (never someone else's).
        DisplayWatch@ WrapperWatch() {
            auto w = DisplayWatch();
            auto api = _DisplayScriptApi();
            if (api is null || ownWrapper is null || api.DisplaySettings !is ownWrapper) return w;
            try {
                auto s = api.DisplaySettings;
                w.dirty = s.DirtyCounter;
                w.mode = int(s.DisplayMode);
                w.winX = s.WindowSize.x;
                w.winY = s.WindowSize.y;
                w.ok = true;
            } catch {
                w.ok = false;
            }
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
        return SetDisplaySettingCore(g_liveDisplayHost, input);
    }

    Json::Value@ RestoreDisplaySetting(Json::Value &in input) {
        return RestoreDisplaySettingTool(g_liveDisplayHost, input);
    }

    // Plugin start / disable / unload (no yield): never restores bloom.
    // Releases a wrapper this tool still holds and logs a pending record.
    void DisplaySettingsOnLifecycle(const string &in when) {
        try {
            string done = DisplayLifecycleCore(g_liveDisplayHost, when);
            if (done.Length > 0) trace("TM Control MCP: display settings on " + when + ": " + done);
        } catch {
            warn("TM Control MCP: display settings on " + when + " failed: " + getExceptionInfo());
        }
    }
}
