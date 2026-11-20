namespace TmMcp {
    // Live blocking-screen detection/dismissal. Pure policy (classification,
    // actions, whitelists) lives in BlockingScreensPolicy.as; this file reads
    // the real UI. See docs/blocking-screens.md for the page map and evidence.
    //
    // The two screens are ManiaLink pages, invisible to GetDialog:
    //  - Page_PressStart (layer named Page_PressStart): full-page start /
    //    connect flow. Detected controls: button-start-click (start prompt),
    //    frame-play-offline (+ button-play-offline / button-back / button-quit-game),
    //    loading-spinner-connection's menu-libs-loading-spinner_quad-loading,
    //    label-error, frame-ubi-connect, frame-welcome-back.
    //  - Page_ConnectionError: "Connection error" PopUpMultiChoice with one
    //    choice; its confirm button is
    //    trackmania-pop-up-multi-choice_button-first-choice.
    // Detection uses page name + control id + EFFECTIVE visibility (control
    // .Visible stays true under a hidden parent frame, so the parent chain is
    // walked). Button labels are set by the page script at runtime and are
    // reported, never matched on.

    const string BS_PAGE_PRESSSTART = "Page_PressStart";
    const string BS_PAGE_CONNERR = "Page_ConnectionError";

    CGameUILayer@ _BsFindPage(const string &in pageName, int &out layerIndex) {
        layerIndex = -1;
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return null;
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[i]; } catch { @layer = null; }
            if (layer is null) continue;
            if (_ExtractManialinkName(layer) == pageName) {
                layerIndex = int(i);
                return layer;
            }
        }
        return null;
    }

    // Effective visibility: the control AND every ManiaLink ancestor visible.
    // (The live trap: button-play-offline .Visible==true under hidden
    // frame-play-offline. Layer visibility is checked by the caller.)
    bool _BsControlVisible(CGameManialinkControl@ c) {
        if (c is null) return false;
        CGameManialinkControl@ cur = c;
        int guard = 0;
        while (cur !is null && guard < 16) {
            try { if (!bool(cur.Visible)) return false; }
            catch { return false; }
            try { @cur = cast<CGameManialinkControl>(cur.Parent); }
            catch { @cur = null; }
            guard++;
        }
        return true;
    }

    // Depth-first id search under a page frame (GetFirstChild is not reliably
    // recursive across frameinstance content, so descend manually).
    CGameManialinkControl@ _BsFindById(CGameManialinkFrame@ root, const string &in controlId, int maxDepth) {
        if (root is null || maxDepth < 0) return null;
        CGameManialinkControl@ hit = null;
        try { @hit = root.GetFirstChild(controlId); } catch { @hit = null; }
        if (hit !is null) return hit;
        uint n = 0;
        try { n = root.Controls.Length; } catch { n = 0; }
        for (uint i = 0; i < n; i++) {
            CGameManialinkControl@ c = null;
            try { @c = root.Controls[i]; } catch { @c = null; }
            auto f = cast<CGameManialinkFrame>(c);
            if (f is null) continue;
            @hit = _BsFindById(f, controlId, maxDepth - 1);
            if (hit !is null) return hit;
        }
        return null;
    }

    Json::Value _BsButtonEntry(CGameManialinkFrame@ root, const string &in frameId, const string &in action) {
        // Empty object => not found / not effectively visible; caller skips.
        Json::Value e = Json::Object();
        auto btn = _BsFindById(root, frameId, 8);
        if (btn is null || !_BsControlVisible(btn)) return e;
        e["id"] = frameId;
        string raw = _FindFirstLabelValue(btn, 6);
        e["label"] = raw;
        string stripped = StripTranslationMarkers(raw);
        if (stripped != raw) e["displayText"] = stripped;
        e["action"] = action;
        return e;
    }

    Json::Value BuildBlockingScreenSnapshot() {
        Json::Value o = Json::Object();
        o["mode"] = DetectGameModeName();
        auto menuApp = _GetMenuApp();
        if (menuApp is null) {
            o["available"] = false;
            o["kind"] = "none";
            o["blocking"] = false;
            o["needsAction"] = false;
            o["suggestedAction"] = "";
            return o;
        }
        o["available"] = true;

        bool psPageVisible = false;
        bool startVisible = false, offlineVisible = false, spinnerVisible = false;
        bool ubiVisible = false, welcomeVisible = false, errVisible = false;
        string statusText = "", errorText = "";

        Json::Value pressStart = Json::Object();
        pressStart["pageVisible"] = false;
        int psIndex = -1;
        auto psLayer = _BsFindPage(BS_PAGE_PRESSSTART, psIndex);
        if (psLayer !is null) {
            pressStart["layerIndex"] = psIndex;
            bool lv = true;
            try { lv = bool(psLayer.IsVisible); } catch { lv = false; }
            psPageVisible = lv;
            pressStart["pageVisible"] = lv;
            if (lv) {
                CGameManialinkPage@ page = null;
                try { @page = psLayer.LocalPage; } catch { @page = null; }
                CGameManialinkFrame@ root = null;
                if (page !is null) {
                    try { @root = page.MainFrame; } catch { @root = null; }
                }
                if (root !is null) {
                    startVisible = _BsControlVisible(_BsFindById(root, "button-start-click", 8));
                    offlineVisible = _BsControlVisible(_BsFindById(root, "frame-play-offline", 8));
                    spinnerVisible = _BsControlVisible(_BsFindById(root, "menu-libs-loading-spinner_quad-loading", 8));
                    ubiVisible = _BsControlVisible(_BsFindById(root, "frame-ubi-connect", 8));
                    welcomeVisible = _BsControlVisible(_BsFindById(root, "frame-welcome-back", 8));
                    auto errLabel = _BsFindById(root, "label-error", 6);
                    errVisible = _BsControlVisible(errLabel);
                    if (errVisible) errorText = _ReadLabelValue(errLabel);
                    auto statusLabel = _BsFindById(root, "ComponentOnlineServicesStatusCard_label-online-services-status-name", 12);
                    if (statusLabel !is null && _BsControlVisible(statusLabel)) {
                        statusText = _ReadLabelValue(statusLabel);
                    }
                    Json::Value buttons = Json::Array();
                    Json::Value b;
                    b = _BsButtonEntry(root, "button-play-offline", "play-offline");
                    if (b.GetKeys().Length > 0) buttons.Add(b);
                    b = _BsButtonEntry(root, "button-back", "retry");
                    if (b.GetKeys().Length > 0) buttons.Add(b);
                    b = _BsButtonEntry(root, "button-quit-game", "quit");
                    if (b.GetKeys().Length > 0) buttons.Add(b);
                    b = _BsButtonEntry(root, "button-ubi-connect-offline", "play-offline");
                    if (b.GetKeys().Length > 0) buttons.Add(b);
                    b = _BsButtonEntry(root, "button-welcome-back-later", "later");
                    if (b.GetKeys().Length > 0) buttons.Add(b);
                    pressStart["buttons"] = buttons;
                }
            }
        }
        pressStart["startPromptVisible"] = startVisible;
        pressStart["offlineButtonsVisible"] = offlineVisible;
        pressStart["connecting"] = spinnerVisible;
        pressStart["ubiConnectVisible"] = ubiVisible;
        pressStart["welcomeBackVisible"] = welcomeVisible;
        if (errorText.Length > 0) pressStart["errorText"] = errorText;
        if (statusText.Length > 0) {
            pressStart["onlineServicesStatus"] = statusText;
            pressStart["onlineServicesStatusKind"] = NormalizeOnlineServicesStatus(statusText);
        }
        o["pressStart"] = pressStart;

        bool cePopupVisible = false;
        string ceTitle = "", ceDescription = "", ceConfirm = "";
        Json::Value connErr = Json::Object();
        connErr["pageVisible"] = false;
        int ceIndex = -1;
        auto ceLayer = _BsFindPage(BS_PAGE_CONNERR, ceIndex);
        if (ceLayer !is null) {
            connErr["layerIndex"] = ceIndex;
            bool lv = true;
            try { lv = bool(ceLayer.IsVisible); } catch { lv = false; }
            connErr["pageVisible"] = lv;
            if (lv) {
                CGameManialinkPage@ page = null;
                try { @page = ceLayer.LocalPage; } catch { @page = null; }
                CGameManialinkFrame@ root = null;
                if (page !is null) {
                    try { @root = page.MainFrame; } catch { @root = null; }
                }
                if (root !is null) {
                    cePopupVisible = _BsControlVisible(_BsFindById(root, "popupmultichoice-confirm", 8));
                    if (cePopupVisible) {
                        ceTitle = _ReadLabelValue(_BsFindById(root, "trackmania-pop-up-multi-choice_label-title", 12));
                        ceDescription = _ReadLabelValue(_BsFindById(root, "trackmania-pop-up-multi-choice_label-description-line-0", 12));
                        auto confirmBtn = _BsFindById(root, "trackmania-pop-up-multi-choice_button-first-choice", 12);
                        if (confirmBtn !is null) ceConfirm = _FindFirstLabelValue(confirmBtn, 6);
                    }
                }
            }
        }
        if (ceTitle.Length > 0) connErr["title"] = ceTitle;
        if (ceDescription.Length > 0) connErr["description"] = ceDescription;
        if (ceConfirm.Length > 0) {
            connErr["confirmLabel"] = ceConfirm;
            connErr["confirmDisplayText"] = StripTranslationMarkers(ceConfirm);
        }
        o["connectionError"] = connErr;

        string kind = ClassifyBlockingScreen(psPageVisible, startVisible, offlineVisible,
            spinnerVisible, ubiVisible, welcomeVisible, cePopupVisible);
        o["kind"] = kind;
        o["blocking"] = kind != "none";
        o["needsAction"] = BlockingScreenKindNeedsAction(kind);
        o["suggestedAction"] = BlockingScreenAutoAction(kind);
        return o;
    }

    Json::Value@ GetBlockingScreen(Json::Value &in input) {
        return MakeSuccess(BuildBlockingScreenSnapshot());
    }

    // Resolve the click target for an action. Confirm lives on
    // Page_ConnectionError; every other action on Page_PressStart.
    // play-offline has two possible ids depending on kind. Returns null with
    // err set when the page/root/control is unavailable.
    CGameManialinkControl@ _BsResolveTarget(const string &in action, const string &in kind,
                                            string &out targetId, string &out err) {
        err = "";
        targetId = "";
        bool onConnErr = action == "confirm";
        if (action == "start") targetId = "button-start-click";
        else if (action == "confirm") targetId = "trackmania-pop-up-multi-choice_button-first-choice";
        else if (action == "play-offline")
            targetId = kind == "ubi-connect" ? "button-ubi-connect-offline" : "button-play-offline";
        else if (action == "retry") targetId = "button-back";
        else if (action == "later") targetId = "button-welcome-back-later";
        else { err = "no target for action '" + action + "'"; return null; }

        int idx = -1;
        auto layer = _BsFindPage(onConnErr ? BS_PAGE_CONNERR : BS_PAGE_PRESSSTART, idx);
        if (layer is null) {
            err = (onConnErr ? BS_PAGE_CONNERR : BS_PAGE_PRESSSTART) + " layer not found";
            return null;
        }
        CGameManialinkPage@ page = null;
        try { @page = layer.LocalPage; } catch { @page = null; }
        CGameManialinkFrame@ root = null;
        if (page !is null) {
            try { @root = page.MainFrame; } catch { @root = null; }
        }
        if (root is null) {
            err = (onConnErr ? BS_PAGE_CONNERR : BS_PAGE_PRESSSTART) + " has no MainFrame";
            return null;
        }
        return _BsFindById(root, targetId, 12);
    }

    Json::Value@ DismissBlockingScreen(Json::Value &in input) {
        if (_GetMenuApp() is null) {
            return MakeError("menu mania app not available (not in menu?)", "WRONG_MODE", false, "Menu",
                "These screens exist only in the main menu module.");
        }
        string action = input.HasKey("action") ? string(input["action"]).ToLower() : "auto";
        if (!IsValidBlockingScreenAction(action)) {
            return MakeError("action must be one of: auto, start, confirm, play-offline, retry, later", "INVALID_INPUT", false, "",
                "GetBlockingScreen lists each visible button with its action. The quit button is never clicked by this tool.");
        }
        int waitMs = input.HasKey("waitMs") ? int(input["waitMs"]) : 15000;
        if (waitMs < 0) waitMs = 0;
        if (waitMs > 120000) waitMs = 120000;

        auto before = BuildBlockingScreenSnapshot();
        string kind = string(before["kind"]);

        if (action == "auto") {
            action = BlockingScreenAutoAction(kind);
            if (action.Length == 0) {
                Json::Value output = Json::Object();
                output["acted"] = false;
                output["kind"] = kind;
                output["note"] = kind == "none"
                    ? "No blocking screen is up."
                    : "Kind '" + kind + "' resolves on its own; poll GetBlockingScreen or WaitUntil {condition:'menuReached'}.";
                return MakeSuccess(output);
            }
        }
        // Explicit actions must fit the screen actually up (agent bug guard).
        bool fits = (action == "start" && kind == "start-screen")
            || (action == "confirm" && kind == "connection-error")
            || (action == "play-offline" && (kind == "connection-failed" || kind == "ubi-connect"))
            || (action == "retry" && kind == "connection-failed")
            || (action == "later" && kind == "welcome-back");
        if (!fits) {
            return MakeError("action '" + action + "' does not fit kind '" + kind + "'", "WRONG_KIND", false, "",
                "Re-read GetBlockingScreen; call with action:auto to take the suggested action.");
        }

        string targetId = "";
        string resolveErr = "";
        CGameManialinkControl@ target = _BsResolveTarget(action, kind, targetId, resolveErr);
        if (target is null) {
            return MakeError("target not found: " + resolveErr, "NOT_FOUND", true, "",
                "The page may have changed; re-read GetBlockingScreen.");
        }
        if (!ActionTargetsControl(action, targetId)) {
            return MakeError("refusing to click '" + targetId + "' for action '" + action + "'", "NOT_WHITELISTED", false, "",
                "Whitelist: start=button-start-click, confirm=pop-up first-choice, play-offline=button-play-offline|button-ubi-connect-offline, retry=button-back, later=button-welcome-back-later.");
        }
        if (!_BsControlVisible(target)) {
            return MakeError("target '" + targetId + "' is not effectively visible", "NOT_VISIBLE", true, "",
                "The screen state changed under us; re-read GetBlockingScreen.");
        }

        // Click like ClickMenuButton does: nav-zone leaf if there is one
        // (expendable buttons), else the control's own CControlBase
        // (button-start-click is a plain scriptevents quad).
        CControlBase@ base = null;
        bool viaNavZone = false;
        auto zone = _FindNavZoneInSubtree(target, 10);
        if (zone !is null) {
            try { @base = zone.Control; } catch { @base = null; }
            viaNavZone = base !is null;
        }
        if (base is null) {
            try { @base = target.Control; } catch { @base = null; }
        }
        if (base is null) {
            return MakeError("no CControlBase under '" + targetId + "'", "NOT_FOUND", true);
        }
        try {
            base.OnAction();
        } catch {
            return MakeError("OnAction() threw on '" + targetId + "': " + getExceptionInfo(), "CLICK_FAILED", true);
        }

        Json::Value output = Json::Object();
        output["acted"] = true;
        output["action"] = action;
        output["kind"] = kind;
        output["clickedControl"] = targetId;
        output["viaNavZone"] = viaNavZone;
        output["waitMs"] = waitMs;

        // Wait for the screen state to move off the kind we clicked (e.g.
        // start-screen -> connecting -> home, or connection-error -> press-start).
        uint64 t0 = Time::Now;
        if (waitMs > 0) {
            while (Time::Now - t0 < uint64(waitMs)) {
                yield();
                auto nowSnap = BuildBlockingScreenSnapshot();
                if (string(nowSnap["kind"]) != kind) break;
            }
        }
        // Settle: the router push after a confirm (RequestRestart ->
        // /press-start) lands a few frames after the popup closes, and a
        // snapshot taken in between would call menuReached prematurely.
        for (int i = 0; i < 5; i++) yield();
        auto after = BuildBlockingScreenSnapshot();
        output["after"] = after;
        output["waitedMs"] = int(Time::Now - t0);
        output["menuReached"] = string(after["kind"]) == "none" && string(after["mode"]) == "Menu";
        if (string(after["kind"]) == kind) {
            output["warning"] = "still on kind '" + kind + "' after " + int(Time::Now - t0) + "ms; the click may not have advanced it. Re-read GetBlockingScreen.";
        }
        return MakeSuccess(output);
    }
}
