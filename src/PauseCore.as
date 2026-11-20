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
    // this game, so ControlPause refuses online play BEFORE anything opens,
    // and success is judged on three clocks, never on the menu flag.
    //
    // The agent stays in control: nothing here outlives a call. There is no
    // ownership record, no watcher and no timer. Resume closes the in-game
    // menu whoever opened it (that is the point of the tool).
    //
    // Within one call (P2): after every yield, and immediately before every
    // ShowInGameMenu and every Resume, the call reads the gate (locality,
    // loading), the menu, the dialog state and the context (the playground
    // and its interface handler captured when the call began). A context or
    // locality change aborts; a blocking dialog refuses before the next Show;
    // the deadline is checked right after each yield and before each Show.
    // The budget is checked once per game frame, so a frame hitch can run
    // past it by up to that frame.
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

    // The playground and handler a call began in. The live host keeps the
    // two handles only to compare them (never dereferenced, no reference
    // taken); the object dies with the call.
    interface PauseContext {}

    // What the game looks like right now, read without yielding.
    class PauseGate {
        bool inPlayground = false;
        bool loading = false;
        bool local = false;
        bool serverLoginSet = false;
        bool spectatorClient = false;
        bool serverOrSolo = false;
        // The playground and handler are the ones the call's context holds
        // (both present).
        bool sameContext = false;

        string Refusal() {
            return PauseRefusalCode(inPlayground, loading, local, serverLoginSet, spectatorClient);
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
        // The playground + handler now; ReadGate compares against it.
        PauseContext@ CaptureContext();
        PauseGate@ ReadGate(PauseContext@ ctx);
        // False means neither reader was available, not that the menu is closed.
        bool TryMenuShown(bool &out shown);
        bool ReadClock(uint index, uint &out value);
        // false when there is no handler to call.
        bool ShowMenu();
        bool CloseMenuResume();
        // A blocking BasicDialogs / modal menu dialog (DialogPolicy). The
        // in-game menu is not one of those frames, so it never counts.
        bool DialogBlocking();
        // Extra read-only state added to clock reports (may be null).
        Json::Value@ ExtraState();
    }

    // One call's view of the game, refreshed after every yield and right
    // before every menu action. Lives only for the call.
    class PauseCall {
        PauseHost@ host;
        PauseContext@ ctx;
        uint64 deadline = 0;
        // ControlPause: a locality, loading or context change stops it.
        // GetPauseState (read-only): only a context change does; loading
        // restarts the window and locality is just reported.
        bool mutating = true;
        PauseGate@ gate;
        bool menu = false;
        bool menuKnown = false;
        bool dialog = false;
        string stop = "";
        uint frames = 0;
        uint64 longestFrameMs = 0;
        uint shows = 0;
        uint resumes = 0;
        bool attemptedResume = false;
        bool resumeSent = false;
        // Once a mutator sees an invalid playground, it must not send a
        // cleanup action even if the next observation appears valid again.
        string gateFailure = "";
        // After this call's first Show: the menu was seen open, and was then
        // seen closed (by anyone). A reopened menu is not eligible for cleanup.
        bool menuSeenOpen = false;
        bool menuSeenClosedAfterOpen = false;

        PauseCall(PauseHost@ h, uint64 until, bool isMutating) {
            @host = h;
            deadline = until;
            mutating = isMutating;
            @ctx = host.CaptureContext();
        }

        string _StopCode() {
            if (mutating) {
                string refusal = gate.Refusal();
                if (refusal.Length > 0) return refusal;
                if (!gate.sameContext) return "CONTEXT_CHANGED";
                return "";
            }
            if (!gate.inPlayground) return "NO_PLAYGROUND";
            if (!gate.sameContext) return "CONTEXT_CHANGED";
            return "";
        }

        // Gate, menu, dialog and context, read now with no yield.
        void Observe() {
            @gate = host.ReadGate(ctx);
            string currentStop = _StopCode();
            if (mutating && gateFailure.Length == 0) gateFailure = currentStop;
            if (stop.Length == 0) stop = currentStop;
            menuKnown = host.TryMenuShown(menu);
            if (!menuKnown && mutating) {
                if (gateFailure.Length == 0) gateFailure = "NO_PLAYGROUND";
                if (stop.Length == 0) stop = gateFailure;
            }
            if (shows > 0 && menuKnown) {
                if (menu && !menuSeenClosedAfterOpen) menuSeenOpen = true;
                else if (!menu && menuSeenOpen) menuSeenClosedAfterOpen = true;
            }
            dialog = host.DialogBlocking();
        }

        // One game frame, then a fresh observation and, for ControlPause, the
        // deadline: a frame that ends past it stops the call (DEADLINE).
        void Step() {
            uint64 before = host.NowMs();
            host.Yield();
            frames++;
            uint64 took = host.NowMs() - before;
            if (took > longestFrameMs) longestFrameMs = took;
            Observe();
            if (mutating && stop.Length == 0 && Past(deadline)) stop = "DEADLINE";
        }

        bool Past(uint64 t) { return host.NowMs() >= t; }

        // Read everything immediately before the Show; send it only if
        // nothing stops it. false = not sent (stop says why).
        bool ShowChecked(uint64 showEnd) {
            Observe();
            if (stop.Length > 0) return false;
            if (dialog) { stop = "DIALOG_BLOCKING"; return false; }
            if (Past(showEnd) || Past(deadline)) return false;
            if (menu) return false; // a menu became visible before dispatch
            shows++; // the native call may throw after dispatch
            if (!host.ShowMenu()) { shows--; stop = "NO_PLAYGROUND"; return false; }
            return true;
        }

        void Resume() {
            attemptedResume = true;
            resumes++;
            resumeSent = host.CloseMenuResume();
        }

        bool CanRead() { return gate !is null && !gate.loading && gate.sameContext; }

        // Observed open after Show and not observed closed since. This says
        // nothing about who opened it.
        bool OwnMenuStillUp() { return menuKnown && menuSeenOpen && !menuSeenClosedAfterOpen && menu; }
    }

    // F5: every clock must be readable when the window starts and on every
    // sample after; an unreadable sample, a loading screen or a context
    // change restarts it. So the window only ever covers time in which all
    // three clocks were continuously read, and frozen needs that coverage to
    // reach holdMs with no clock changing. Every observed change counts, so
    // a clock that goes A -> B -> A is not frozen (P5).
    class PauseClockWindow {
        array<uint> first(PAUSE_CLOCK_COUNT, 0);
        array<uint> last(PAUSE_CLOCK_COUNT, 0);
        array<uint> changes(PAUSE_CLOCK_COUNT, 0);
        array<uint64> lastChangeAt(PAUSE_CLOCK_COUNT, 0);
        array<bool> seen(PAUSE_CLOCK_COUNT, false); // read at least once (reporting only)
        array<uint> seenValue(PAUSE_CLOCK_COUNT, 0);
        bool started = false;
        bool menuUpThroughout = false;
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
        void Observe(PauseHost@ host, bool canRead, bool menuUp = false) {
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
                menuUpThroughout = menuUp;
                startedAt = now;
                endedAt = now;
                for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                    first[i] = v[i]; last[i] = v[i]; changes[i] = 0; lastChangeAt[i] = now;
                }
                return;
            }
            endedAt = now;
            menuUpThroughout = menuUpThroughout && menuUp;
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

    // Samples once per frame until the window covers holdMs uninterrupted,
    // endAt passes, or the call stops. requireMenu: the menu must be seen up
    // on every frame (a pause's verification); a closed menu stops the call
    // with MENU_CLOSED.
    PauseClockWindow@ PauseSampleWindow(PauseCall@ call, uint holdMs, uint64 endAt, bool requireMenu) {
        auto w = PauseClockWindow();
        if (requireMenu && !call.menu) { if (call.stop.Length == 0) call.stop = "MENU_CLOSED"; return w; }
        w.Observe(call.host, call.CanRead(), call.menu);
        if (holdMs == 0 || call.stop.Length > 0) return w;
        while (w.WindowMs() < holdMs) {
            if (call.Past(endAt)) break;
            call.Step();
            if (call.stop.Length > 0) return w;
            if (requireMenu && !call.menu) { call.stop = "MENU_CLOSED"; return w; }
            w.Observe(call.host, call.CanRead(), call.menu);
        }
        return w;
    }

    uint64 _PauseMin(uint64 a, uint64 b) { return a < b ? a : b; }

    Json::Value@ _PauseErr(const string &in message, const string &in code, bool retryable,
                           const string &in requiredMode, const string &in hint, Json::Value &in output) {
        auto err = MakeError(message, code, retryable, requiredMode, hint);
        err["output"] = output;
        return err;
    }

    void _PauseFinish(PauseCall@ call, uint64 t0, Json::Value &inout output) {
        output["elapsedMs"] = double(call.host.NowMs() - t0);
        output["frames"] = int(call.frames);
        output["longestFrameMs"] = double(call.longestFrameMs);
        output["showCalls"] = int(call.shows);
        output["resumeCalls"] = int(call.resumes);
    }

    // Stopped before any menu call: nothing changed.
    Json::Value@ _PauseStoppedBeforeAction(PauseCall@ call, uint64 t0, Json::Value &in output) {
        output["changed"] = false;
        output["stoppedAt"] = "before-action";
        if (call.menuKnown) output["menuShown"] = call.menu;
        else output["menuShown"] = "unknown";
        output["openedByThisCall"] = false;
        _PauseFinish(call, t0, output);
        string stop = call.stop.Length > 0 ? call.stop : "DEADLINE";
        return _PauseErr("ControlPause stopped before acting: " + PauseStopMessage(stop) + ". No menu call was made.",
            stop, stop != "DIALOG_BLOCKING", "", "GetPauseState shows the current menu and clocks.", output);
    }

    // Reads a numeric input; false when present but not a number.
    bool _PauseNumberInput(Json::Value &in input, const string &in key, bool &out given, double &out value) {
        given = input.HasKey(key);
        value = 0;
        if (!given) return true;
        if (input[key].GetType() != Json::Type::Number) return false;
        value = double(input[key]);
        return true;
    }

    Json::Value@ GetPauseStateCore(PauseHost@ host, Json::Value &in input) {
        bool given;
        double raw;
        if (!_PauseNumberInput(input, "sampleMs", given, raw)) return MakeError("sampleMs must be a number", "INVALID_INPUT");
        int sampleMs = ClampPauseSampleMs(raw, given);
        uint64 t0 = host.NowMs();
        uint limit = PauseStateSampleLimitMs(uint(sampleMs));
        PauseCall@ call = PauseCall(host, t0 + uint64(limit), false);
        call.Observe();
        bool menuAtStart = call.menu;
        bool menuKnownAtStart = call.menuKnown;
        auto w = PauseSampleWindow(call, uint(sampleMs), t0 + uint64(limit), false);
        // P4: the reported state is read at the END of the window.
        call.Observe();
        string stop = call.stop;
        Json::Value output = Json::Object();
        output["locality"] = call.gate.ToJson();
        string refusal = call.gate.Refusal();
        output["pausable"] = refusal.Length == 0;
        if (refusal.Length > 0) {
            output["notPausableReason"] = PauseRefusalReason(refusal, call.gate.local, call.gate.serverLoginSet,
                                                             call.gate.spectatorClient);
        }
        if (call.menuKnown) output["menuShown"] = call.menu;
        else output["menuShown"] = "unknown";
        if (menuKnownAtStart) output["menuShownAtStart"] = menuAtStart;
        else output["menuShownAtStart"] = "unknown";
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
        bool hGiven, tGiven;
        double hRaw, tRaw;
        if (!_PauseNumberInput(input, "holdMs", hGiven, hRaw) || !_PauseNumberInput(input, "timeoutMs", tGiven, tRaw)) {
            return MakeError("holdMs and timeoutMs must be numbers", "INVALID_INPUT");
        }
        uint holdMs = uint(ClampPauseHoldMs(hRaw, hGiven));
        uint timeoutMs = uint(ClampPauseTimeoutMs(tRaw, tGiven));

        // One deadline for the whole call, checked once per frame.
        uint64 t0 = host.NowMs();
        uint budgetMs = PauseCallBudgetMs(holdMs, timeoutMs);
        PauseCall@ call = PauseCall(host, t0 + uint64(budgetMs), true);
        call.Observe();
        Json::Value output = Json::Object();
        output["action"] = action;
        output["locality"] = call.gate.ToJson();
        output["holdMs"] = int(holdMs);
        output["timeoutMs"] = int(timeoutMs);
        output["budgetMs"] = int(budgetMs);
        output["budgetNote"] = "checked once per game frame; a frame hitch can run past it";

        // Locality gate BEFORE any menu call. Refusals touch nothing.
        string refusal = call.gate.Refusal();
        if (refusal.Length > 0) {
            output["changed"] = false;
            output["openedByThisCall"] = false;
            return _PauseErr("ControlPause refused: " + PauseRefusalReason(refusal, call.gate.local,
                    call.gate.serverLoginSet, call.gate.spectatorClient),
                refusal, refusal == "LOADING", refusal == "NO_PLAYGROUND" ? "Race" : "",
                "GetPauseState reports the clocks without changing anything.", output);
        }

        auto before = PauseSampleWindow(call, holdMs, _PauseMin(t0 + uint64(PauseInitialSampleLimitMs(holdMs)), call.deadline), false);
        output["clocksBefore"] = before.ToJson(host);
        if (call.stop.Length > 0) return _PauseStoppedBeforeAction(call, t0, output);
        // The menu state, the plan and the dialog check come from AFTER the
        // sample: the menu may have opened or closed while it ran.
        call.Observe();
        if (call.stop.Length > 0) return _PauseStoppedBeforeAction(call, t0, output);
        if (call.dialog) { call.stop = "DIALOG_BLOCKING"; return _PauseStoppedBeforeAction(call, t0, output); }
        bool menuBefore = call.menu;
        string verdictBefore = before.Verdict(holdMs);
        string resolved = ResolvePauseAction(action, menuBefore);
        if (resolved == "pause" && menuBefore) return _PauseExisting(call, before, holdMs, t0, output);
        string plan = PausePlan(resolved, menuBefore, verdictBefore);
        output["resolvedAction"] = resolved;
        output["plan"] = plan;
        output["menuShownBefore"] = menuBefore;
        output["verdictBefore"] = verdictBefore;

        if (plan == "noop") {
            output["changed"] = false;
            output["paused"] = resolved == "pause";
            output["menuShown"] = menuBefore;
            output["openedByThisCall"] = false;
            _PauseFinish(call, t0, output);
            return MakeSuccess(output);
        }

        if (plan == "verify") {
            output["changed"] = false;
            output["menuShown"] = menuBefore;
            output["openedByThisCall"] = false;
            _PauseFinish(call, t0, output);
            return _PauseErr("No in-game menu is up but the clocks are not running ("
                + verdictBefore + "): nothing this tool can close. Check GetMode / loading / finish screen.",
                "RESUME_UNVERIFIED", true, "", "", output);
        }

        if (plan == "open") return _PauseOpen(call, holdMs, timeoutMs, t0, output);
        return _PauseClose(call, holdMs, timeoutMs, t0, before, output);
    }

    // A pre-existing menu is never opened or closed by a pause request.
    Json::Value@ _PauseExisting(PauseCall@ call, PauseClockWindow@ before, uint holdMs, uint64 t0,
                                Json::Value &in output) {
        auto w = before;
        if (w is null || !w.menuUpThroughout || w.WindowMs() < holdMs) {
            @w = PauseSampleWindow(call, holdMs, call.deadline - uint64(PAUSE_CLEANUP_RESERVE_MS), true);
        }
        string verdict = w.Verdict(holdMs);
        output["resolvedAction"] = "pause";
        output["menuShownBefore"] = true;
        output["changed"] = false;
        output["openedByThisCall"] = false;
        output["clocks"] = w.ToJson(call.host);
        output["verdict"] = verdict;
        call.Observe();
        if (call.menuKnown) output["menuShown"] = call.menu;
        else output["menuShown"] = "unknown";
        string code = call.stop;
        if (code.Length == 0 && !call.menu) code = "MENU_CLOSED";
        if (code.Length == 0 && verdict != PAUSE_VERDICT_FROZEN) code = "NOT_PAUSED";
        output["paused"] = code.Length == 0;
        output["plan"] = code.Length == 0 ? "noop" : "verify";
        _PauseFinish(call, t0, output);
        if (code.Length == 0) return MakeSuccess(output);
        string why = code == "NOT_PAUSED" ? "The clocks were not verified frozen (" + verdict + ")"
                                          : PauseStopMessage(code);
        return _PauseErr(why + "; no menu action was sent.", code, code != "NOT_PAUSED", "",
            "GetPauseState shows the current menu and clocks.", output);
    }

    Json::Value@ _PauseOpen(PauseCall@ call, uint holdMs, uint timeoutMs, uint64 t0, Json::Value &in output) {
        auto host = call.host;
        string code, exception;
        string verdictAfter = PAUSE_VERDICT_UNKNOWN;
        try {
            uint64 workEnd = call.deadline - uint64(PAUSE_CLEANUP_RESERVE_MS);
            uint64 showStart = host.NowMs();
            uint64 showEnd = _PauseMin(showStart + uint64(timeoutMs), workEnd);
            if (!call.ShowChecked(showEnd)) {
                if (call.menu && call.stop.Length == 0) return _PauseExisting(call, null, holdMs, t0, output);
                return _PauseStoppedBeforeAction(call, t0, output);
            }
            call.Observe();
            // Wait for the menu, re-sending Show each frame as before, only
            // if the fresh gate allows it and the menu is not already up.
            while (!call.menu && call.stop.Length == 0) {
                if (call.Past(showEnd)) break;
                call.Step();
                if (call.stop.Length > 0 || call.menu || !call.ShowChecked(showEnd)) break;
                call.Observe();
            }

            uint windows = 0;
            PauseClockWindow@ after = null;
            if (call.menu && call.stop.Length == 0) {
                // Allow the clocks to settle, but require a full menu-up hold.
                uint64 freezeEnd = _PauseMin(showStart + uint64(timeoutMs) + uint64(holdMs), workEnd);
                while (windows == 0 || host.NowMs() + uint64(holdMs) <= freezeEnd) {
                    @after = PauseSampleWindow(call, holdMs, freezeEnd, true);
                    windows++;
                    if (call.stop.Length > 0) break;
                    verdictAfter = after.Verdict(holdMs);
                    if (verdictAfter == PAUSE_VERDICT_FROZEN) break;
                }
            }
            output["holdWindows"] = int(windows);
            if (after !is null) output["clocks"] = after.ToJson(host);
            output["verdict"] = verdictAfter;

            call.Observe();
            code = call.stop;
            if (code.Length == 0 && call.menuSeenClosedAfterOpen) code = "MENU_CLOSED";
            if (code.Length == 0) code = PauseOutcomeCode(call.menu, verdictAfter);
            if (code.Length == 0) {
                output["changed"] = true;
                output["paused"] = true;
                output["menuShown"] = true;
                output["openedByThisCall"] = true;
                output["lateShowPossible"] = call.shows > 1;
                if (call.shows > 1) output["lateShowHint"] = "After the menu appears closed, call GetPauseState again.";
                _PauseFinish(call, t0, output);
                return MakeSuccess(output);
            }
        } catch {
            exception = getExceptionInfo();
            code = "tool_exception";
            if (call.shows == 0) return MakeError("ControlPause threw before Show: " + exception, code, true);
        }
        return _PauseFailed(call, code, verdictAfter, exception, t0, output);
    }

    // At most one cleanup Resume. Reobserve immediately before dispatch;
    // never close in a changed playground or without an eligible observation.
    Json::Value@ _PauseFailed(PauseCall@ call, const string &in code, const string &in verdictAfter,
                              const string &in exception, uint64 t0, Json::Value &in output) {
        string skipped, cleanupError;
        bool menuKnown = false;
        bool menuAfter = false;
        try {
            call.Observe();
            if (call.gateFailure.Length > 0) skipped = call.gateFailure;
            else if (!call.menuKnown) skipped = "menu state unavailable";
            else if (!call.OwnMenuStillUp()) {
                skipped = call.menu ? "the menu that is up is not one this call saw open and continuously up"
                                    : "no in-game menu is up";
            }
            if (call.dialog) output["dialogUpAtCleanup"] = true;
            if (skipped.Length == 0 && !call.attemptedResume) {
                call.Resume();
                call.Observe();
                while (call.menuKnown && call.menu && call.gateFailure.Length == 0 && !call.Past(call.deadline)) call.Step();
            }
            menuKnown = call.menuKnown;
            menuAfter = call.menu;
        } catch {
            cleanupError = getExceptionInfo();
            if (!call.attemptedResume) skipped = "cleanup observation failed";
            // A reporting read may fail too. Do not present a stale menu bit
            // as proof of closure and never send another Resume from here.
            try {
                if (call.host.TryMenuShown(menuAfter)) menuKnown = true;
            } catch {}
        }
        try { _PauseFinish(call, t0, output); } catch {}
        output["paused"] = false;
        output["openedByThisCall"] = call.menuSeenOpen;
        output["resumeAttempted"] = call.attemptedResume;
        output["resumeSent"] = call.resumeSent;
        if (skipped.Length > 0) output["cleanupSkipped"] = skipped;
        if (cleanupError.Length > 0) output["cleanupError"] = cleanupError;
        if (menuKnown) {
            output["menuShown"] = menuAfter;
            output["menuShownAfter"] = menuAfter;
            output["changed"] = menuAfter;
        } else {
            output["menuShown"] = "unknown";
            output["menuShownAfter"] = "unknown";
            output["changed"] = "unknown";
        }
        // No API to cancel or drain a Show. A visible menu does not remove
        // the risk of additional pending requests.
        bool late = call.shows > 0 && (!call.menuSeenOpen || call.shows > 1 || !menuKnown);
        output["lateShowPossible"] = late;

        string why = code == "MENU_NOT_SHOWN"
            ? "ShowInGameMenu did not bring the in-game menu up within timeoutMs."
            : (code == "NOT_PAUSED"
               ? "The in-game menu opened but the clocks were not verified frozen (" + verdictAfter + ")."
               : "ControlPause stopped after ShowInGameMenu was called: " + PauseStopMessage(code) + ".");
        if (exception.Length > 0) why += " " + exception + ".";
        if (!menuKnown) why += " The menu state could not be read.";
        else if (menuAfter) why += " The in-game menu is still up.";
        else why += " The in-game menu was observed closed.";
        if (late) why += " A ShowInGameMenu this call sent may still be applied later.";
        string hint = "Call GetPauseState; ControlPause resume closes the in-game menu if it is up.";
        if (late) hint += " After the menu appears closed, call GetPauseState again to check for a late Show.";
        string outCode = (call.attemptedResume && (!menuKnown || menuAfter)) ? "CLEANUP_FAILED" : code;
        if (outCode != code) output["cause"] = code;
        return _PauseErr(why, outCode, code != "NOT_PAUSED" || outCode == "CLEANUP_FAILED", "", hint, output);
    }

    Json::Value@ _PauseClose(PauseCall@ call, uint holdMs, uint timeoutMs, uint64 t0, PauseClockWindow@ before,
                             Json::Value &in output) {
        auto host = call.host;
        output["openedByThisCall"] = false;
        // The values sampled just now: frozen if the game is paused.
        array<uint> pausedValues(PAUSE_CLOCK_COUNT, 0);
        array<bool> pausedHave(PAUSE_CLOCK_COUNT, false);
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
            pausedHave[i] = before.started;
            pausedValues[i] = before.last[i];
        }
        // Immediately before the Resume.
        call.Observe();
        if (call.stop.Length > 0) return _PauseStoppedBeforeAction(call, t0, output);
        if (call.dialog) { call.stop = "DIALOG_BLOCKING"; return _PauseStoppedBeforeAction(call, t0, output); }
        if (call.Past(call.deadline)) return _PauseStoppedBeforeAction(call, t0, output);
        if (!call.menu) { call.stop = "MENU_CLOSED"; return _PauseStoppedBeforeAction(call, t0, output); }
        call.Resume();
        uint64 closeStart = host.NowMs();
        uint64 closeEnd = _PauseMin(closeStart + uint64(timeoutMs), call.deadline);
        bool shown;
        bool known = host.TryMenuShown(shown);
        if (!known) call.stop = "NO_PLAYGROUND";
        bool closed = known && !shown;
        while (!closed && call.stop.Length == 0) {
            if (call.Past(closeEnd)) break;
            call.Step();
            if (call.stop.Length > 0) break;
            closed = !call.menu;
        }

        // First new value per clock after the close = the resume step.
        Json::Value jumps = Json::Object();
        array<bool> seen(PAUSE_CLOCK_COUNT, false);
        uint seenCount = 0, wantCount = 0;
        for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) if (pausedHave[i]) wantCount++;
        while (closed && call.stop.Length == 0 && seenCount < wantCount) {
            for (uint i = 0; i < PAUSE_CLOCK_COUNT; i++) {
                if (!pausedHave[i] || seen[i]) continue;
                uint v = 0;
                if (!host.ReadClock(i, v) || v == pausedValues[i]) continue;
                seen[i] = true;
                seenCount++;
                jumps[PauseClockName(i)] = ClockJumpMs(pausedValues[i], v);
            }
            if (seenCount >= wantCount || call.Past(closeEnd)) break;
            call.Step();
        }
        string verdictAfter = PAUSE_VERDICT_UNKNOWN;
        if (closed && call.stop.Length == 0) {
            auto after = PauseSampleWindow(call, holdMs, call.deadline, false);
            output["clocks"] = after.ToJson(host);
            if (call.stop.Length == 0) verdictAfter = after.Verdict(holdMs);
        }
        call.Observe();
        bool menuNow = call.menu;
        if (call.menuKnown) {
            output["menuShown"] = menuNow;
            output["menuShownAfter"] = menuNow;
            output["changed"] = !menuNow;
        } else {
            output["menuShown"] = "unknown";
            output["menuShownAfter"] = "unknown";
            output["changed"] = "unknown";
        }
        output["verdict"] = verdictAfter;
        output["jumpMs"] = jumps;
        output["jumpNote"] = "Missing jumpMs entries are unmeasured, not zero.";
        _PauseFinish(call, t0, output);
        if (call.stop.Length > 0) {
            return _PauseErr("ControlPause resume stopped: " + PauseStopMessage(call.stop) + ". "
                + (!call.menuKnown ? "The menu state could not be read."
                   : menuNow ? "The in-game menu is still up." : "The in-game menu is closed."),
                call.stop, true, "", "GetPauseState shows the current state.", output);
        }
        string code = ResumeOutcomeCode(menuNow, verdictAfter);
        if (code.Length > 0) {
            return _PauseErr(code == "MENU_SUBPAGE_OPEN"
                ? "CloseInGameMenu(Resume) did not close the menu (a sub-page such as settings may be open). Nothing else was clicked."
                : "The menu closed but the clocks did not start again in time (" + verdictAfter + ").",
                code, true, "", "", output);
        }
        output["paused"] = false;
        return MakeSuccess(output);
    }
}
