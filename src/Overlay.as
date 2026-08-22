namespace TmMcp {
    // Openplanet's own overlay -- the F3 menu bar and every plugin window --
    // not the game's HUD. The two are unrelated: the game HUD (the chrono,
    // the records panel, the chat) lives on CGamePlaygroundUIConfig's
    // OverlayHide* fields and is untouched here.
    //
    // This exists because the overlay being up over the viewport has real
    // consequences beyond looking untidy:
    //
    //  * A play-mode camera switch (ControlPlayCamera set_mode) is only
    //    consumed on a live playground tick and is silently dropped while the
    //    overlay is up. That cost a long debugging session -- every mechanism,
    //    every mode, dropped, with uiSequence Playing and the player spawned.
    //  * A screenshot with the overlay up is largely a screenshot of the
    //    overlay. Anything measuring rendered pixels wants it gone first.
    //
    // The API is Openplanet's, documented and stable: UI::ShowOverlay(),
    // UI::HideOverlay(), UI::IsOverlayShown(), UI::IsRendering(). No memory
    // offsets, so unlike ControlPlayCamera this cannot break on a game update.

    // Whether Openplanet is drawing its overlay at all, which is NOT the same
    // question as whether the overlay is shown. The global option "Hide overlay
    // on hidden game UI" makes IsRendering() false while IsOverlayShown() stays
    // true -- so a caller that only checked `shown` would conclude the overlay
    // is in the way when nothing is being drawn, and vice versa. Both are
    // reported, always.
    Json::Value@ OverlayStateJson() {
        Json::Value state = Json::Object();
        state["shown"] = UI::IsOverlayShown();
        state["rendering"] = UI::IsRendering();
        return state;
    }

    void OverlaySettle(Json::Value &in input) {
        // Show/Hide flips the flag at once, but the frame on screen is the one
        // already drawn. A caller that hides the overlay in order to screenshot
        // needs the next frames to have gone by, so this yields by default
        // rather than making every caller remember to.
        int frames = input.HasKey("settleFrames") ? int(input["settleFrames"]) : 2;
        if (frames < 0) frames = 0;
        if (frames > 30) frames = 30;
        for (int i = 0; i < frames; i++) yield();
    }

    Json::Value@ ControlOverlay(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "get";

        Json::Value output = Json::Object();
        output["action"] = action;
        output["before"] = OverlayStateJson();

        bool wantShown = false;
        if (action == "get") {
            // No settle and no write: `get` must be free to call in a loop.
            output["state"] = OverlayStateJson();
            output["changed"] = false;
            return MakeSuccess(output);
        } else if (action == "show") {
            wantShown = true;
        } else if (action == "hide") {
            wantShown = false;
        } else if (action == "toggle") {
            wantShown = !UI::IsOverlayShown();
        } else {
            return MakeError("unknown action '" + action
                             + "' (expected get|show|hide|toggle)",
                             "BAD_ACTION");
        }

        const bool was = UI::IsOverlayShown();
        if (wantShown) {
            UI::ShowOverlay();
        } else {
            UI::HideOverlay();
        }
        OverlaySettle(input);

        Json::Value@ after = OverlayStateJson();
        output["after"] = after;
        output["state"] = after;
        // Judged on the readback, not on the call having been made. Reported
        // separately from `changed` because "already in the wanted state" and
        // "the write did not take" are different answers and a caller retrying
        // the second must not loop on the first.
        output["shown"] = bool(after["shown"]);
        output["changed"] = was != bool(after["shown"]);
        output["asRequested"] = bool(after["shown"]) == wantShown;
        return MakeSuccess(output);
    }
}
