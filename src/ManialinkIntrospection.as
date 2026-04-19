namespace TmMcp {
    // Introspection helpers for the Manialink UI layer tree. Used to expose
    // button/control paths to MCP callers so they can figure out which events
    // to fire via SetMenuPage / Queue_*_SendCustomEvent.

    // Recursively search all UI layers for a control with the given ControlId.
    // Returns the first match or null. Safe to call while the menu is rebuilding.
    CGameManialinkControl@ _FindControlById(const string &in controlId) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return null;
        CGameManiaAppTitle@ menuApp = null;
        try {
            auto menus = cast<CTrackManiaMenus>(app.MenuManager);
            if (menus !is null) @menuApp = menus.MenuCustom_CurrentManiaApp;
        } catch { @menuApp = null; }
        if (menuApp is null) return null;

        uint nbLayers = 0;
        try { nbLayers = menuApp.UILayers.Length; } catch { nbLayers = 0; }
        for (uint li = 0; li < nbLayers; li++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[li]; } catch { @layer = null; }
            if (layer is null) continue;
            CGameManialinkPage@ page = null;
            try { @page = layer.LocalPage; } catch { @page = null; }
            if (page is null) continue;
            CGameManialinkControl@ hit = null;
            try { @hit = page.GetFirstChild(controlId); } catch { @hit = null; }
            if (hit !is null) return hit;
        }
        return null;
    }

    Json::Value@ FocusMenuControl(Json::Value &in input) {
        if (!input.HasKey("controlId")) return MakeError("missing controlId");
        string controlId = string(input["controlId"]);
        auto ctrl = _FindControlById(controlId);
        if (ctrl is null) return MakeError("control not found: " + controlId);
        try { ctrl.Focus(); } catch {
            return MakeError("Focus() threw: " + getExceptionInfo());
        }
        Json::Value output = Json::Object();
        output["controlId"] = controlId;
        output["type"] = Reflection::TypeOf(ctrl).Name;
        try { output["wasFocused"] = bool(ctrl.IsFocused); } catch { output["wasFocused"] = false; }
        return MakeSuccess(output);
    }

    Json::Value _ControlToJson(CGameManialinkControl@ ctrl, const string &in path) {
        Json::Value obj = Json::Object();
        if (ctrl is null) {
            obj["null"] = true;
            return obj;
        }
        obj["path"] = path;
        string cid = "";
        try { cid = string(ctrl.ControlId); } catch { cid = "<error>"; }
        obj["controlId"] = cid;
        bool visible = true;
        try { visible = bool(ctrl.Visible); } catch { visible = false; }
        obj["visible"] = visible;
        Json::Value classes = Json::Array();
        try {
            for (uint i = 0; i < ctrl.ControlClasses.Length; i++) {
                classes.Add(string(ctrl.ControlClasses[i]));
            }
        } catch {
            classes.Add("<error>");
        }
        obj["classes"] = classes;
        string tyName = "?";
        try { tyName = Reflection::TypeOf(ctrl).Name; } catch { tyName = "?"; }
        obj["type"] = tyName;
        return obj;
    }

    void _WalkControl(CGameManialinkControl@ ctrl, const string &in path, int depth, int maxDepth, bool onlyWithId, bool includeHidden, Json::Value &inout results) {
        if (ctrl is null) return;
        if (depth > maxDepth) return;

        bool visible = true;
        try { visible = bool(ctrl.Visible); } catch { visible = true; }
        if (!includeHidden && !visible) return;

        string cid = "";
        try { cid = string(ctrl.ControlId); } catch { cid = ""; }

        bool include = !onlyWithId || cid.Length > 0;
        if (include) {
            results.Add(_ControlToJson(ctrl, path));
        }

        auto frame = cast<CGameManialinkFrame>(ctrl);
        if (frame is null) return;

        uint childCount = 0;
        try { childCount = frame.Controls.Length; } catch { childCount = 0; }
        for (uint i = 0; i < childCount; i++) {
            CGameManialinkControl@ child = null;
            try { @child = frame.Controls[i]; } catch { @child = null; }
            if (child is null) continue;
            string childId = "";
            try { childId = string(child.ControlId); } catch { childId = ""; }
            string childPath = path + "/" + (childId.Length > 0 ? childId : ("#" + i));
            _WalkControl(child, childPath, depth + 1, maxDepth, onlyWithId, includeHidden, results);
        }
    }

    Json::Value@ ListMenuManialinkControls(Json::Value &in input) {
        int maxDepth = input.HasKey("maxDepth") ? int(input["maxDepth"]) : 8;
        bool onlyWithId = input.HasKey("onlyWithId") ? bool(input["onlyWithId"]) : true;
        bool includeHidden = input.HasKey("includeHidden") ? bool(input["includeHidden"]) : false;
        int maxResults = input.HasKey("maxResults") ? int(input["maxResults"]) : 200;

        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return MakeError("app not available");
        CGameManiaAppTitle@ menuApp = null;
        try {
            auto menus = cast<CTrackManiaMenus>(app.MenuManager);
            if (menus !is null) @menuApp = menus.MenuCustom_CurrentManiaApp;
        } catch { @menuApp = null; }
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");

        Json::Value output = Json::Object();
        Json::Value layers = Json::Array();
        uint nbLayers = 0;
        try { nbLayers = menuApp.UILayers.Length; } catch { nbLayers = 0; }

        for (uint li = 0; li < nbLayers; li++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[li]; } catch { @layer = null; }
            if (layer is null) continue;

            Json::Value lj = Json::Object();
            lj["index"] = int(li);
            try { lj["type"] = int(layer.Type); } catch { lj["type"] = -1; }

            CGameManialinkPage@ page = null;
            try { @page = layer.LocalPage; } catch { @page = null; }
            lj["hasPage"] = page !is null;

            if (page !is null) {
                string url = "";
                try { url = string(page.Url); } catch { url = ""; }
                lj["url"] = url;

                CGameManialinkFrame@ mainFrame = null;
                try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
                if (mainFrame !is null) {
                    Json::Value layerControls = Json::Array();
                    _WalkControl(mainFrame, "L" + li, 0, maxDepth, onlyWithId, includeHidden, layerControls);
                    if (int(layerControls.Length) > maxResults) {
                        Json::Value trimmed = Json::Array();
                        for (int ci = 0; ci < maxResults; ci++) trimmed.Add(layerControls[ci]);
                        lj["controls"] = trimmed;
                        lj["trimmedAt"] = maxResults;
                    } else {
                        lj["controls"] = layerControls;
                    }
                }
            }
            layers.Add(lj);
        }
        output["nbLayers"] = int(nbLayers);
        output["layers"] = layers;
        output["note"] = "Only layers with a LocalPage have controls. Use onlyWithId=false to also list anonymous frames. Each control exposes controlId + classes + visibility; to act on one, fire a Manialink event keyed by its controlId (see the menu-navigation guide).";
        return MakeSuccess(output);
    }
}
