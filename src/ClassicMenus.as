namespace TmMcp {
    // "Classic" menus: the engine's own CGameMenuFrame dialogs on app.ActiveMenus (server join
    // card, map-saved card, ...), as opposed to the ManiaLink pages of the main menu. Their
    // controls are CControl* nods found by id name; a click is CControlButton.OnAction().
    //
    // Many of them are cards (CGameControlCardGeneric) whose clickable part is a child button
    // named ButtonSelection, and one frame can hold several cards, so "the first ButtonSelection"
    // is not a safe target: name the card.

    // Only server join links: this is not a general "open any link" tool.
    bool IsJoinLink(const string &in link) {
        return (link.StartsWith("#join=") || link.StartsWith("#spectate=")) && link.Length > 10
            && !link.Contains(" ") && !link.Contains("\n");
    }

    // The button to fire for a named control: itself if it is a button, else its ButtonSelection.
    CControlButton@ _ClassicButtonOf(CControlBase@ target) {
        auto btn = cast<CControlButton>(target);
        if (btn !is null) return btn;
        return cast<CControlButton>(_DlgFindChildRecursive(target, "ButtonSelection", 0));
    }

    // Finds `id` under the current frame of the topmost active menu that has it. menuIndex >= 0
    // restricts the search to that menu.
    CControlBase@ _ClassicFind(CTrackMania@ app, const string &in id, int menuIndex, int &out foundIndex, string &out frameName) {
        foundIndex = -1;
        frameName = "";
        for (int i = int(app.ActiveMenus.Length) - 1; i >= 0; i--) {
            if (menuIndex >= 0 && i != menuIndex) continue;
            auto menu = app.ActiveMenus[i];
            if (menu is null || menu.CurrentFrame is null) continue;
            auto found = _DlgFindChildRecursive(menu.CurrentFrame, id, 0);
            if (found is null) continue;
            foundIndex = i;
            frameName = menu.CurrentFrame.IdName;
            return found;
        }
        return null;
    }

    string _ClassicTopFrame(CTrackMania@ app) {
        for (int i = int(app.ActiveMenus.Length) - 1; i >= 0; i--) {
            auto menu = app.ActiveMenus[i];
            if (menu !is null && menu.CurrentFrame !is null) return menu.CurrentFrame.IdName;
        }
        return "";
    }

    Json::Value@ ClickClassicMenuControl(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return MakeError("no app");
        if (!input.HasKey("id") || input["id"].GetType() != Json::Type::String) return MakeError("id (control id name) is required", "INVALID_INPUT");
        string id = string(input["id"]);
        int menuIndex = input.HasKey("menuIndex") ? int(input["menuIndex"]) : -1;
        int foundIndex;
        string frameName;
        auto target = _ClassicFind(app, id, menuIndex, foundIndex, frameName);
        if (target is null) {
            return MakeError("no control '" + id + "' under an active classic menu frame (top frame: '" + _ClassicTopFrame(app) + "')",
                "NOT_FOUND", false, "", "GetMenuFrameTree {menuIndex} lists the ids.");
        }
        auto btn = _ClassicButtonOf(target);
        if (btn is null) return MakeError("'" + id + "' is not a button and has no ButtonSelection child", "INVALID_INPUT");
        bool visible = btn.IsVisible && target.IsVisible;
        bool requireVisible = !input.HasKey("requireVisible") || bool(input["requireVisible"]);
        if (requireVisible && !visible) return MakeError("'" + id + "' is not visible", "NOT_VISIBLE");
        btn.OnAction();
        Json::Value output = Json::Object();
        output["clicked"] = id;
        output["menuIndex"] = foundIndex;
        output["frame"] = frameName;
        output["viaButtonSelection"] = cast<CControlButton>(target) is null;
        output["visible"] = visible;
        return MakeSuccess(output);
    }

    string _ServerLoginNow(CTrackMania@ app) {
        if (app.Network is null) return "";
        auto info = cast<CGameCtnNetServerInfo>(app.Network.ServerInfo);
        return info is null ? "" : string(info.ServerLogin);
    }

    // Opens a join link from the main menu, confirms the server card, and waits for the playground.
    Json::Value@ JoinServer(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.ManiaPlanetScriptAPI is null) return MakeError("no app");
        if (!input.HasKey("link") || input["link"].GetType() != Json::Type::String) return MakeError("link is required", "INVALID_INPUT");
        string link = string(input["link"]);
        if (!IsJoinLink(link)) return MakeError("link must be '#join=host:password:port' or '#spectate=...'", "INVALID_INPUT");
        bool spectate = link.StartsWith("#spectate=") || (input.HasKey("spectate") && bool(input["spectate"]));
        uint timeoutMs = input.HasKey("timeoutMs") ? uint(int(input["timeoutMs"])) : 60000;
        if (app.RootMap !is null || app.CurrentPlayground !is null || app.Editor !is null) {
            return MakeError("JoinServer starts from the main menu", "WRONG_MODE", false, "Menu", "BackToMainMenu first.");
        }
        Json::Value output = Json::Object();
        string cardButton = spectate ? "ButtonSpectator" : "ButtonJoin";
        int idx;
        string frame;
        // A join card left up by an earlier link is reused instead of opening a second one.
        if (_ClassicFind(app, cardButton, -1, idx, frame) is null) {
            app.ManiaPlanetScriptAPI.OpenLink(link, CGameManiaPlanetScriptAPI::ELinkType::ManialinkBrowser);
        }
        uint64 t0 = Time::Now;
        string stage = "waitingForCard";
        bool clicked = false;
        while (Time::Now - t0 < timeoutMs) {
            yield();
            if (app.CurrentPlayground !is null && _ServerLoginNow(app).Length > 0) { stage = "joined"; break; }
            if (clicked) continue;
            auto target = _ClassicFind(app, cardButton, -1, idx, frame);
            if (target is null) continue;
            auto btn = _ClassicButtonOf(target);
            if (btn is null || !btn.IsVisible) continue;
            // The card fills in (name, maps, ping) over a few frames after it appears.
            if (Time::Now - t0 < 1500) continue;
            btn.OnAction();
            clicked = true;
            stage = "waitingForPlayground";
            output["cardFrame"] = frame;
        }
        output["stage"] = stage;
        output["joined"] = stage == "joined";
        output["clickedCard"] = clicked;
        output["waitedMs"] = int(Time::Now - t0);
        output["serverLogin"] = _ServerLoginNow(app);
        output["topFrame"] = _ClassicTopFrame(app);
        if (stage != "joined") {
            return MakeError(clicked ? "the server card was confirmed but the playground did not start in time"
                                     : "the server card did not appear (wrong address, password, or server down)",
                "JOIN_FAILED", true, "", "GetDialog / GetMenuFrameTree show what is up; RespondDialog {action:frame-cancel} closes a card.");
        }
        return MakeSuccess(output);
    }
}
