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
    // Context ids: the host remembers the playground and handler handles it
    // last saw and hands out a new id whenever either differs, null
    // included. The handles are only compared, never dereferenced, and hold
    // no engine reference: keeping a playground alive past its map would be
    // worse than the problem. A map change passes through frames with no
    // playground or a loading screen, and both a running call (after every
    // yield) and the ownership watcher (every frame) read the gate, so they
    // see the change even if a new object later reuses an address.

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

    class PauseNodIds {
        CGamePlayground@ playground;
        CGameScriptHandlerPlaygroundInterface@ handler;
        uint64 playgroundId = 0;
        uint64 handlerId = 0;
        uint64 next = 1;

        uint64 PlaygroundId(CGamePlayground@ pg) {
            if (playground !is pg || (pg !is null && playgroundId == 0)) {
                @playground = pg;
                playgroundId = pg is null ? 0 : next++;
            }
            return playgroundId;
        }

        uint64 HandlerId(CGameScriptHandlerPlaygroundInterface@ h) {
            if (handler !is h || (h !is null && handlerId == 0)) {
                @handler = h;
                handlerId = h is null ? 0 : next++;
            }
            return handlerId;
        }

        void Forget() {
            @playground = null;
            @handler = null;
            playgroundId = 0;
            handlerId = 0;
        }
    }

    PauseNodIds g_pauseNodIds;

    class LivePauseHost : PauseHost {
        uint64 NowMs() { return Time::Now; }
        void Yield() { yield(); }

        PauseGate@ ReadGate() {
            auto g = PauseGate();
            auto app = GetApp();
            auto api = _PauseClientApi();
            auto h = _PauseHandler();
            g.inPlayground = app !is null && app.CurrentPlayground !is null && api !is null && h !is null;
            g.loading = api !is null && api.IsLoadingScreen;
            g.local = app !is null && app.PlaygroundScript !is null;
            if (app !is null && app.Network !is null) {
                auto info = cast<CGameCtnNetServerInfo>(app.Network.ServerInfo);
                g.serverLoginSet = info !is null && info.ServerLogin.Length > 0;
            }
            g.spectatorClient = api !is null && api.IsSpectatorClient;
            g.serverOrSolo = api !is null && api.IsServerOrSolo;
            g.playgroundId = g_pauseNodIds.PlaygroundId(app is null ? null : app.CurrentPlayground);
            g.handlerId = g_pauseNodIds.HandlerId(h);
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

        bool DialogBlocking() {
            auto d = BasicDialogSummary();
            return d.HasKey("blocking") && bool(d["blocking"]);
        }

        void StartWatcher() { startnew(_PauseWatchCoro); }
        void Log(const string &in message) { trace(message); }

        Json::Value@ ExtraState() {
            Json::Value o = Json::Object();
            auto core = GetCmdBufferCore();
            if (core !is null) o["coreSimulationRelativeSpeed"] = core.SimulationRelativeSpeed;
            return o;
        }
    }

    LivePauseHost g_livePauseHost;

    // Runs every frame while this tool owns a menu (PauseCore.as).
    void _PauseWatchCoro() {
        while (PauseWatchStep(g_livePauseHost)) yield();
    }

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
            PauseCallAborted(); // the watcher closes a menu this call opened
            @r = MakeError("ControlPause threw: " + getExceptionInfo(), "tool_exception", true, "",
                "GetPauseState shows the menu; a menu this call opened is closed in the background.");
        }
        if (r.HasKey("output")) {
            r["output"]["mode"] = DetectGameModeName();
            r["output"]["overlay"] = OverlayStateJson();
        }
        return r;
    }

    // Plugin disable / unload (no yield): close a menu this tool still owns.
    void ClosePauseOnLifecycle(const string &in when) {
        try {
            string outcome = PauseCloseOwnedOnShutdown(g_livePauseHost);
            if (outcome != "none") trace("TM Control MCP: in-game menu on " + when + ": " + outcome);
        } catch {
            warn("TM Control MCP: in-game menu close on " + when + " failed: " + getExceptionInfo());
        }
    }
}
