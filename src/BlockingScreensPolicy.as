namespace TmMcp {
    // Pure blocking-screen policy: no game types, so
    // tests/test_blocking_screens.py runs it in stock AngelScript. The live
    // side is src/BlockingScreens.as. See docs/blocking-screens.md.
    //
    // TM2020 has two full-page menu screens that stall menu-only agents and
    // that GetDialog does not see (they are ManiaLink pages, not BasicDialogs):
    //  - Page_ConnectionError: "Connection error" pop-up (one choice,
    //    "Confirm"); on confirm the menu restarts on Page_PressStart.
    //  - Page_PressStart: "Start" prompt (auto-connects on PC unless the
    //    online-services status makes it wait for input), a connecting
    //    spinner, and after a failure the buttons button-play-offline /
    //    button-back ("Retry") / button-quit-game.
    // Both are detected by page name + control ids + effective visibility;
    // runtime-set button labels are only reported, never matched (label
    // search is blind to them until their page script has run).

    const string BS_STATUS_NONE = "none";
    const string BS_STATUS_MAINTENANCE = "maintenance";
    const string BS_STATUS_DISRUPTION = "disruption";
    const string BS_STATUS_UNKNOWN = "unknown";

    // Keyword read of the online-services status card. Marker-stripping is
    // not needed to recognise the words; anything unrecognised (incl. empty)
    // is "none"/"unknown" — over-detecting a start screen is harmless because
    // clicking Start when the page would auto-connect anyway just starts the
    // connection immediately. Substrings are chosen case-stable (stock
    // AngelScript strings have no ToLower; Openplanet text uses "Maintenance").
    string NormalizeOnlineServicesStatus(const string &in raw) {
        if (raw.Trim().Length == 0) return BS_STATUS_NONE;
        if (raw.IndexOf("aintenance") >= 0) return BS_STATUS_MAINTENANCE;
        if (raw.IndexOf("isruption") >= 0) return BS_STATUS_DISRUPTION;
        if (raw.IndexOf("o issues") >= 0) return BS_STATUS_NONE;
        return BS_STATUS_UNKNOWN;
    }

    // Nadeo label text uses \x91 (fallback text) / \x92 (translated text)
    // markers, stored as the UTF-8 two-byte sequences C2 91 / C2 92 in
    // AngelScript strings, plus |Context| prefixes. Same conventions as
    // _StripTranslationPrefix (ManialinkIntrospection.as), self-contained so
    // the policy file compiles in stock AngelScript.
    const string BS_U91 = "\xC2\x91";
    const string BS_U92 = "\xC2\x92";

    string StripTranslationMarkers(const string &in raw) {
        string s = raw;
        while (true) {
            if (s.Length >= 2 && s.SubStr(0, 2) == BS_U91) {
                string rest = s.SubStr(2);
                int close = rest.IndexOf(BS_U91);
                if (close >= 0) s = rest.SubStr(uint(close + 2));
                else s = rest;
                continue;
            }
            if (s.Length >= 2 && s.SubStr(0, 2) == BS_U92) {
                s = s.SubStr(2);
                continue;
            }
            if (s.Length > 1 && s.SubStr(0, 1) == "|") {
                int close = s.SubStr(1).IndexOf("|"); // closing bar of |Context|
                if (close >= 0) {
                    s = s.SubStr(uint(close + 2));
                    continue;
                }
            }
            break;
        }
        // Whatever marker remains is the start of a fallback/composed tail
        // (e.g. "Maintenance\x91$<$FA0…$>"); display text ends there.
        int cut = s.IndexOf(BS_U91);
        int cut2 = s.IndexOf(BS_U92);
        if (cut < 0 || (cut2 >= 0 && cut2 < cut)) cut = cut2;
        if (cut >= 0) s = s.SubStr(0, uint(cut));
        return s;
    }

    // Effective kind from the two pages' control visibility, pre-read by the
    // caller. connection-error first (the pop-up renders over whatever route
    // was active); then Page_PressStart's states, most specific first.
    string ClassifyBlockingScreen(bool pressStartPageVisible, bool psStartVisible,
                                  bool psOfflineVisible, bool psSpinnerVisible,
                                  bool psUbiConnectVisible, bool psWelcomeBackVisible,
                                  bool connErrPopupVisible) {
        if (connErrPopupVisible) return "connection-error";
        if (!pressStartPageVisible) return "none";
        if (psUbiConnectVisible) return "ubi-connect";
        if (psWelcomeBackVisible) return "welcome-back";
        if (psOfflineVisible) return "connection-failed";
        if (psStartVisible) return "start-screen";
        if (psSpinnerVisible) return "connecting";
        return "none";
    }

    // Kinds an agent can and should dismiss. "connecting" blocks too but
    // resolves on its own (or becomes connection-failed).
    bool BlockingScreenKindNeedsAction(const string &in kind) {
        return kind == "start-screen" || kind == "connection-error"
            || kind == "connection-failed" || kind == "ubi-connect"
            || kind == "welcome-back";
    }

    // The dismiss action for a kind; "" when the kind needs none.
    // Never "quit": the quit button belongs to the operator, not the agent.
    string BlockingScreenAutoAction(const string &in kind) {
        if (kind == "start-screen") return "start";
        if (kind == "connection-error") return "confirm";
        if (kind == "connection-failed") return "play-offline";
        if (kind == "ubi-connect") return "play-offline";
        if (kind == "welcome-back") return "later";
        return "";
    }

    // Which control ids each action may click (tests pin this whitelist).
    // button-quit-game is deliberately absent.
    bool ActionTargetsControl(const string &in action, const string &in controlId) {
        if (action == "start") return controlId == "button-start-click";
        if (action == "confirm")
            return controlId == "trackmania-pop-up-multi-choice_button-first-choice";
        if (action == "play-offline")
            return controlId == "button-play-offline" || controlId == "button-ubi-connect-offline";
        if (action == "retry") return controlId == "button-back";
        if (action == "later") return controlId == "button-welcome-back-later";
        return false;
    }

    bool IsValidBlockingScreenAction(const string &in action) {
        return action == "auto" || action == "start" || action == "confirm"
            || action == "play-offline" || action == "retry" || action == "later";
    }
}
