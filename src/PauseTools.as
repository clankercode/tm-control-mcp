namespace TmMcp {
    // GetPauseState / ControlPause: pause and resume the game without OS input.
    // Pure rules are in PausePolicy.as.
    //
    // Mechanism: the game's own in-game (ESC) menu, opened and closed through
    // the native procs on app.Network.PlaygroundInterfaceScriptHandler:
    // ShowInGameMenu() and CloseInGameMenu(EInGameMenuResult::Resume). That
    // is the only pause the public API has (no GamePaused / SetPause member
    // exists; GetCmdBufferCore() clocks are read-only). It only stops time
    // where the mode script runs locally, so the locality gate refuses online
    // play BEFORE anything opens, and success is judged on the clocks:
    //   client GameTime     app.Network.PlaygroundClientScriptAPI.GameTime (int)
    //   core SimulationTime GetCmdBufferCore().SimulationTime (uint)
    //   core GameTime       GetCmdBufferCore().GameTime (uint)
    // The only close result used here is Resume. Quit would leave the map;
    // the sub-menu results open other pages that this tool cannot close again.
    //
    // UNPROVEN live (2026-11-18): that a programmatic ShowInGameMenu freezes
    // the clocks like ESC does (Q1). ESC in solo was measured to freeze all
    // three (research/tm2020/2026-11-17-EffectClockAndGamePause.md).

    const uint PAUSE_CLOCK_COUNT = 3;
    string PauseClockName(uint i) {
        if (i == 0) return "clientGameTime";
        if (i == 1) return "coreSimulationTime";
        return "coreGameTime";
    }

    // In memory only: whether the menu that is up was opened by this tool.
    bool g_pauseOpenedByTool = false;
    uint g_pauseToken = 0;
    uint64 g_pauseOpenedAt = 0;
    array<uint> g_pausedClockValues(PAUSE_CLOCK_COUNT, 0);
    array<bool> g_pausedClockHave(PAUSE_CLOCK_COUNT, false);
    int g_autoResumeMs = 0;

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

    bool _PauseMenuShown() {
        auto api = _PauseClientApi();
        if (api !is null) return api.IsInGameMenuDisplayed;
        auto h = _PauseHandler();
        return h !is null && h.IsInGameMenuDisplayed;
    }

    bool _ReadPauseClock(uint idx, uint &out value) {
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

    class PauseClockWindow {
        array<bool> have;
        array<bool> lost;
        array<uint> first;
        array<uint> last;
        array<uint> changes;
        array<uint64> lastChangeAt;
        uint64 startedAt = 0;
        uint64 endedAt = 0;
        uint frames = 0;

        PauseClockWindow() {
            have.Resize(PAUSE_CLOCK_COUNT);
            lost.Resize(PAUSE_CLOCK_COUNT);
            first.Resize(PAUSE_CLOCK_COUNT);
            last.Resize(PAUSE_CLOCK_COUNT);
            changes.Resize(PAUSE_CLOCK_COUNT);
            lastChangeAt.Resize(PAUSE_CLOCK_COUNT);
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                have[i] = false; lost[i] = false; first[i] = 0; last[i] = 0; changes[i] = 0; lastChangeAt[i] = 0;
            }
        }

        void Observe() {
            uint64 now = Time::Now;
            if (startedAt == 0) startedAt = now;
            endedAt = now;
            frames++;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                uint v = 0;
                if (!_ReadPauseClock(i, v)) {
                    if (have[i]) lost[i] = true;
                    continue;
                }
                if (!have[i]) {
                    have[i] = true;
                    first[i] = v;
                    last[i] = v;
                    lastChangeAt[i] = now;
                    continue;
                }
                if (v != last[i]) {
                    changes[i]++;
                    lastChangeAt[i] = now;
                    last[i] = v;
                }
            }
        }

        uint Available() {
            uint n = 0;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (have[i] && !lost[i]) n++;
            return n;
        }

        uint Changed() {
            uint n = 0;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (have[i] && !lost[i] && changes[i] > 0) n++;
            return n;
        }

        uint WindowMs() {
            return uint(endedAt - startedAt);
        }

        string Verdict(uint holdMs) {
            return PauseVerdict(Available(), Changed(), WindowMs(), holdMs);
        }

        Json::Value@ ToJson() {
            Json::Value clocks = Json::Object();
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                Json::Value c = Json::Object();
                c["available"] = have[i] && !lost[i];
                if (have[i]) {
                    c["value"] = double(last[i]);
                    c["advancedMs"] = double(ClockForwardDelta(first[i], last[i]));
                    c["changesInWindow"] = int(changes[i]);
                    c["msSinceChange"] = double(endedAt - lastChangeAt[i]);
                }
                clocks[PauseClockName(i)] = c;
            }
            auto core = GetCmdBufferCore();
            if (core !is null) clocks["coreSimulationRelativeSpeed"] = core.SimulationRelativeSpeed;
            return clocks;
        }
    }

    // Samples once per frame for windowMs (0 = one sample).
    PauseClockWindow@ _SamplePauseClocks(uint windowMs) {
        auto w = PauseClockWindow();
        w.Observe();
        if (windowMs == 0) return w;
        while (w.WindowMs() < windowMs) {
            yield();
            w.Observe();
        }
        return w;
    }

    Json::Value@ _PauseLocalityJson(bool &out inPlayground, bool &out loading, bool &out local,
                                    bool &out serverLoginSet, bool &out spectatorClient) {
        auto app = GetApp();
        auto api = _PauseClientApi();
        auto h = _PauseHandler();
        inPlayground = app !is null && app.CurrentPlayground !is null && api !is null && h !is null;
        loading = api !is null && api.IsLoadingScreen;
        local = app !is null && app.PlaygroundScript !is null;
        serverLoginSet = false;
        if (app !is null && app.Network !is null) {
            auto info = cast<CGameCtnNetServerInfo>(app.Network.ServerInfo);
            serverLoginSet = info !is null && info.ServerLogin.Length > 0;
        }
        spectatorClient = api !is null && api.IsSpectatorClient;
        Json::Value o = Json::Object();
        o["inPlayground"] = inPlayground;
        o["isLoadingScreen"] = loading;
        o["playgroundScriptLocal"] = local;
        o["serverLoginSet"] = serverLoginSet; // the login itself is not reported
        o["isSpectatorClient"] = spectatorClient;
        o["isServerOrSolo"] = api !is null && api.IsServerOrSolo; // reported only, never decides
        return o;
    }

    Json::Value@ _PauseOwnershipJson() {
        Json::Value o = Json::Object();
        o["openedBy"] = g_pauseOpenedByTool ? "tool" : (_PauseMenuShown() ? "other" : "none");
        if (g_pauseOpenedByTool) {
            o["openedForMs"] = double(Time::Now - g_pauseOpenedAt);
            o["autoResumeAfterMs"] = g_autoResumeMs;
        }
        return o;
    }

    Json::Value@ GetPauseState(Json::Value &in input) {
        bool given = input.HasKey("sampleMs");
        int sampleMs = ClampPauseSampleMs(given ? int(input["sampleMs"]) : 0, given);
        bool inPg, loading, local, loginSet, spec;
        Json::Value output = Json::Object();
        output["mode"] = DetectGameModeName();
        output["locality"] = _PauseLocalityJson(inPg, loading, local, loginSet, spec);
        string refusal = PauseRefusalCode(inPg, loading, local, loginSet, spec);
        output["pausable"] = refusal.Length == 0;
        if (refusal.Length > 0) output["notPausableReason"] = PauseRefusalReason(refusal, local, loginSet, spec);
        output["menuShown"] = _PauseMenuShown();
        output["ownership"] = _PauseOwnershipJson();
        auto w = _SamplePauseClocks(uint(sampleMs));
        output["sampleMs"] = sampleMs;
        output["windowMs"] = int(w.WindowMs());
        output["frames"] = int(w.frames);
        output["clocks"] = w.ToJson();
        // sampleMs=0 is one snapshot: no proof either way.
        output["verdict"] = sampleMs == 0 ? PAUSE_VERDICT_UNKNOWN : w.Verdict(uint(sampleMs));
        output["note"] = "verdict comes from the clocks, never from menuShown: online the menu shows while the game runs.";
        return MakeSuccess(output);
    }

    bool _WaitMenuShown(bool wanted, uint timeoutMs, bool reopen) {
        auto h = _PauseHandler();
        uint64 t0 = Time::Now;
        while (_PauseMenuShown() != wanted) {
            if (Time::Now - t0 >= timeoutMs) return false;
            // ShowInGameMenu can need more than one call/frame to take
            // (tm-minimap ScreenshotWizard.as loops it the same way).
            if (reopen && h !is null) h.ShowInGameMenu();
            yield();
            @h = _PauseHandler();
        }
        return true;
    }

    void _PauseRecordClocks(PauseClockWindow@ w) {
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
            g_pausedClockHave[i] = w.have[i] && !w.lost[i];
            g_pausedClockValues[i] = w.last[i];
        }
    }

    // The only way this file closes the in-game menu.
    void _CloseMenuResume() {
        auto h = _PauseHandler();
        if (h is null) return;
        h.CloseInGameMenu(CGameScriptHandlerPlaygroundInterface::EInGameMenuResult::Resume);
    }

    void _PauseForget() {
        g_pauseOpenedByTool = false;
        g_autoResumeMs = 0;
        g_pauseToken++;
    }

    void _PauseAutoResumeCoro() {
        uint token = g_pauseToken;
        uint64 dueAt = g_pauseOpenedAt + uint64(g_autoResumeMs);
        while (Time::Now < dueAt) {
            yield();
            if (g_pauseToken != token) return;
        }
        if (!AutoResumeShouldFire(token, g_pauseToken, g_pauseOpenedByTool, _PauseMenuShown())) return;
        trace("TM Control MCP: autoResumeAfterMs elapsed, resuming the pause this tool made");
        _CloseMenuResume();
        _PauseForget();
    }

    Json::Value@ ControlPause(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "";
        if (!IsValidPauseAction(action)) {
            return MakeError("action must be pause, resume or toggle", "INVALID_INPUT");
        }
        bool hGiven = input.HasKey("holdMs");
        uint holdMs = uint(ClampPauseHoldMs(hGiven ? int(input["holdMs"]) : 0, hGiven));
        bool tGiven = input.HasKey("timeoutMs");
        uint timeoutMs = uint(ClampPauseTimeoutMs(tGiven ? int(input["timeoutMs"]) : 0, tGiven));
        bool aGiven = input.HasKey("autoResumeAfterMs");
        int autoResumeMs = ClampAutoResumeMs(aGiven ? int(input["autoResumeAfterMs"]) : 0, aGiven);

        bool inPg, loading, local, loginSet, spec;
        Json::Value output = Json::Object();
        output["action"] = action;
        output["mode"] = DetectGameModeName();
        output["locality"] = _PauseLocalityJson(inPg, loading, local, loginSet, spec);
        output["overlay"] = OverlayStateJson();

        // Locality gate BEFORE any menu call. Refusals touch nothing.
        string refusal = PauseRefusalCode(inPg, loading, local, loginSet, spec);
        if (refusal.Length > 0) {
            output["changed"] = false;
            auto err = MakeError("ControlPause refused: " + PauseRefusalReason(refusal, local, loginSet, spec),
                refusal, refusal == "LOADING", refusal == "NO_PLAYGROUND" ? "Race" : "",
                "GetPauseState reports the clocks without changing anything.");
            err["output"] = output;
            return err;
        }

        bool menuBefore = _PauseMenuShown();
        auto before = _SamplePauseClocks(holdMs);
        string verdictBefore = before.Verdict(holdMs);
        string resolved = ResolvePauseAction(action, menuBefore);
        string plan = PausePlan(resolved, menuBefore, verdictBefore);
        output["resolvedAction"] = resolved;
        output["plan"] = plan;
        output["menuShownBefore"] = menuBefore;
        output["verdictBefore"] = verdictBefore;
        output["clocksBefore"] = before.ToJson();
        output["holdMs"] = int(holdMs);

        if (plan == "noop") {
            output["changed"] = false;
            output["paused"] = resolved == "pause";
            output["ownership"] = _PauseOwnershipJson();
            return MakeSuccess(output);
        }

        if (plan == "verify") {
            output["changed"] = false;
            output["ownership"] = _PauseOwnershipJson();
            if (resolved == "pause") {
                // The menu is up but time runs: online-like, or someone else's
                // menu. Not ours to close.
                auto err = MakeError("The in-game menu is up but the clocks are still running ("
                    + verdictBefore + "). Not paused; the menu was left as it was.", "NOT_PAUSED");
                err["output"] = output;
                return err;
            }
            auto err = MakeError("No in-game menu is up but the clocks are not running ("
                + verdictBefore + "): nothing this tool can close. Check GetMode / loading / finish screen.",
                "RESUME_UNVERIFIED", true);
            err["output"] = output;
            return err;
        }

        if (plan == "open") {
            auto h = _PauseHandler();
            if (h is null) return MakeError("PlaygroundInterfaceScriptHandler unavailable", "NO_PLAYGROUND", true, "Race");
            h.ShowInGameMenu();
            bool shown = _WaitMenuShown(true, timeoutMs, true);
            // The pause can take effect a frame or two after the menu shows:
            // take back-to-back hold windows until one is frozen or timeoutMs.
            uint64 tFreeze = Time::Now;
            auto after = _SamplePauseClocks(holdMs);
            string verdictAfter = after.Verdict(holdMs);
            uint windows = 1;
            while (shown && verdictAfter != PAUSE_VERDICT_FROZEN && Time::Now - tFreeze < timeoutMs) {
                @after = _SamplePauseClocks(holdMs);
                verdictAfter = after.Verdict(holdMs);
                windows++;
            }
            output["holdWindows"] = int(windows);
            string code = PauseOutcomeCode(shown && _PauseMenuShown(), verdictAfter);
            output["menuShown"] = _PauseMenuShown();
            output["verdict"] = verdictAfter;
            output["clocks"] = after.ToJson();
            if (code.Length > 0) {
                // Put back what we found: close the menu this call opened.
                if (_PauseMenuShown()) {
                    _CloseMenuResume();
                    _WaitMenuShown(false, timeoutMs, false);
                }
                output["changed"] = false;
                output["paused"] = false;
                output["menuClosedAgain"] = !_PauseMenuShown();
                auto err = MakeError(code == "MENU_NOT_SHOWN"
                    ? "ShowInGameMenu did not bring the in-game menu up within timeoutMs."
                    : "The in-game menu opened but the clocks kept running (" + verdictAfter
                        + "): not paused. The menu was closed again.", code, code == "MENU_NOT_SHOWN");
                err["output"] = output;
                return err;
            }
            g_pauseToken++;
            g_pauseOpenedByTool = true;
            g_pauseOpenedAt = Time::Now;
            g_autoResumeMs = autoResumeMs;
            _PauseRecordClocks(after);
            if (autoResumeMs > 0) startnew(_PauseAutoResumeCoro);
            output["changed"] = true;
            output["paused"] = true;
            output["ownership"] = _PauseOwnershipJson();
            return MakeSuccess(output);
        }

        // plan == "close"
        bool openedByTool = g_pauseOpenedByTool;
        uint64 pausedAt = g_pauseOpenedAt;
        array<uint> pausedValues = g_pausedClockValues;
        array<bool> pausedHave = g_pausedClockHave;
        if (!openedByTool) {
            // Someone else's pause: use the values sampled just now.
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                pausedHave[i] = before.have[i] && !before.lost[i];
                pausedValues[i] = before.last[i];
            }
        }
        output["openedBy"] = openedByTool ? "tool" : "other";
        _CloseMenuResume();
        bool closed = _WaitMenuShown(false, timeoutMs, false);

        // First new value per clock after the close = the resume step.
        Json::Value jumps = Json::Object();
        array<bool> seen(PAUSE_CLOCK_COUNT, false);
        uint64 t0 = Time::Now;
        uint seenCount = 0, wantCount = 0;
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (pausedHave[i]) wantCount++;
        while (closed && seenCount < wantCount && Time::Now - t0 < timeoutMs) {
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                if (!pausedHave[i] || seen[i]) continue;
                uint v = 0;
                if (!_ReadPauseClock(i, v) || v == pausedValues[i]) continue;
                seen[i] = true;
                seenCount++;
                jumps[PauseClockName(i)] = ClockJumpMs(pausedValues[i], v);
            }
            if (seenCount < wantCount) yield();
        }
        auto after = _SamplePauseClocks(holdMs);
        string verdictAfter = after.Verdict(holdMs);
        string code = ResumeOutcomeCode(_PauseMenuShown(), verdictAfter);
        output["menuShown"] = _PauseMenuShown();
        output["verdict"] = verdictAfter;
        output["clocks"] = after.ToJson();
        output["jumpMs"] = jumps;
        if (openedByTool) output["wallPausedMs"] = double(t0 - pausedAt);
        if (code.Length > 0) {
            output["changed"] = !_PauseMenuShown();
            auto err = MakeError(code == "MENU_SUBPAGE_OPEN"
                ? "CloseInGameMenu(Resume) did not close the menu (a sub-page such as settings may be open). Nothing else was clicked."
                : "The menu closed but the clocks did not start again within timeoutMs (" + verdictAfter + ").",
                code, true);
            err["output"] = output;
            if (!_PauseMenuShown()) _PauseForget();
            return err;
        }
        _PauseForget();
        output["changed"] = true;
        output["paused"] = false;
        return MakeSuccess(output);
    }
}
