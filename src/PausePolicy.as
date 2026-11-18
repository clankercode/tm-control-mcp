namespace TmMcp {
    // Pure pause policy: no game types, so tests/test_pause_tools.py runs it in
    // stock AngelScript. The live side is src/PauseTools.as.
    //
    // The game has no public "pause the simulation" call. The only pause is the
    // game's own in-game (ESC) menu, and it only stops time where the mode
    // script runs in this process (solo / local play). Online, the menu opens
    // but the server keeps going. So a pause is never judged on
    // IsInGameMenuDisplayed: it is judged on the clocks standing still for a
    // whole hold window. One equal sample proves nothing -- the simulation
    // ticks about every 10 ms, so a 240 fps frame often sees the same value.

    const int PAUSE_SAMPLE_MS_DEFAULT = 300;
    const int PAUSE_SAMPLE_MS_MAX = 2000;
    const int PAUSE_HOLD_MS_DEFAULT = 300;
    const int PAUSE_HOLD_MS_MIN = 100;
    const int PAUSE_HOLD_MS_MAX = 2000;
    const int PAUSE_TIMEOUT_MS_DEFAULT = 3000;
    const int PAUSE_TIMEOUT_MS_MIN = 100;
    const int PAUSE_TIMEOUT_MS_MAX = 10000;

    const string PAUSE_VERDICT_FROZEN = "frozen";
    const string PAUSE_VERDICT_RUNNING = "running";
    const string PAUSE_VERDICT_MIXED = "mixed";
    const string PAUSE_VERDICT_UNKNOWN = "unknown";

    // Clamped in double BEFORE narrowing to int, so any JSON number (huge,
    // infinite, fractional) lands inside [lo, hi]. NaN takes lo: it is
    // tested on its own because AngelScript's double compare does not order
    // NaN the IEEE way (NaN >= x is true there). Fractions are truncated
    // after the clamp.
    int _ClampMs(double v, bool given, int dflt, int lo, int hi) {
        if (!given) return dflt;
        if (v != v) return lo;
        if (v < double(lo)) return lo;
        if (v > double(hi)) return hi;
        return int(v);
    }

    int ClampPauseSampleMs(double v, bool given) {
        return _ClampMs(v, given, PAUSE_SAMPLE_MS_DEFAULT, 0, PAUSE_SAMPLE_MS_MAX);
    }

    int ClampPauseHoldMs(double v, bool given) {
        return _ClampMs(v, given, PAUSE_HOLD_MS_DEFAULT, PAUSE_HOLD_MS_MIN, PAUSE_HOLD_MS_MAX);
    }

    int ClampPauseTimeoutMs(double v, bool given) {
        return _ClampMs(v, given, PAUSE_TIMEOUT_MS_DEFAULT, PAUSE_TIMEOUT_MS_MIN, PAUSE_TIMEOUT_MS_MAX);
    }

    // CGamePlaygroundClientScriptAPI.GameTime is a signed int; the core clocks
    // are uint. Keep the bit pattern so deltas are modulo 2^32 like the others.
    uint ClockBits(int signedClock) {
        return uint(signedClock);
    }

    // Forward distance from a to b, modulo 2^32 (handles the wrap).
    uint ClockForwardDelta(uint a, uint b) {
        return b - a;
    }

    // Signed step from the paused value to the first value after resume.
    // Small positive = a normal resume; a value near the wall-clock pause
    // length = the clock caught up (a jump); negative = it went backwards.
    int ClockJumpMs(uint pausedValue, uint firstNewValue) {
        return int(firstNewValue - pausedValue);
    }

    // available: clocks that could be read for the whole window.
    // changed:   how many of those changed at least once in it.
    // windowMs:  how long the window really lasted; holdMs: the required hold.
    string PauseVerdict(uint available, uint changed, uint windowMs, uint holdMs) {
        if (available == 0) return PAUSE_VERDICT_UNKNOWN;
        if (changed == 0) return windowMs >= holdMs ? PAUSE_VERDICT_FROZEN : PAUSE_VERDICT_UNKNOWN;
        if (changed == available || changed >= 2) return PAUSE_VERDICT_RUNNING;
        return PAUSE_VERDICT_MIXED;
    }

    // Locality gate, checked BEFORE the menu is opened. "" = may try to pause.
    // playgroundScriptLocal: app.PlaygroundScript is set (the mode script runs
    // in this process). serverLoginSet: ServerInfo.ServerLogin is not empty.
    // IsServerOrSolo is deliberately not an input: its name covers servers.
    string PauseRefusalCode(bool inPlayground, bool loading, bool playgroundScriptLocal,
                            bool serverLoginSet, bool spectatorClient) {
        if (!inPlayground) return "NO_PLAYGROUND";
        if (loading) return "LOADING";
        if (!playgroundScriptLocal || serverLoginSet || spectatorClient) return "ONLINE_NOT_PAUSABLE";
        return "";
    }

    string PauseRefusalReason(const string &in code, bool playgroundScriptLocal,
                              bool serverLoginSet, bool spectatorClient) {
        if (code == "NO_PLAYGROUND") return "no playground: load a map (solo / local play) first";
        if (code == "LOADING") return "the game is on a loading screen";
        if (code == "ONLINE_NOT_PAUSABLE") {
            string why = "";
            if (!playgroundScriptLocal) why += " the mode script is not running in this game (PlaygroundScript is null);";
            if (serverLoginSet) why += " connected to a server (ServerLogin set);";
            if (spectatorClient) why += " spectator client;";
            return "the in-game menu would not stop the game here:" + why
                + " it only pauses solo / local play. Nothing was opened.";
        }
        return "";
    }

    bool IsValidPauseAction(const string &in action) {
        return action == "pause" || action == "resume" || action == "toggle";
    }

    // toggle decides on the menu: every pause this tool makes has the menu up.
    string ResolvePauseAction(const string &in action, bool menuShown) {
        if (action == "toggle") return menuShown ? "resume" : "pause";
        return action;
    }

    // What to do for a resolved action, given the state before acting.
    //  "noop"   already in the wanted state (success, changed:false)
    //  "open"   open the in-game menu, then verify the clocks froze
    //  "close"  close the in-game menu with Resume, then verify they run
    //  "verify" touch nothing, just sample (state is ambiguous)
    //  ""       invalid action
    string PausePlan(const string &in resolved, bool menuShown, const string &in verdict) {
        if (resolved == "pause") {
            if (!menuShown) return "open";
            if (verdict == PAUSE_VERDICT_FROZEN) return "noop";
            return "verify"; // menu already up (someone else opened it): never re-open or close it
        }
        if (resolved == "resume") {
            if (menuShown) return "close";
            if (verdict == PAUSE_VERDICT_RUNNING) return "noop";
            return "verify"; // no menu but not running: nothing of ours to close
        }
        return "";
    }

    // After this call sent ShowInGameMenu, the outcome code. "" = success
    // (paused). Anything else: the call sends ONE Resume if it saw the menu
    // open and the context is unchanged, then reports the menu state it
    // observed (CLEANUP_FAILED when the menu is still up).
    string PauseOutcomeCode(bool menuShownAfter, const string &in verdictAfter) {
        if (!menuShownAfter) return "MENU_NOT_SHOWN";
        if (verdictAfter == PAUSE_VERDICT_FROZEN) return "";
        return "NOT_PAUSED";
    }

    // After a close: "" = success (running again).
    string ResumeOutcomeCode(bool menuShownAfter, const string &in verdictAfter) {
        if (menuShownAfter) return "MENU_SUBPAGE_OPEN";
        if (verdictAfter == PAUSE_VERDICT_RUNNING) return "";
        return "RESUME_UNVERIFIED";
    }

    // --- One deadline per call ----------------------------------------------
    // The deadline is checked once per game frame (right after each yield and
    // before each ShowInGameMenu), so a frame hitch can overrun it by up to
    // that frame's length. It is not a wall-clock cap.
    // A failed pause keeps this much of the budget to watch its one Resume land.
    const int PAUSE_CLEANUP_RESERVE_MS = 2000;

    // The initial sample can restart (a clock unreadable for a frame); it gets
    // at most twice holdMs before the call goes on with what it has.
    uint PauseInitialSampleLimitMs(uint holdMs) {
        return 2 * holdMs;
    }

    // The whole ControlPause call, clamped inputs: the initial sample
    // (<= 2*holdMs), timeoutMs for the show or close, holdMs for the
    // verification window, then the cleanup reserve. Nothing in a call waits
    // past this; tools/call.py gives the socket this plus slack.
    uint PauseCallBudgetMs(uint holdMs, uint timeoutMs) {
        return 3 * holdMs + timeoutMs + uint(PAUSE_CLEANUP_RESERVE_MS);
    }

    // GetPauseState: the window may restart, so it gets at most this long.
    uint PauseStateSampleLimitMs(uint sampleMs) {
        return 2 * sampleMs + 100;
    }

    // Why a call stopped part-way. Codes come from PauseRefusalCode, plus
    // CONTEXT_CHANGED, DIALOG_BLOCKING, DEADLINE and MENU_CLOSED.
    string PauseStopMessage(const string &in code) {
        if (code == "CONTEXT_CHANGED") return "the playground or its interface handler changed (map change, restart or reload)";
        if (code == "LOADING") return "a loading screen started";
        if (code == "NO_PLAYGROUND") return "the playground went away";
        if (code == "ONLINE_NOT_PAUSABLE") return "the game is no longer solo/local play";
        if (code == "DIALOG_BLOCKING") return "a game dialog came up";
        if (code == "DEADLINE") return "the call's deadline (budgetMs) passed";
        if (code == "MENU_CLOSED") return "the in-game menu closed while the clocks were being checked";
        return code;
    }
}
