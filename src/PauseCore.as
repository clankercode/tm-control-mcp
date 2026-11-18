namespace TmMcp {
    // ControlPause / GetPauseState orchestration with no game types: every
    // game read, menu call, clock and yield goes through PauseHost.
    // src/PauseTools.as is the live host; tests/test_pause_tools.py runs this
    // file in stock AngelScript against a scripted fake game.
    //
    // Mechanism: the game's own in-game (ESC) menu, opened with
    // ShowInGameMenu() and closed with CloseInGameMenu(Resume) only. Quit
    // would leave the map; the sub-menu results open pages this tool cannot
    // close again. The menu only stops time where the mode script runs in
    // this game, so the locality gate refuses online play BEFORE anything
    // opens, and success is judged on three clocks, never on the menu flag.
    //
    // Context (F6): the playground and its interface handler are captured as
    // opaque ids at the gate. After every yield, and right before every
    // ShowInGameMenu and every success return, the gate (locality, loading)
    // and the context are checked again; a change stops the call.
    //
    // Ownership (F7/F8): recorded the moment ShowInGameMenu is first called,
    // bound to that context, and watched every frame by a coroutine. It ends
    // when the menu closes (for any reason) or the context changes, so a
    // timer can never close a menu someone else opened later.
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

    // What the game looks like right now, read without yielding.
    class PauseGate {
        bool inPlayground = false;
        bool loading = false;
        bool local = false;
        bool serverLoginSet = false;
        bool spectatorClient = false;
        bool serverOrSolo = false;
        // Opaque, stable while the same playground / handler object lives;
        // 0 when there is none.
        uint64 playgroundId = 0;
        uint64 handlerId = 0;

        string Refusal() {
            return PauseRefusalCode(inPlayground, loading, local, serverLoginSet, spectatorClient);
        }

        bool SameContext(PauseGate@ other) {
            return other !is null && playgroundId != 0 && handlerId != 0
                && playgroundId == other.playgroundId && handlerId == other.handlerId;
        }

        Json::Value@ ToJson() {
            Json::Value o = Json::Object();
            o["inPlayground"] = inPlayground;
            o["isLoadingScreen"] = loading;
            o["playgroundScriptLocal"] = local;
            o["serverLoginSet"] = serverLoginSet; // the login itself is not reported
            o["isSpectatorClient"] = spectatorClient;
            o["isServerOrSolo"] = serverOrSolo; // reported only, never decides
            return o;
        }
    }

    interface PauseHost {
        uint64 NowMs();
        void Yield();
        PauseGate@ ReadGate();
        bool MenuShown();
        bool ReadClock(uint index, uint &out value);
        // false when there is no handler to call.
        bool ShowMenu();
        bool CloseMenuResume();
        bool DialogBlocking();
        // Start the per-frame ownership watcher (PauseWatchStep).
        void StartWatcher();
        void Log(const string &in message);
        // Extra read-only state added to clock reports (may be null).
        Json::Value@ ExtraState();
    }

    // In memory only: the menu this tool opened, if it is still up.
    class PauseOwnership {
        bool owned = false;
        uint token = 0;
        uint64 playgroundId = 0;
        uint64 handlerId = 0;
        uint64 openedAt = 0;     // when the show was attempted
        bool callActive = false; // a ControlPause call is running on it and decides
        uint64 callUntil = 0;    // ...until its deadline (a killed worker cannot hold it)
        uint64 timerFrom = 0;    // autoResumeAfterMs counts from here
        int autoResumeMs = 0;
        bool watching = false;
        uint closeAttempts = 0;
        uint64 lastCloseAt = 0;
        bool closing = false;    // a failed call's cleanup: close it, retrying
        bool gaveUp = false;
        string endedReason = "";
        array<uint> clockValues(PAUSE_CLOCK_COUNT, 0);
        array<bool> clockHave(PAUSE_CLOCK_COUNT, false);
    }

    PauseOwnership g_pause;

    void PauseOwnershipBegin(PauseHost@ host, PauseGate@ ctx, uint64 callDeadline) {
        g_pause.token++;
        g_pause.owned = true;
        g_pause.playgroundId = ctx.playgroundId;
        g_pause.handlerId = ctx.handlerId;
        g_pause.openedAt = host.NowMs();
        g_pause.callActive = true;
        g_pause.callUntil = callDeadline;
        g_pause.timerFrom = g_pause.openedAt;
        g_pause.autoResumeMs = 0;
        g_pause.closeAttempts = 0;
        g_pause.lastCloseAt = 0;
        g_pause.closing = false;
        g_pause.gaveUp = false;
        g_pause.endedReason = "";
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) { g_pause.clockHave[i] = false; g_pause.clockValues[i] = 0; }
        if (!g_pause.watching) {
            g_pause.watching = true;
            host.StartWatcher();
        }
    }

    void PauseOwnershipEnd(const string &in reason) {
        if (!g_pause.owned) return;
        g_pause.owned = false;
        g_pause.callActive = false;
        g_pause.autoResumeMs = 0;
        g_pause.closing = false;
        g_pause.endedReason = reason;
        g_pause.token++;
    }

    // A call that threw or died part-way: hand any menu it opened to the
    // watcher, which closes it (same menu, same context only).
    void PauseCallAborted() {
        if (!g_pause.owned || !g_pause.callActive) return;
        g_pause.callActive = false;
        g_pause.closing = true;
        g_pause.autoResumeMs = 0;
    }

    bool PauseOwnedIn(PauseGate@ ctx) {
        return g_pause.owned && ctx !is null && ctx.playgroundId != 0
            && ctx.playgroundId == g_pause.playgroundId && ctx.handlerId == g_pause.handlerId;
    }

    // One watcher pass; the coroutine calls it once per frame. false = stop.
    bool PauseWatchStep(PauseHost@ host) {
        if (!g_pause.owned) { g_pause.watching = false; return false; }
        auto ctx = host.ReadGate();
        bool same = PauseOwnedIn(ctx);
        bool menu = host.MenuShown();
        uint64 now = host.NowMs();
        bool timerDue = g_pause.closing
            || (g_pause.autoResumeMs > 0 && now >= g_pause.timerFrom + uint64(g_pause.autoResumeMs));
        // Resume is re-sent at most every PAUSE_CLOSE_RETRY_MS.
        bool retryDue = g_pause.lastCloseAt == 0 || now - g_pause.lastCloseAt >= uint64(PAUSE_CLOSE_RETRY_MS);
        if (g_pause.callActive && now > g_pause.callUntil) {
            // The call that owns it never finished (its worker died): treat it
            // like a failed pause and close the menu it opened.
            PauseCallAborted();
            host.Log("TM Control MCP: a ControlPause call did not finish; closing the in-game menu it opened");
        }
        bool callActive = g_pause.callActive;
        string act = PauseWatchAction(true, callActive, same, menu,
                                      timerDue && retryDue && !g_pause.gaveUp, g_pause.closeAttempts);
        if (act == "forget-context") {
            host.Log("TM Control MCP: pause ownership ended: the playground changed");
            PauseOwnershipEnd("context-changed");
            g_pause.watching = false;
            return false;
        }
        if (act == "forget-closed") {
            PauseOwnershipEnd("menu-closed");
            g_pause.watching = false;
            return false;
        }
        if (act == "close") {
            host.Log(g_pause.closing ? "TM Control MCP: closing the in-game menu this tool opened (cleanup retry)"
                                     : "TM Control MCP: autoResumeAfterMs elapsed, resuming the pause this tool made");
            host.CloseMenuResume();
            g_pause.closeAttempts++;
            g_pause.lastCloseAt = now;
        } else if (act == "give-up") {
            host.Log("TM Control MCP: the in-game menu this tool opened did not close after "
                + PAUSE_CLOSE_ATTEMPTS_MAX + " Resume calls; stopped retrying (ownership kept for ControlPause resume)");
            g_pause.gaveUp = true;
        }
        return true;
    }

    Json::Value@ PauseOwnershipJson(PauseHost@ host, PauseGate@ ctx, bool menuShown) {
        Json::Value o = Json::Object();
        bool ours = PauseOwnedIn(ctx);
        o["openedBy"] = ours ? "tool" : (menuShown ? "other" : "none");
        if (ours) {
            o["openedForMs"] = double(host.NowMs() - g_pause.openedAt);
            o["autoResumeAfterMs"] = g_pause.autoResumeMs;
            if (g_pause.autoResumeMs > 0) {
                uint64 due = g_pause.timerFrom + uint64(g_pause.autoResumeMs);
                uint64 now = host.NowMs();
                o["autoResumeInMs"] = double(due > now ? due - now : 0);
            }
            o["pendingClose"] = g_pause.closing;
            o["closeAttempts"] = int(g_pause.closeAttempts);
            if (g_pause.gaveUp) o["closeGaveUp"] = true;
        } else if (g_pause.endedReason.Length > 0) {
            o["lastEnded"] = g_pause.endedReason;
        }
        return o;
    }

    // F5: every clock must be readable when the window starts and on every
    // sample after; an unreadable sample, a loading screen or a context
    // change restarts it. So the window only ever covers time in which all
    // three clocks were continuously read, and frozen needs that coverage to
    // reach holdMs with no clock changing.
    class PauseClockWindow {
        array<uint> first(PAUSE_CLOCK_COUNT, 0);
        array<uint> last(PAUSE_CLOCK_COUNT, 0);
        array<uint> changes(PAUSE_CLOCK_COUNT, 0);
        array<uint64> lastChangeAt(PAUSE_CLOCK_COUNT, 0);
        array<bool> seen(PAUSE_CLOCK_COUNT, false); // read at least once (reporting only)
        array<uint> seenValue(PAUSE_CLOCK_COUNT, 0);
        bool started = false;
        uint64 startedAt = 0;
        uint64 endedAt = 0;
        uint frames = 0;
        uint restarts = 0;
        string lastRestart = "";

        void Restart(const string &in why) {
            if (started) { restarts++; lastRestart = why; }
            started = false;
            startedAt = 0;
            endedAt = 0;
        }

        // canRead: no loading screen and the context is the one the call began in.
        void Observe(PauseHost@ host, bool canRead) {
            uint64 now = host.NowMs();
            frames++;
            if (!canRead) { Restart("loading or context change"); return; }
            array<uint> v(PAUSE_CLOCK_COUNT, 0);
            bool all = true;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                uint x = 0;
                if (host.ReadClock(i, x)) { v[i] = x; seen[i] = true; seenValue[i] = x; }
                else all = false;
            }
            if (!all) { Restart("a clock was unreadable"); return; }
            if (!started) {
                started = true;
                startedAt = now;
                endedAt = now;
                for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                    first[i] = v[i]; last[i] = v[i]; changes[i] = 0; lastChangeAt[i] = now;
                }
                return;
            }
            endedAt = now;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                if (v[i] != last[i]) {
                    changes[i]++;
                    lastChangeAt[i] = now;
                    last[i] = v[i];
                }
            }
        }

        uint Available() {
            return started ? PAUSE_CLOCK_COUNT : 0;
        }

        uint Changed() {
            if (!started) return 0;
            uint n = 0;
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (changes[i] > 0) n++;
            return n;
        }

        uint WindowMs() {
            return started ? uint(endedAt - startedAt) : 0;
        }

        string Verdict(uint holdMs) {
            return PauseVerdict(Available(), Changed(), WindowMs(), holdMs);
        }

        Json::Value@ ToJson(PauseHost@ host) {
            Json::Value clocks = Json::Object();
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                Json::Value c = Json::Object();
                c["available"] = started;
                if (started) {
                    c["value"] = double(last[i]);
                    c["advancedMs"] = double(ClockForwardDelta(first[i], last[i]));
                    c["changesInWindow"] = int(changes[i]);
                    c["msSinceChange"] = double(endedAt - lastChangeAt[i]);
                } else if (seen[i]) {
                    c["value"] = double(seenValue[i]);
                }
                clocks[PauseClockName(i)] = c;
            }
            clocks["windowRestarts"] = int(restarts);
            if (lastRestart.Length > 0) clocks["lastRestart"] = lastRestart;
            auto extra = host.ExtraState();
            if (extra !is null && extra.GetType() == Json::Type::Object) {
                auto keys = extra.GetKeys();
                for (uint k = 0; k < keys.Length; k++) clocks[keys[k]] = extra[keys[k]];
            }
            return clocks;
        }
    }

    // "" while the call may go on, else the stop code.
    string PauseContextStop(PauseHost@ host, PauseGate@ ctx, bool checkDialog) {
        auto g = host.ReadGate();
        string refusal = g.Refusal();
        if (refusal.Length > 0) return refusal;
        if (!ctx.SameContext(g)) return "CONTEXT_CHANGED";
        if (checkDialog && host.DialogBlocking()) return "DIALOG_BLOCKING";
        return "";
    }

    bool _PauseCanRead(PauseHost@ host, PauseGate@ ctx) {
        auto g = host.ReadGate();
        return !g.loading && ctx.SameContext(g);
    }

    // Samples once per frame until the window covers holdMs uninterrupted,
    // limitMs passes, the deadline passes, or the context stops the call.
    PauseClockWindow@ PauseSampleWindow(PauseHost@ host, PauseGate@ ctx, uint holdMs, uint limitMs,
                                        uint64 deadline, string &out stop) {
        stop = "";
        auto w = PauseClockWindow();
        uint64 t0 = host.NowMs();
        w.Observe(host, _PauseCanRead(host, ctx));
        if (holdMs == 0) return w;
        while (w.WindowMs() < holdMs) {
            uint64 now = host.NowMs();
            if (now - t0 >= limitMs || now >= deadline) break;
            host.Yield();
            stop = PauseContextStop(host, ctx, false);
            if (stop.Length > 0) return w;
            w.Observe(host, _PauseCanRead(host, ctx));
        }
        return w;
    }

    // Wait until the menu flag is `wanted`, the deadline passes, or the
    // context stops the call. reopen re-sends ShowInGameMenu each frame (it
    // can take more than one), each time right after a fresh gate check. No
    // dialog check here: the menu being opened must not count as one (the
    // dialog check runs after the initial sample and before the first show).
    bool PauseWaitMenu(PauseHost@ host, PauseGate@ ctx, bool wanted, uint64 deadline, bool reopen,
                       string &out stop) {
        stop = "";
        while (host.MenuShown() != wanted) {
            if (host.NowMs() >= deadline) return false;
            host.Yield();
            stop = PauseContextStop(host, ctx, false);
            if (stop.Length > 0) return host.MenuShown() == wanted;
            if (reopen && host.MenuShown() != wanted) host.ShowMenu();
        }
        return true;
    }

    // Close the menu this call opened: Resume, re-sent every
    // PAUSE_CLOSE_RETRY_MS while this tool still owns that menu in the same
    // context, until it is seen closed or the deadline passes.
    bool PauseCloseOwned(PauseHost@ host, PauseGate@ ctx, uint64 deadline, Json::Value &inout output) {
        uint attempts = 0;
        uint64 lastAt = 0;
        while (host.MenuShown()) {
            auto g = host.ReadGate();
            if (!PauseOwnedIn(g) || !ctx.SameContext(g)) {
                output["cleanupStoppedBecause"] = "the playground changed; Resume was not sent into a different context";
                break;
            }
            uint64 now = host.NowMs();
            if (attempts == 0 || now - lastAt >= uint64(PAUSE_CLOSE_RETRY_MS)) {
                host.CloseMenuResume();
                attempts++;
                lastAt = now;
            }
            if (now >= deadline) break;
            host.Yield();
        }
        output["cleanupResumeCalls"] = int(attempts);
        return !host.MenuShown();
    }

    Json::Value@ _PauseErr(const string &in message, const string &in code, bool retryable,
                           const string &in requiredMode, const string &in hint, Json::Value &in output) {
        auto err = MakeError(message, code, retryable, requiredMode, hint);
        err["output"] = output;
        return err;
    }

    // Stopped before any menu call: nothing changed.
    Json::Value@ _PauseStoppedBeforeAction(PauseHost@ host, const string &in stop, Json::Value &in output) {
        bool menu = host.MenuShown();
        output["changed"] = false;
        output["stoppedAt"] = "before-action";
        output["menuShown"] = menu;
        output["ownership"] = PauseOwnershipJson(host, host.ReadGate(), menu);
        return _PauseErr("ControlPause stopped before acting: " + PauseStopMessage(stop) + ". No menu call was made.",
            stop, stop != "DIALOG_BLOCKING", "", "GetPauseState shows the current menu and clocks.", output);
    }

    Json::Value@ GetPauseStateCore(PauseHost@ host, Json::Value &in input) {
        bool given = input.HasKey("sampleMs");
        int sampleMs = ClampPauseSampleMs(given ? int(input["sampleMs"]) : 0, given);
        auto ctx = host.ReadGate();
        Json::Value output = Json::Object();
        output["locality"] = ctx.ToJson();
        string refusal = ctx.Refusal();
        output["pausable"] = refusal.Length == 0;
        if (refusal.Length > 0) {
            output["notPausableReason"] = PauseRefusalReason(refusal, ctx.local, ctx.serverLoginSet, ctx.spectatorClient);
        }
        bool menu = host.MenuShown();
        output["menuShown"] = menu;
        output["ownership"] = PauseOwnershipJson(host, ctx, menu);
        string stop;
        uint limit = PauseStateSampleLimitMs(uint(sampleMs));
        auto w = PauseSampleWindow(host, ctx, uint(sampleMs), limit, host.NowMs() + uint64(limit), stop);
        output["sampleMs"] = sampleMs;
        output["windowMs"] = int(w.WindowMs());
        output["frames"] = int(w.frames);
        output["clocks"] = w.ToJson(host);
        // sampleMs=0 is one snapshot: no proof either way. Nor is a window
        // cut short by a context change.
        output["verdict"] = (sampleMs == 0 || stop.Length > 0) ? PAUSE_VERDICT_UNKNOWN : w.Verdict(uint(sampleMs));
        if (stop.Length > 0) output["sampleStopped"] = PauseStopMessage(stop);
        output["note"] = "verdict comes from the clocks, never from menuShown: online the menu shows while the game runs.";
        return MakeSuccess(output);
    }

    Json::Value@ ControlPauseCore(PauseHost@ host, Json::Value &in input) {
        string action = input.HasKey("action") && input["action"].GetType() == Json::Type::String
            ? string(input["action"]) : "";
        if (!IsValidPauseAction(action)) {
            return MakeError("action must be pause, resume or toggle", "INVALID_INPUT");
        }
        bool hGiven = input.HasKey("holdMs");
        uint holdMs = uint(ClampPauseHoldMs(hGiven ? int(input["holdMs"]) : 0, hGiven));
        bool tGiven = input.HasKey("timeoutMs");
        uint timeoutMs = uint(ClampPauseTimeoutMs(tGiven ? int(input["timeoutMs"]) : 0, tGiven));
        bool aGiven = input.HasKey("autoResumeAfterMs");
        int autoResumeMs = ClampAutoResumeMs(aGiven ? int(input["autoResumeAfterMs"]) : 0, aGiven);

        // F10: one deadline for the whole call.
        uint64 t0 = host.NowMs();
        uint budgetMs = PauseCallBudgetMs(holdMs, timeoutMs);
        uint64 deadline = t0 + uint64(budgetMs);

        auto ctx = host.ReadGate();
        Json::Value output = Json::Object();
        output["action"] = action;
        output["locality"] = ctx.ToJson();
        output["holdMs"] = int(holdMs);
        output["timeoutMs"] = int(timeoutMs);
        output["budgetMs"] = int(budgetMs);

        // Locality gate BEFORE any menu call. Refusals touch nothing.
        string refusal = ctx.Refusal();
        if (refusal.Length > 0) {
            output["changed"] = false;
            return _PauseErr("ControlPause refused: " + PauseRefusalReason(refusal, ctx.local, ctx.serverLoginSet, ctx.spectatorClient),
                refusal, refusal == "LOADING", refusal == "NO_PLAYGROUND" ? "Race" : "",
                "GetPauseState reports the clocks without changing anything.", output);
        }

        string stop;
        uint64 sampleEnd = t0 + uint64(PauseInitialSampleLimitMs(holdMs));
        auto before = PauseSampleWindow(host, ctx, holdMs, PauseInitialSampleLimitMs(holdMs), sampleEnd, stop);
        output["clocksBefore"] = before.ToJson(host);
        if (stop.Length > 0) return _PauseStoppedBeforeAction(host, stop, output);
        // F6/F9: the menu state, the plan and the dialog check come from AFTER
        // the sample: the menu may have opened or closed while it ran.
        stop = PauseContextStop(host, ctx, true);
        if (stop.Length > 0) return _PauseStoppedBeforeAction(host, stop, output);
        bool menuBefore = host.MenuShown();
        string verdictBefore = before.Verdict(holdMs);
        string resolved = ResolvePauseAction(action, menuBefore);
        string plan = PausePlan(resolved, menuBefore, verdictBefore);
        output["resolvedAction"] = resolved;
        output["plan"] = plan;
        output["menuShownBefore"] = menuBefore;
        output["verdictBefore"] = verdictBefore;

        if (plan == "noop") {
            output["changed"] = false;
            if (resolved == "pause") {
                bool ours = PauseOwnedIn(ctx);
                string timer = PauseNoopTimerAction(aGiven, autoResumeMs, ours);
                if (ours) {
                    // A verified pause request supersedes a failed call's
                    // pending cleanup on this same menu.
                    g_pause.closing = false;
                    g_pause.gaveUp = false;
                    g_pause.closeAttempts = 0;
                }
                output["autoResume"] = timer;
                if (timer == "refuse") {
                    output["menuShown"] = menuBefore;
                    output["ownership"] = PauseOwnershipJson(host, ctx, menuBefore);
                    return _PauseErr("Already paused by a menu this tool did not open: autoResumeAfterMs would close"
                        + " someone else's menu, so no timer was set. Nothing was changed.",
                        "AUTO_RESUME_NOT_OWNED", false, "",
                        "Resume it with ControlPause resume, or call pause without autoResumeAfterMs.", output);
                }
                if (timer == "update") {
                    g_pause.autoResumeMs = autoResumeMs;
                    g_pause.timerFrom = host.NowMs(); // the new timer counts from now
                }
            }
            output["paused"] = resolved == "pause";
            output["menuShown"] = menuBefore;
            output["ownership"] = PauseOwnershipJson(host, ctx, menuBefore);
            return MakeSuccess(output);
        }

        if (plan == "verify") {
            output["changed"] = false;
            output["menuShown"] = menuBefore;
            output["ownership"] = PauseOwnershipJson(host, ctx, menuBefore);
            if (resolved == "pause") {
                // The menu is up but time runs: online-like, or someone else's
                // menu. Not ours to close.
                return _PauseErr("The in-game menu is up but the clocks are not frozen ("
                    + verdictBefore + "). Not paused; the menu was left as it was.", "NOT_PAUSED", false, "", "", output);
            }
            return _PauseErr("No in-game menu is up but the clocks are not running ("
                + verdictBefore + "): nothing this tool can close. Check GetMode / loading / finish screen.",
                "RESUME_UNVERIFIED", true, "", "", output);
        }

        if (plan == "open") return _PauseOpen(host, ctx, holdMs, timeoutMs, autoResumeMs, deadline, output);
        return _PauseClose(host, ctx, holdMs, timeoutMs, deadline, before, output);
    }

    Json::Value@ _PauseOpen(PauseHost@ host, PauseGate@ ctx, uint holdMs, uint timeoutMs, int autoResumeMs,
                            uint64 deadline, Json::Value &in output) {
        // Last checks right before the first menu call.
        string stop = PauseContextStop(host, ctx, true);
        if (stop.Length > 0) return _PauseStoppedBeforeAction(host, stop, output);
        // Ownership is recorded as the show is attempted (F7).
        PauseOwnershipBegin(host, ctx, deadline);
        if (!host.ShowMenu()) {
            PauseOwnershipEnd("show-failed");
            output["changed"] = false;
            output["menuShown"] = host.MenuShown();
            return _PauseErr("PlaygroundInterfaceScriptHandler unavailable", "NO_PLAYGROUND", true, "Race", "", output);
        }
        uint64 showStart = host.NowMs();
        uint64 cleanupFrom = deadline - uint64(PAUSE_CLEANUP_RESERVE_MS);
        bool shown = PauseWaitMenu(host, ctx, true, showStart + uint64(timeoutMs), true, stop);
        string verdictAfter = PAUSE_VERDICT_UNKNOWN;
        uint windows = 0;
        PauseClockWindow@ after = null;
        if (shown && stop.Length == 0) {
            // The pause can take effect a frame or two after the menu shows:
            // back-to-back hold windows until one is frozen or the time for
            // them (timeoutMs from the show, plus one last full window) runs out.
            uint64 freezeEnd = showStart + uint64(timeoutMs) + uint64(holdMs);
            if (freezeEnd > cleanupFrom) freezeEnd = cleanupFrom;
            while (windows == 0 || host.NowMs() + uint64(holdMs) <= freezeEnd) {
                @after = PauseSampleWindow(host, ctx, holdMs, holdMs + 1000, freezeEnd, stop);
                windows++;
                if (stop.Length > 0) break;
                verdictAfter = after.Verdict(holdMs);
                if (verdictAfter == PAUSE_VERDICT_FROZEN || !host.MenuShown()) break;
            }
        }
        output["holdWindows"] = int(windows);
        if (after !is null) output["clocks"] = after.ToJson(host);
        output["verdict"] = verdictAfter;

        string code = stop;
        if (code.Length == 0) {
            // Final checks right before the success return.
            stop = PauseContextStop(host, ctx, false);
            code = stop.Length > 0 ? stop : PauseOutcomeCode(host.MenuShown(), verdictAfter);
        }
        if (code.Length == 0) {
            g_pause.callActive = false;
            g_pause.autoResumeMs = autoResumeMs;
            g_pause.timerFrom = host.NowMs();
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                g_pause.clockHave[i] = after.started;
                g_pause.clockValues[i] = after.last[i];
            }
            output["changed"] = true;
            output["paused"] = true;
            output["menuShown"] = true;
            output["ownership"] = PauseOwnershipJson(host, ctx, true);
            return MakeSuccess(output);
        }

        output["paused"] = false;
        // Not paused: put back what we found. Only Resume, and only while the
        // same menu in the same context is ours (PauseCloseOwned checks that
        // before every Resume, so nothing is sent into another playground).
        if (code == "MENU_NOT_SHOWN" && !host.MenuShown()) {
            // A late show can still land: watch a little longer so it is closed.
            uint64 graceEnd = host.NowMs() + uint64(PAUSE_LATE_MENU_GRACE_MS);
            if (graceEnd > deadline) graceEnd = deadline;
            while (!host.MenuShown() && host.NowMs() < graceEnd) {
                host.Yield();
                if (!ctx.SameContext(host.ReadGate())) break;
            }
        }
        bool closed = true;
        if (host.MenuShown()) closed = PauseCloseOwned(host, ctx, deadline, output);
        bool menuNow = host.MenuShown();
        bool sameNow = ctx.SameContext(host.ReadGate());
        bool tried = output.HasKey("cleanupResumeCalls");
        output["menuShown"] = menuNow;
        if (tried) output["menuClosedAgain"] = closed;
        string why = code == "MENU_NOT_SHOWN"
            ? "ShowInGameMenu did not bring the in-game menu up within timeoutMs."
            : (code == "NOT_PAUSED"
               ? "The in-game menu opened but the clocks kept running (" + verdictAfter + "): not paused."
               : "ControlPause stopped after ShowInGameMenu was called: " + PauseStopMessage(code) + ".");
        g_pause.callActive = false;
        if (!closed) {
            output["changed"] = true;
            if (sameNow) {
                // F7: keep the recovery. The watcher keeps sending Resume
                // while this exact menu is ours; ControlPause resume also
                // closes it.
                g_pause.closing = true;
                g_pause.autoResumeMs = 0;
                output["ownership"] = PauseOwnershipJson(host, ctx, menuNow);
                return _PauseErr(why + " The in-game menu it opened did not close: Resume was sent and the menu is"
                    + " still up (a sub-page may be open). Ownership is kept; the tool keeps retrying Resume in the"
                    + " background, and ControlPause resume closes it.",
                    "CLEANUP_FAILED", true, "", "Call GetPauseState, then ControlPause resume.", output);
            }
            // The playground changed: the watcher drops the ownership on its
            // next frame and nothing is sent into the new context.
            output["ownership"] = PauseOwnershipJson(host, host.ReadGate(), menuNow);
            return _PauseErr(why + " An in-game menu is up; Resume was not sent because the playground changed.",
                code, true, "", "GetPauseState shows the current state.", output);
        }
        // Seen closed, or never up: ownership ends here.
        PauseOwnershipEnd(tried ? "cleanup-closed" : "never-shown");
        output["changed"] = false;
        output["ownership"] = PauseOwnershipJson(host, host.ReadGate(), menuNow);
        why += tried ? " The menu was seen closed again." : " No in-game menu is up.";
        return _PauseErr(why, code, code != "NOT_PAUSED", "", "", output);
    }

    Json::Value@ _PauseClose(PauseHost@ host, PauseGate@ ctx, uint holdMs, uint timeoutMs, uint64 deadline,
                             PauseClockWindow@ before, Json::Value &in output) {
        bool openedByTool = PauseOwnedIn(ctx);
        uint64 pausedAt = g_pause.openedAt;
        array<uint> pausedValues(PAUSE_CLOCK_COUNT, 0);
        array<bool> pausedHave(PAUSE_CLOCK_COUNT, false);
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
            // Someone else's pause: the values sampled just now.
            pausedHave[i] = openedByTool ? g_pause.clockHave[i] : before.started;
            pausedValues[i] = openedByTool ? g_pause.clockValues[i] : before.last[i];
        }
        output["openedBy"] = openedByTool ? "tool" : "other";
        string stop = PauseContextStop(host, ctx, false);
        if (stop.Length > 0) return _PauseStoppedBeforeAction(host, stop, output);
        if (openedByTool) { g_pause.callActive = true; g_pause.callUntil = deadline; }
        host.CloseMenuResume();
        uint64 closeStart = host.NowMs();
        bool closed = PauseWaitMenu(host, ctx, false, closeStart + uint64(timeoutMs), false, stop);
        if (openedByTool) {
            // Seen closed: ours ends here. Not closed: hand it back to the watcher.
            if (closed) PauseOwnershipEnd("resumed");
            else g_pause.callActive = false;
        }

        // First new value per clock after the close = the resume step.
        Json::Value jumps = Json::Object();
        array<bool> seen(PAUSE_CLOCK_COUNT, false);
        uint64 t1 = host.NowMs();
        uint64 jumpEnd = closeStart + uint64(timeoutMs);
        uint seenCount = 0, wantCount = 0;
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (pausedHave[i]) wantCount++;
        while (closed && stop.Length == 0 && seenCount < wantCount && host.NowMs() < jumpEnd) {
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                if (!pausedHave[i] || seen[i]) continue;
                uint v = 0;
                if (!host.ReadClock(i, v) || v == pausedValues[i]) continue;
                seen[i] = true;
                seenCount++;
                jumps[PauseClockName(i)] = ClockJumpMs(pausedValues[i], v);
            }
            if (seenCount < wantCount) {
                host.Yield();
                stop = PauseContextStop(host, ctx, false);
            }
        }
        string verdictAfter = PAUSE_VERDICT_UNKNOWN;
        if (closed && stop.Length == 0) {
            auto after = PauseSampleWindow(host, ctx, holdMs, holdMs + 1000, deadline, stop);
            output["clocks"] = after.ToJson(host);
            if (stop.Length == 0) verdictAfter = after.Verdict(holdMs);
        }
        bool menuNow = host.MenuShown();
        output["menuShown"] = menuNow;
        output["verdict"] = verdictAfter;
        output["jumpMs"] = jumps;
        if (openedByTool) output["wallPausedMs"] = double(t1 - pausedAt);
        output["ownership"] = PauseOwnershipJson(host, host.ReadGate(), menuNow);
        if (stop.Length > 0) {
            output["changed"] = !menuNow;
            return _PauseErr("ControlPause resume stopped: " + PauseStopMessage(stop) + ". "
                + (menuNow ? "The in-game menu is still up." : "The in-game menu closed."),
                stop, true, "", "GetPauseState shows the current state.", output);
        }
        string code = ResumeOutcomeCode(menuNow, verdictAfter);
        if (code.Length > 0) {
            output["changed"] = !menuNow;
            return _PauseErr(code == "MENU_SUBPAGE_OPEN"
                ? "CloseInGameMenu(Resume) did not close the menu (a sub-page such as settings may be open). Nothing else was clicked."
                : "The menu closed but the clocks did not start again in time (" + verdictAfter + ").",
                code, true, "", "", output);
        }
        output["changed"] = true;
        output["paused"] = false;
        return MakeSuccess(output);
    }

    // Plugin disable / unload: callbacks, so no yield. Close a menu this tool
    // still owns in the same context, once, and report what was seen.
    string PauseCloseOwnedOnShutdown(PauseHost@ host) {
        if (!g_pause.owned) return "none";
        auto ctx = host.ReadGate();
        if (!PauseOwnedIn(ctx)) { PauseOwnershipEnd("context-changed"); return "context-changed"; }
        if (!host.MenuShown()) { PauseOwnershipEnd("menu-closed"); return "already-closed"; }
        host.CloseMenuResume();
        bool closed = !host.MenuShown();
        PauseOwnershipEnd("shutdown");
        return closed ? "closed" : "resume-sent-unconfirmed";
    }
}
