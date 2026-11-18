namespace TmMcp {
    // GetPauseState / ControlPause: the live game side. The orchestration is
    // in PauseCore.as and the pure rules in PausePolicy.as; this file only
    // maps PauseHost onto the game.
    //
    // Mechanism: the game's own in-game (ESC) menu, opened and closed through
    // the native procs on app.Network.PlaygroundInterfaceScriptHandler:
    // ShowInGameMenu() and CloseInGameMenu(EInGameMenuResult::Resume). That
    // is the only pause the public API has (no GamePaused / SetPause member
    // exists; GetCmdBufferCore() clocks are read-only). Clocks:
    //   client GameTime     app.Network.PlaygroundClientScriptAPI.GameTime (int)
    //   core SimulationTime GetCmdBufferCore().SimulationTime (uint)
    //   core GameTime       GetCmdBufferCore().GameTime (uint)
    // The only close result used here is Resume. Quit would leave the map;
    // the sub-menu results open other pages that this tool cannot close again.
    //
    // Context: a call captures the playground and handler handles when it
    // begins and compares them (with `is`, never dereferenced) after every
    // frame. Nothing is kept after the call. A same-address replacement with
    // no loading or empty frame in between would not be seen (documented).

    CGameScriptHandlerPlaygroundInterface@ _PauseHandler() {
        auto app = GetApp();
        if (app is null || app.Network is null) return null;
        return app.Network.PlaygroundInterfaceScriptHandler;
    }

    CGamePlaygroundClientScriptAPI@ _PauseClientApi() {
        auto app = GetApp();
        if (app is null || app.Network is null) return null;
        return app.Network.PlaygroundClientScriptAPI;
    }

    class LivePauseContext : PauseContext {
        CGamePlayground@ playground;
        CGameScriptHandlerPlaygroundInterface@ handler;
    }

    class LivePauseHost : PauseHost {
        uint64 NowMs() { return Time::Now; }
        void Yield() { yield(); }

        PauseContext@ CaptureContext() {
            auto c = LivePauseContext();
            auto app = GetApp();
            @c.playground = app is null ? null : app.CurrentPlayground;
            @c.handler = _PauseHandler();
            return c;
        }

        PauseGate@ ReadGate(PauseContext@ ctx) {
            auto g = PauseGate();
            auto app = GetApp();
            auto api = _PauseClientApi();
            auto h = _PauseHandler();
            auto pg = app is null ? null : app.CurrentPlayground;
            g.inPlayground = pg !is null && api !is null && h !is null;
            g.loading = api !is null && api.IsLoadingScreen;
            g.local = app !is null && app.PlaygroundScript !is null;
            if (app !is null && app.Network !is null) {
                auto info = cast<CGameCtnNetServerInfo>(app.Network.ServerInfo);
                g.serverLoginSet = info !is null && info.ServerLogin.Length > 0;
            }
            g.spectatorClient = api !is null && api.IsSpectatorClient;
            g.serverOrSolo = api !is null && api.IsServerOrSolo;
            auto c = cast<LivePauseContext>(ctx);
            g.sameContext = c !is null && pg !is null && h !is null && c.playground is pg && c.handler is h;
            return g;
        }

        bool MenuShown() {
            auto api = _PauseClientApi();
            if (api !is null) return api.IsInGameMenuDisplayed;
            auto h = _PauseHandler();
            return h !is null && h.IsInGameMenuDisplayed;
        }

        bool ReadClock(uint idx, uint &out value) {
            value = 0;
            auto app = GetApp();
            if (app is null || app.CurrentPlayground is null) return false;
            if (idx == 0) {
                auto api = _PauseClientApi();
                if (api is null || api.IsLoadingScreen) return false;
                value = ClockBits(api.GameTime);
                return true;
            }
            auto core = GetCmdBufferCore();
            if (core is null) return false;
            value = idx == 1 ? core.SimulationTime : core.GameTime;
            return true;
        }

        bool ShowMenu() {
            auto h = _PauseHandler();
            if (h is null) return false;
            h.ShowInGameMenu();
            return true;
        }

        // The only way this file closes the in-game menu.
        bool CloseMenuResume() {
            auto h = _PauseHandler();
            if (h is null) return false;
            h.CloseInGameMenu(CGameScriptHandlerPlaygroundInterface::EInGameMenuResult::Resume);
            return true;
        }

        // BasicDialogs and modal menu frames (DialogPolicy). The in-game menu
        // is a playground UI layer, not one of those frames (assumed; checked
        // in the first live run).
        bool DialogBlocking() {
            auto d = BasicDialogSummary();
            return d.HasKey("blocking") && bool(d["blocking"]);
        }

        void Log(const string &in message) { trace(message); }

        Json::Value@ ExtraState() {
            Json::Value o = Json::Object();
            auto core = GetCmdBufferCore();
            if (core !is null) o["coreSimulationRelativeSpeed"] = core.SimulationRelativeSpeed;
            return o;
        }
    }

    LivePauseHost g_livePauseHost;

    Json::Value@ GetPauseState(Json::Value &in input) {
        auto r = GetPauseStateCore(g_livePauseHost, input);
        if (r.HasKey("output")) r["output"]["mode"] = DetectGameModeName();
        return r;
    }

    Json::Value@ ControlPause(Json::Value &in input) {
        Json::Value@ r;
        try {
            @r = ControlPauseCore(g_livePauseHost, input);
        } catch {
            // Nothing outlives the call: report what is up now.
            @r = MakeError("ControlPause threw: " + getExceptionInfo(), "tool_exception", true, "",
                "Call GetPauseState; if the in-game menu is up, ControlPause resume closes it.");
            Json::Value o = Json::Object();
            o["menuShown"] = g_livePauseHost.MenuShown();
            r["output"] = o;
        }
        try {
            if (r.HasKey("output")) {
                r["output"]["mode"] = DetectGameModeName();
                r["output"]["overlay"] = OverlayStateJson();
            }
        } catch {
            warn("TM Control MCP: ControlPause result decoration failed: " + getExceptionInfo());
        }
        return r;
    }
}
