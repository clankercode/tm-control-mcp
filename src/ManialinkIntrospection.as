namespace TmMcp {
    // Introspection helpers for the Manialink UI layer tree. Used to expose
    // button/control paths to MCP callers so they can figure out which events
    // to fire via SetMenuPage / Queue_*_SendCustomEvent.

    string _LayerTypeName(int t) {
        switch (t) {
            case 0: return "Normal";
            case 1: return "ScoresTable";
            case 2: return "ScreenIn3d";
            case 3: return "AltMenu";
            case 4: return "Markers";
            case 5: return "CutScene";
            case 6: return "InGameMenu";
            case 7: return "EditorPlugin";
            case 8: return "ManiaplanetPlugin";
            case 9: return "ManiaplanetMenu";
            case 10: return "LoadingScreen";
        }
        return "?";
    }

    CGameManiaAppTitle@ _GetMenuApp() {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return null;
        try {
            auto menus = cast<CTrackManiaMenus>(app.MenuManager);
            if (menus is null) return null;
            return menus.MenuCustom_CurrentManiaApp;
        } catch { return null; }
    }

    // Scan a Manialink XML header for the root <manialink name="..."> attribute.
    // Reads only the first few hundred chars of the source to avoid allocating
    // the full multi-KB page string where possible. Returns empty if not found.
    string _ExtractManialinkName(CGameUILayer@ layer) {
        if (layer is null) return "";
        string src = "";
        try { src = layer.ManialinkPageUtf8; } catch { return ""; }
        if (src.Length == 0) return "";
        int cap = int(src.Length) < 1024 ? int(src.Length) : 1024;
        string head = src.SubStr(0, cap);
        int open = head.IndexOf("<manialink");
        if (open < 0) return "";
        // Slice past the <manialink token, then find name="..." within the tag.
        string tail = head.SubStr(open);
        int nameIx = tail.IndexOf("name=\"");
        if (nameIx < 0) return "";
        int start = nameIx + 6;
        string afterName = tail.SubStr(start);
        int end = afterName.IndexOf("\"");
        if (end < 0) return "";
        return afterName.SubStr(0, end);
    }

    Json::Value _LayerMetaJson(CGameUILayer@ layer, int index, bool includeName, bool includeXmlSize) {
        Json::Value obj = Json::Object();
        obj["index"] = index;
        if (layer is null) { obj["null"] = true; return obj; }
        int ty = -1;
        try { ty = int(layer.Type); } catch { /* ignore */ }
        obj["type"] = ty;
        obj["typeName"] = _LayerTypeName(ty);
        try { obj["isVisible"] = bool(layer.IsVisible); } catch { /* ignore */ }
        try { obj["attachId"] = string(layer.AttachId); } catch { /* ignore */ }
        try { obj["isLocalPageScriptRunning"] = bool(layer.IsLocalPageScriptRunning); } catch { /* ignore */ }
        CGameManialinkPage@ page = null;
        try { @page = layer.LocalPage; } catch { @page = null; }
        obj["hasPage"] = page !is null;
        if (page !is null) {
            try { obj["pageUrl"] = string(page.Url); } catch { /* ignore */ }
            CGameManialinkFrame@ mainFrame = null;
            try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
            obj["hasMainFrame"] = mainFrame !is null;
            if (mainFrame !is null) {
                int topLevel = 0;
                try { topLevel = int(mainFrame.Controls.Length); } catch { /* ignore */ }
                obj["topLevelChildren"] = topLevel;
            }
        }
        if (includeName) {
            obj["manialinkName"] = _ExtractManialinkName(layer);
        }
        if (includeXmlSize) {
            int sz = -1;
            try { sz = int(layer.ManialinkPageUtf8.Length); } catch { /* ignore */ }
            obj["manialinkXmlLength"] = sz;
        }
        return obj;
    }

    Json::Value@ GetUILayers(Json::Value &in input) {
        bool includeName = input.HasKey("includeName") ? bool(input["includeName"]) : true;
        bool includeXmlSize = input.HasKey("includeXmlSize") ? bool(input["includeXmlSize"]) : false;
        bool onlyVisible = input.HasKey("onlyVisible") ? bool(input["onlyVisible"]) : false;
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[i]; } catch { @layer = null; }
            if (layer is null) continue;
            if (onlyVisible) {
                bool vis = true;
                try { vis = bool(layer.IsVisible); } catch { vis = true; }
                if (!vis) continue;
            }
            arr.Add(_LayerMetaJson(layer, int(i), includeName, includeXmlSize));
        }
        output["nbLayers"] = int(nb);
        output["layers"] = arr;
        return MakeSuccess(output);
    }

    // Enumerate visible Manialink layers whose <manialink name> begins with
    // "Page_". This is the route-level counterpart to GetMenuPage's mode-level
    // answer: after SetMenuPage, the Router swaps which Page_* layer is
    // visible, so reading the visible Page_* list reports what actually
    // rendered. Caller decides how to interpret (multiple visible pages can
    // exist during transitions or for overlay pages like Page_Popup).
    // DFS from `node` looking for the first descendant whose ControlId == target.
    // Returns true when found; `outPath` is filled with the slash-joined ControlId
    // chain from (but not including) the start node down to the match. Ids used in
    // the path are each control's ControlId (anonymous controls appear as "").
    bool _FindControlPath(CGameManialinkControl@ node, const string &in target, string &out outPath) {
        if (node is null) return false;
        string selfId = "";
        try { selfId = string(node.ControlId); } catch { /* swallow */ }
        if (selfId == target) { outPath = selfId; return true; }
        auto frame = cast<CGameManialinkFrame>(node);
        if (frame is null) return false;
        uint n = 0;
        try { n = frame.Controls.Length; } catch { n = 0; }
        for (uint i = 0; i < n; i++) {
            CGameManialinkControl@ c = null;
            try { @c = frame.Controls[i]; } catch { @c = null; }
            if (c is null) continue;
            string subPath;
            if (_FindControlPath(c, target, subPath)) {
                outPath = selfId.Length > 0 ? (selfId + "/" + subPath) : subPath;
                return true;
            }
        }
        return false;
    }

    // DFS from `node` looking for the first descendant whose ControlId == target.
    // Returns true when found; `outPath` is filled with the slash-joined child-index
    // chain FROM (but not including) the start node down to the match. So for
    // MainFrame → Controls[3] (frame-global) → Controls[0] (button-create) the
    // path is "3/0". The empty string means the start node itself matched.
    bool _FindControlIndexPath(CGameManialinkControl@ node, const string &in target, string &out outPath) {
        if (node is null) return false;
        string selfId = "";
        try { selfId = string(node.ControlId); } catch { /* swallow */ }
        if (selfId == target) { outPath = ""; return true; }
        auto frame = cast<CGameManialinkFrame>(node);
        if (frame is null) return false;
        uint n = 0;
        try { n = frame.Controls.Length; } catch { n = 0; }
        for (uint i = 0; i < n; i++) {
            CGameManialinkControl@ c = null;
            try { @c = frame.Controls[i]; } catch { @c = null; }
            if (c is null) continue;
            string subPath;
            if (_FindControlIndexPath(c, target, subPath)) {
                string idx = "" + i;
                outPath = subPath.Length > 0 ? (idx + "/" + subPath) : idx;
                return true;
            }
        }
        return false;
    }

    // Walk a slash-separated child-index path from `root`. Empty segments are
    // skipped; each non-empty segment is parsed as a uint and used to index
    // `frame.Controls`. Returns null if any step fails.
    CGameManialinkControl@ _ResolveControlIndexPath(CGameManialinkFrame@ root, const string &in path) {
        if (root is null) return null;
        if (path.Length == 0) return root;
        auto segs = path.Split("/");
        CGameManialinkControl@ cur = root;
        for (uint i = 0; i < segs.Length; i++) {
            string seg = segs[i];
            if (seg.Length == 0) continue;
            auto frame = cast<CGameManialinkFrame>(cur);
            if (frame is null) return null;
            uint n = 0;
            try { n = frame.Controls.Length; } catch { n = 0; }
            uint ix = 0;
            try { ix = Text::ParseUInt(seg); } catch { return null; }
            if (ix >= n) return null;
            CGameManialinkControl@ next = null;
            try { @next = frame.Controls[ix]; } catch { @next = null; }
            if (next is null) return null;
            @cur = next;
        }
        return cur;
    }

    Json::Value _ControlSnapshotJson(CGameManialinkControl@ ctrl) {
        Json::Value o = Json::Object();
        if (ctrl is null) { o["null"] = true; return o; }
        try { o["controlId"] = string(ctrl.ControlId); } catch { /* swallow */ }
        try { o["typeName"] = string(Reflection::TypeOf(ctrl).Name); } catch { /* swallow */ }
        try { o["visible"] = bool(ctrl.Visible); } catch { /* swallow */ }
        try { o["isFocused"] = bool(ctrl.IsFocused); } catch { /* swallow */ }
        try {
            Json::Value cls = Json::Array();
            uint nc = ctrl.ControlClasses.Length;
            for (uint i = 0; i < nc; i++) cls.Add(string(ctrl.ControlClasses[i]));
            o["classes"] = cls;
        } catch { /* swallow */ }
        try {
            Json::Value pos = Json::Array();
            pos.Add(ctrl.AbsolutePosition.x);
            pos.Add(ctrl.AbsolutePosition.y);
            pos.Add(ctrl.AbsolutePosition.z);
            o["absPos"] = pos;
        } catch { /* swallow */ }
        auto frame = cast<CGameManialinkFrame>(ctrl);
        if (frame !is null) {
            try { o["isFrame"] = true; } catch { /* swallow */ }
            try { o["childCount"] = int(frame.Controls.Length); } catch { /* swallow */ }
        }
        return o;
    }

    Json::Value@ InspectMenuControl(Json::Value &in input) {
        if (!input.HasKey("controlId")) return MakeError("missing controlId");
        string controlId = string(input["controlId"]);
        string layerName = input.HasKey("layerName") ? string(input["layerName"]) : "";
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");

        CGameUILayer@ pickedLayer = null;
        int pickedIndex = -1;
        string pickedName = "";
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[i]; } catch { @layer = null; }
            if (layer is null) continue;
            bool vis = true;
            try { vis = bool(layer.IsVisible); } catch { vis = true; }
            if (!vis) continue;
            string name = _ExtractManialinkName(layer);
            if (name.Length < 5 || name.SubStr(0, 5) != "Page_") continue;
            if (layerName.Length > 0 && name != layerName) continue;
            @pickedLayer = layer;
            pickedIndex = int(i);
            pickedName = name;
            if (layerName.Length > 0) break;
        }
        if (pickedLayer is null) return MakeError("no visible Page_* layer matched (layerName='" + layerName + "')");

        CGameManialinkPage@ page = null;
        try { @page = pickedLayer.LocalPage; } catch { @page = null; }
        if (page is null) return MakeError("picked layer has no LocalPage");

        CGameManialinkControl@ direct = null;
        try { @direct = page.GetFirstChild(controlId); } catch { /* swallow */ }

        CGameManialinkFrame@ mainFrame = null;
        try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
        CGameManialinkControl@ viaFrame = null;
        if (mainFrame !is null) {
            try { @viaFrame = mainFrame.GetFirstChild(controlId); } catch { /* swallow */ }
        }

        Json::Value output = Json::Object();
        output["layerIndex"] = pickedIndex;
        output["layerName"] = pickedName;
        output["controlId"] = controlId;
        output["pageGetFirstChild"] = _ControlSnapshotJson(direct);
        output["mainFrameGetFirstChild"] = _ControlSnapshotJson(viaFrame);
        if (mainFrame !is null) {
            string idxPath;
            bool pathFound = _FindControlIndexPath(mainFrame, controlId, idxPath);
            output["pathFound"] = pathFound;
            if (pathFound) {
                output["path"] = idxPath;
                string idPath;
                if (_FindControlPath(mainFrame, controlId, idPath)) output["idPath"] = idPath;
            }
        }
        auto picked = direct !is null ? direct : viaFrame;
        if (picked !is null) {
            auto frame = cast<CGameManialinkFrame>(picked);
            if (frame !is null) {
                Json::Value kids = Json::Array();
                uint nk = 0;
                try { nk = frame.Controls.Length; } catch { nk = 0; }
                for (uint i = 0; i < nk && i < 32; i++) {
                    CGameManialinkControl@ c = null;
                    try { @c = frame.Controls[i]; } catch { @c = null; }
                    kids.Add(_ControlSnapshotJson(c));
                }
                output["children"] = kids;
            }
        }
        output["note"] = "Probe: calls page.GetFirstChild(controlId) and mainFrame.GetFirstChild(controlId). Both should return the same node if present. Child list limited to 32.";
        return MakeSuccess(output);
    }

    Json::Value@ GetActiveMenuPages(Json::Value &in input) {
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[i]; } catch { @layer = null; }
            if (layer is null) continue;
            bool vis = true;
            try { vis = bool(layer.IsVisible); } catch { vis = true; }
            if (!vis) continue;
            string name = _ExtractManialinkName(layer);
            if (name.Length < 5) continue;
            if (name.SubStr(0, 5) != "Page_") continue;
            Json::Value entry = Json::Object();
            entry["index"] = int(i);
            entry["manialinkName"] = name;
            try { entry["attachId"] = string(layer.AttachId); } catch { /* swallow */ }
            arr.Add(entry);
        }
        output["nbLayers"] = int(nb);
        output["pages"] = arr;
        output["note"] = "Visible Manialink layers named Page_*. Typically one is the active route; overlays may add more. Use SetMenuPage then poll this to verify.";
        return MakeSuccess(output);
    }

    // Resolve a slash-separated ControlId path starting from a frame. Each
    // segment walks via GetFirstChild (recursive) on the current node if it is
    // a frame. Returns null if any segment fails to match.
    CGameManialinkControl@ _ResolveControlPath(CGameManialinkFrame@ root, const string &in path) {
        if (root is null) return null;
        if (path.Length == 0) return root;
        auto segments = path.Split("/");
        CGameManialinkControl@ cur = root;
        for (uint i = 0; i < segments.Length; i++) {
            string seg = segments[i];
            if (seg.Length == 0) continue;
            auto frame = cast<CGameManialinkFrame>(cur);
            if (frame is null) return null;
            CGameManialinkControl@ next = null;
            try { @next = frame.GetFirstChild(seg); } catch { @next = null; }
            if (next is null) return null;
            @cur = next;
        }
        return cur;
    }

    Json::Value@ GetLayerTree(Json::Value &in input) {
        if (!input.HasKey("layerIndex")) return MakeError("missing layerIndex");
        int layerIndex = int(input["layerIndex"]);
        int maxDepth = input.HasKey("maxDepth") ? int(input["maxDepth"]) : 4;
        bool onlyWithId = input.HasKey("onlyWithId") ? bool(input["onlyWithId"]) : true;
        bool includeHidden = input.HasKey("includeHidden") ? bool(input["includeHidden"]) : false;
        int maxResults = input.HasKey("maxResults") ? int(input["maxResults"]) : 80;
        string rootPath = input.HasKey("rootPath") ? string(input["rootPath"]) : "";

        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available");
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        if (layerIndex < 0 || uint(layerIndex) >= nb) return MakeError("layerIndex out of range (have " + int(nb) + " layers)");
        CGameUILayer@ layer = null;
        try { @layer = menuApp.UILayers[uint(layerIndex)]; } catch { return MakeError("could not read layer"); }
        if (layer is null) return MakeError("layer is null");
        CGameManialinkPage@ page = null;
        try { @page = layer.LocalPage; } catch { @page = null; }
        if (page is null) return MakeError("layer has no LocalPage");
        CGameManialinkFrame@ mainFrame = null;
        try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
        if (mainFrame is null) return MakeError("layer page has no MainFrame");

        CGameManialinkControl@ startCtrl = _ResolveControlPath(mainFrame, rootPath);
        if (startCtrl is null) return MakeError("rootPath did not resolve");

        Json::Value output = Json::Object();
        output["layerIndex"] = layerIndex;
        output["rootPath"] = rootPath;
        Json::Value controls = Json::Array();
        string startLabel = rootPath.Length > 0 ? rootPath : "<root>";
        _WalkControl(startCtrl, startLabel, 0, maxDepth, onlyWithId, includeHidden, controls);
        if (int(controls.Length) > maxResults) {
            Json::Value trimmed = Json::Array();
            for (int ci = 0; ci < maxResults; ci++) trimmed.Add(controls[ci]);
            output["controls"] = trimmed;
            output["trimmedAt"] = maxResults;
        } else {
            output["controls"] = controls;
        }
        return MakeSuccess(output);
    }

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

    // Resolve a control by either `controlId` (global search) or
    // `{layerIndex, indexPath}`/`{layerName, indexPath}` (direct walk). Returns
    // null on failure; err is set with a human-readable reason when non-null.
    CGameManialinkControl@ _ResolveControlFromInput(Json::Value &in input, string &out err) {
        err = "";
        if (input.HasKey("controlId")) {
            string cid = string(input["controlId"]);
            auto ctrl = _FindControlById(cid);
            if (ctrl is null) { err = "control not found: " + cid; return null; }
            return ctrl;
        }
        if (!input.HasKey("indexPath")) {
            err = "missing controlId or indexPath";
            return null;
        }
        string ipath = string(input["indexPath"]);
        auto menuApp = _GetMenuApp();
        if (menuApp is null) { err = "menu mania app not available"; return null; }
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }

        CGameUILayer@ picked = null;
        if (input.HasKey("layerIndex")) {
            int li = int(input["layerIndex"]);
            if (li < 0 || uint(li) >= nb) { err = "layerIndex out of range"; return null; }
            try { @picked = menuApp.UILayers[uint(li)]; } catch { @picked = null; }
        } else if (input.HasKey("layerName")) {
            string want = string(input["layerName"]);
            for (uint i = 0; i < nb; i++) {
                CGameUILayer@ layer = null;
                try { @layer = menuApp.UILayers[i]; } catch { @layer = null; }
                if (layer is null) continue;
                if (_ExtractManialinkName(layer) == want) { @picked = layer; break; }
            }
        } else {
            err = "indexPath needs layerIndex or layerName";
            return null;
        }
        if (picked is null) { err = "layer not found"; return null; }
        CGameManialinkPage@ page = null;
        try { @page = picked.LocalPage; } catch { @page = null; }
        if (page is null) { err = "layer has no LocalPage"; return null; }
        CGameManialinkFrame@ mainFrame = null;
        try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
        if (mainFrame is null) { err = "layer page has no MainFrame"; return null; }
        auto ctrl = _ResolveControlIndexPath(mainFrame, ipath);
        if (ctrl is null) { err = "indexPath did not resolve"; return null; }
        return ctrl;
    }

    // DFS for the first descendant with class `component-navigation-item-zone`.
    // That class marks the click-hitbox quad inside any Nadeo nav-item button
    // (expendable-button, Trackmania_Button, etc. — both templates end at a
    // quad with this class). Returns root itself if it carries the class.
    CGameManialinkControl@ _FindNavZoneInSubtree(CGameManialinkControl@ root, int maxDepth) {
        if (root is null || maxDepth < 0) return null;
        if (_ControlHasClass(root, "component-navigation-item-zone")) return root;
        auto frame = cast<CGameManialinkFrame>(root);
        if (frame is null) return null;
        uint n = 0;
        try { n = frame.Controls.Length; } catch { n = 0; }
        for (uint i = 0; i < n; i++) {
            CGameManialinkControl@ c = null;
            try { @c = frame.Controls[i]; } catch { @c = null; }
            if (c is null) continue;
            auto hit = _FindNavZoneInSubtree(c, maxDepth - 1);
            if (hit !is null) return hit;
        }
        return null;
    }

    // High-level click: resolve a nav-item by {controlId} (global search) or
    // {indexPath, layerIndex|layerName}, descend to its
    // component-navigation-item-zone leaf, then OnAction() its CControlBase.
    // This is what a real mouse click does. If the resolved control already
    // has the nav-zone class it is used directly (so callers may pass the
    // leaf indexPath too).
    Json::Value@ ClickMenuButton(Json::Value &in input) {
        string err;
        auto navItem = _ResolveControlFromInput(input, err);
        if (navItem is null) return MakeError(err);
        auto zone = _FindNavZoneInSubtree(navItem, 10);
        if (zone is null) {
            string navId = "?";
            try { navId = string(navItem.ControlId); } catch { /* swallow */ }
            return MakeError("no component-navigation-item-zone descendant under '" + navId + "'; for non-nav buttons use TriggerControlOnAction directly");
        }
        CControlBase@ base = null;
        try { @base = zone.Control; } catch { return MakeError("reading .Control threw: " + getExceptionInfo()); }
        if (base is null) return MakeError("zone.Control is null");
        string baseTy = "?";
        try { baseTy = Reflection::TypeOf(base).Name; } catch { /* swallow */ }
        try { base.OnAction(); } catch { return MakeError("OnAction() threw: " + getExceptionInfo()); }
        Json::Value output = Json::Object();
        try { output["navItemControlId"] = string(navItem.ControlId); } catch { /* swallow */ }
        try { output["navItemType"] = Reflection::TypeOf(navItem).Name; } catch { /* swallow */ }
        try { output["zoneControlId"] = string(zone.ControlId); } catch { /* swallow */ }
        try { output["zoneType"] = Reflection::TypeOf(zone).Name; } catch { /* swallow */ }
        output["zoneControlBaseType"] = baseTy;
        output["note"] = "Fired CControlBase::OnAction() on the nav-zone leaf. Observe via GetActiveMenuPages / GetMode / GetDialog.";
        return MakeSuccess(output);
    }

    // Invoke CControlBase::OnAction() on the resolved control. OnAction is
    // the low-level click-dispatch that the UI itself calls when a button is
    // activated — living on CControlBase (Openplanet.h:13548) without the
    // // Maniascript marker, so it is safe to call from Angelscript (unlike
    // CGameManialinkScriptHandler::TriggerPageAction which native-crashes).
    //
    // For Nadeo expendable-button nav-items (e.g. 'button-create' on
    // Page_HomePage), the control that actually owns the click is the leaf
    // CMGame_ExpendableButton_quad-nav-zone at Controls[0]/[4]/[0] under the
    // nav-item frame. Caller decides which control to target via
    // controlId or indexPath.
    Json::Value@ TriggerControlOnAction(Json::Value &in input) {
        string err;
        auto ctrl = _ResolveControlFromInput(input, err);
        if (ctrl is null) return MakeError(err);
        CControlBase@ base = null;
        try { @base = ctrl.Control; } catch { return MakeError("reading .Control threw: " + getExceptionInfo()); }
        if (base is null) return MakeError("control.Control is null");
        string baseTy = "?";
        try { baseTy = Reflection::TypeOf(base).Name; } catch { /* swallow */ }
        try { base.OnAction(); } catch { return MakeError("OnAction() threw: " + getExceptionInfo()); }
        Json::Value output = Json::Object();
        try { output["controlId"] = string(ctrl.ControlId); } catch { /* swallow */ }
        try { output["type"] = Reflection::TypeOf(ctrl).Name; } catch { /* swallow */ }
        output["controlBaseType"] = baseTy;
        output["note"] = "Called CControlBase::OnAction(). This is the game's own click-dispatch path; it does not need Maniascript runtime.";
        return MakeSuccess(output);
    }

    Json::Value@ SetMenuControlVisible(Json::Value &in input) {
        if (!input.HasKey("visible")) return MakeError("missing visible (bool)");
        bool visible = bool(input["visible"]);
        string err;
        auto ctrl = _ResolveControlFromInput(input, err);
        if (ctrl is null) return MakeError(err);
        if (visible) {
            try { ctrl.Show(); } catch { return MakeError("Show() threw: " + getExceptionInfo()); }
        } else {
            try { ctrl.Hide(); } catch { return MakeError("Hide() threw: " + getExceptionInfo()); }
        }
        Json::Value output = Json::Object();
        try { output["controlId"] = string(ctrl.ControlId); } catch { /* swallow */ }
        try { output["type"] = Reflection::TypeOf(ctrl).Name; } catch { /* swallow */ }
        try { output["visible"] = bool(ctrl.Visible); } catch { /* swallow */ }
        output["requested"] = visible;
        output["note"] = "Calls Show()/Hide(). Note: game often re-renders the menu and may reset visibility on the next tick. Observe via GetUILayers or InspectMenuControl.";
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

        try {
            Json::Value pos = Json::Array();
            pos.Add(float(ctrl.AbsolutePosition.x));
            pos.Add(float(ctrl.AbsolutePosition.y));
            pos.Add(float(ctrl.AbsolutePosition.z));
            obj["absPos"] = pos;
        } catch { /* ignore */ }
        try {
            Json::Value size = Json::Array();
            size.Add(float(ctrl.Size.x));
            size.Add(float(ctrl.Size.y));
            obj["size"] = size;
        } catch { /* ignore */ }

        // Common click-action data-attribute names on Nadeo menus
        string[] dataKeys = { "action", "route", "context", "target", "handler", "event" };
        Json::Value data = Json::Object();
        for (uint di = 0; di < dataKeys.Length; di++) {
            try {
                if (ctrl.DataAttributeExists(dataKeys[di])) {
                    data[dataKeys[di]] = string(ctrl.DataAttributeGet(dataKeys[di]));
                }
            } catch { /* ignore */ }
        }
        if (data.GetKeys().Length > 0) obj["data"] = data;

        try {
            auto lbl = cast<CGameManialinkLabel>(ctrl);
            if (lbl !is null) {
                auto ty = Reflection::TypeOf(lbl);
                if (ty !is null) {
                    auto m = ty.GetMember("Value");
                    if (m !is null && m.Offset < 0xFFFF) {
                        obj["labelValue"] = Dev::GetOffsetString(lbl, m.Offset);
                    }
                }
            }
        } catch { /* ignore */ }

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

    // Exact-match class test.
    bool _ControlHasClass(CGameManialinkControl@ ctrl, const string &in className) {
        if (ctrl is null) return false;
        try {
            uint nb = ctrl.ControlClasses.Length;
            for (uint i = 0; i < nb; i++) {
                if (string(ctrl.ControlClasses[i]) == className) return true;
            }
        } catch { /* swallow */ }
        return false;
    }

    bool _ControlClassMatches(CGameManialinkControl@ ctrl, const string &in needle, bool substring) {
        if (ctrl is null) return false;
        try {
            uint nb = ctrl.ControlClasses.Length;
            for (uint i = 0; i < nb; i++) {
                string cls = string(ctrl.ControlClasses[i]);
                if (substring) {
                    if (cls.Contains(needle)) return true;
                } else {
                    if (cls == needle) return true;
                }
            }
        } catch { /* swallow */ }
        return false;
    }

    string _ReadLabelValue(CGameManialinkControl@ ctrl) {
        if (ctrl is null) return "";
        auto lbl = cast<CGameManialinkLabel>(ctrl);
        if (lbl is null) return "";
        try {
            auto ty = Reflection::TypeOf(lbl);
            if (ty is null) return "";
            auto m = ty.GetMember("Value");
            if (m is null || m.Offset >= 0xFFFF) return "";
            return Dev::GetOffsetString(lbl, m.Offset);
        } catch { /* swallow */ }
        return "";
    }

    // Depth-first search for the first non-empty Label descendant text.
    // Used to pull the visible text out of a nav button's frame subtree.
    string _FindFirstLabelValue(CGameManialinkControl@ root, int maxDepth) {
        if (root is null || maxDepth < 0) return "";
        string v = _ReadLabelValue(root);
        if (v.Length > 0) return v;
        auto frame = cast<CGameManialinkFrame>(root);
        if (frame is null) return "";
        uint nb = 0;
        try { nb = frame.Controls.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameManialinkControl@ child = null;
            try { @child = frame.Controls[i]; } catch { @child = null; }
            if (child is null) continue;
            string childVal = _FindFirstLabelValue(child, maxDepth - 1);
            if (childVal.Length > 0) return childVal;
        }
        return "";
    }

    // Nadeo menu labels are translation keys that use two control markers:
    // U+0091 (fallback delimiter) and U+0092 (translation-key marker). In
    // UTF-8 these encode as the 2-byte sequences C2 91 and C2 92. Observed:
    //     \u0092|Prefix|Text                       (marker + keyed lookup)
    //     \u0091<fallback>\u0091\u0092|Prefix|Text (fallback + keyed lookup)
    //     \u0092<plain text>                       (marker + direct text, no key)
    //     |Prefix|Text                             (rare, no marker)
    //     Plain text                               (no translation at all)
    // Strip to just the trailing Text segment.
    string _StripTranslationPrefix(const string &in raw) {
        if (raw.Length == 0) return raw;
        string s = raw;
        string U91 = "\xC2\x91";
        string U92 = "\xC2\x92";
        // Drop \u0091<fallback>\u0091 prefix.
        if (s.Length >= 2 && s.SubStr(0, 2) == U91) {
            string rest = s.SubStr(2);
            int closeFall = rest.IndexOf(U91);
            if (closeFall >= 0) s = rest.SubStr(uint(closeFall) + 2);
        }
        // Drop leading \u0092 marker.
        if (s.Length >= 2 && s.SubStr(0, 2) == U92) s = s.SubStr(2);
        // If a |Key|Text structure remains, return Text.
        if (s.Length > 0 && s.SubStr(0, 1) == "|") {
            string rest = s.SubStr(1);
            int close = rest.IndexOf("|");
            if (close >= 0) return rest.SubStr(uint(close) + 1);
        }
        return s;
    }

    class _Counter { int n = 0; }

    void _CollectMatchingByClass(CGameManialinkControl@ ctrl, const string &in path, int depth, int maxDepth, bool onlyVisible, const string &in classNeedle, bool classSubstring, Json::Value &inout results, _Counter@ matchCount, int maxResults) {
        if (ctrl is null) return;
        if (depth > maxDepth) return;
        if (matchCount.n >= maxResults) return;

        bool visible = true;
        try { visible = bool(ctrl.Visible); } catch { visible = true; }
        if (onlyVisible && !visible) return;

        if (_ControlClassMatches(ctrl, classNeedle, classSubstring)) {
            Json::Value entry = _ControlToJson(ctrl, path);
            string rawLabel = _FindFirstLabelValue(ctrl, 6);
            if (rawLabel.Length > 0) {
                entry["label"] = rawLabel;
                string txt = _StripTranslationPrefix(rawLabel);
                if (txt != rawLabel) entry["displayText"] = txt;
            }
            results.Add(entry);
            matchCount.n++;
            if (matchCount.n >= maxResults) return;
        }

        auto frame = cast<CGameManialinkFrame>(ctrl);
        if (frame is null) return;
        uint nb = 0;
        try { nb = frame.Controls.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameManialinkControl@ child = null;
            try { @child = frame.Controls[i]; } catch { @child = null; }
            if (child is null) continue;
            string childId = "";
            try { childId = string(child.ControlId); } catch { childId = ""; }
            string childPath = path + "/" + (childId.Length > 0 ? childId : ("#" + i));
            _CollectMatchingByClass(child, childPath, depth + 1, maxDepth, onlyVisible, classNeedle, classSubstring, results, matchCount, maxResults);
        }
    }

    Json::Value@ _FindControlsAcrossLayers(const string &in classNeedle, bool classSubstring, bool onlyVisibleLayers, bool onlyVisibleControls, int maxDepth, int maxResults) {
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        _Counter@ matchCount = _Counter();
        for (uint li = 0; li < nb; li++) {
            if (matchCount.n >= maxResults) break;
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[li]; } catch { @layer = null; }
            if (layer is null) continue;
            if (onlyVisibleLayers) {
                bool vis = true;
                try { vis = bool(layer.IsVisible); } catch { vis = true; }
                if (!vis) continue;
            }
            CGameManialinkPage@ page = null;
            try { @page = layer.LocalPage; } catch { @page = null; }
            if (page is null) continue;
            CGameManialinkFrame@ mainFrame = null;
            try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
            if (mainFrame is null) continue;

            string layerName = _ExtractManialinkName(layer);
            Json::Value layerResults = Json::Array();
            _CollectMatchingByClass(mainFrame, "L" + li, 0, maxDepth, onlyVisibleControls, classNeedle, classSubstring, layerResults, matchCount, maxResults);
            for (uint k = 0; k < layerResults.Length; k++) {
                Json::Value entry = layerResults[k];
                entry["layerIndex"] = int(li);
                if (layerName.Length > 0) entry["layerName"] = layerName;
                arr.Add(entry);
            }
        }
        output["matches"] = arr;
        output["count"] = int(arr.Length);
        if (matchCount.n >= maxResults) output["truncated"] = true;
        return MakeSuccess(output);
    }

    // Grep/slice a layer's Manialink XML without dumping the whole multi-KB string.
    // Inputs: layerIndex, plus either (find + context) for substring search OR
    // (offset + length) for a raw slice. Returns hits with byte offsets.
    Json::Value@ GetLayerXml(Json::Value &in input) {
        if (!input.HasKey("layerIndex")) return MakeError("missing layerIndex");
        int layerIndex = int(input["layerIndex"]);
        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available");
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        if (layerIndex < 0 || uint(layerIndex) >= nb) return MakeError("layerIndex out of range");
        CGameUILayer@ layer = null;
        try { @layer = menuApp.UILayers[uint(layerIndex)]; } catch { return MakeError("could not read layer"); }
        if (layer is null) return MakeError("layer is null");
        string src = "";
        try { src = layer.ManialinkPageUtf8; } catch { return MakeError("ManialinkPageUtf8 threw"); }

        Json::Value output = Json::Object();
        output["layerIndex"] = layerIndex;
        output["xmlLength"] = int(src.Length);

        if (input.HasKey("find")) {
            string needle = string(input["find"]);
            int ctx = input.HasKey("context") ? int(input["context"]) : 120;
            int maxHits = input.HasKey("maxHits") ? int(input["maxHits"]) : 20;
            bool caseInsensitive = input.HasKey("caseInsensitive") ? bool(input["caseInsensitive"]) : false;
            Json::Value hits = Json::Array();
            string hay = caseInsensitive ? src.ToLower() : src;
            string need = caseInsensitive ? needle.ToLower() : needle;
            int pos = 0;
            int count = 0;
            while (count < maxHits) {
                string tail = hay.SubStr(uint(pos));
                int rel = tail.IndexOf(need);
                if (rel < 0) break;
                int abs = pos + rel;
                int start = abs - ctx; if (start < 0) start = 0;
                int endRaw = abs + int(needle.Length) + ctx;
                if (endRaw > int(src.Length)) endRaw = int(src.Length);
                Json::Value h = Json::Object();
                h["offset"] = abs;
                h["snippet"] = src.SubStr(uint(start), uint(endRaw - start));
                hits.Add(h);
                pos = abs + int(needle.Length);
                count++;
            }
            output["find"] = needle;
            output["hits"] = hits;
            output["count"] = int(hits.Length);
            return MakeSuccess(output);
        }

        int offset = input.HasKey("offset") ? int(input["offset"]) : 0;
        int length = input.HasKey("length") ? int(input["length"]) : 2048;
        if (offset < 0) offset = 0;
        if (offset > int(src.Length)) offset = int(src.Length);
        int endRaw = offset + length;
        if (endRaw > int(src.Length)) endRaw = int(src.Length);
        output["offset"] = offset;
        output["slice"] = src.SubStr(uint(offset), uint(endRaw - offset));
        return MakeSuccess(output);
    }

    Json::Value@ FindMenuButtons(Json::Value &in input) {
        bool onlyVisible = input.HasKey("onlyVisible") ? bool(input["onlyVisible"]) : true;
        int maxDepth = input.HasKey("maxDepth") ? int(input["maxDepth"]) : 10;
        int maxResults = input.HasKey("maxResults") ? int(input["maxResults"]) : 100;
        string classNeedle = input.HasKey("className") ? string(input["className"]) : "component-navigation-item";
        return _FindControlsAcrossLayers(classNeedle, false, onlyVisible, onlyVisible, maxDepth, maxResults);
    }

    Json::Value@ FindControlsByClass(Json::Value &in input) {
        if (!input.HasKey("classPattern")) return MakeError("missing classPattern");
        string pattern = string(input["classPattern"]);
        bool substring = input.HasKey("substring") ? bool(input["substring"]) : true;
        bool onlyVisible = input.HasKey("onlyVisible") ? bool(input["onlyVisible"]) : true;
        int maxDepth = input.HasKey("maxDepth") ? int(input["maxDepth"]) : 10;
        int maxResults = input.HasKey("maxResults") ? int(input["maxResults"]) : 100;
        return _FindControlsAcrossLayers(pattern, substring, onlyVisible, onlyVisible, maxDepth, maxResults);
    }

    void _WalkForLabel(CGameManialinkControl@ ctrl, const string &in path, int depth, int maxDepth, bool onlyVisible, const string &in needleCmp, bool caseInsensitive, Json::Value &inout results, _Counter@ matchCount, int maxResults, int layerIndex, const string &in layerName) {
        if (ctrl is null) return;
        if (depth > maxDepth) return;
        if (matchCount.n >= maxResults) return;
        bool visible = true;
        try { visible = bool(ctrl.Visible); } catch { visible = true; }
        if (onlyVisible && !visible) return;

        string val = _ReadLabelValue(ctrl);
        if (val.Length > 0) {
            string cmp = caseInsensitive ? val.ToLower() : val;
            if (cmp.Contains(needleCmp)) {
                Json::Value entry = _ControlToJson(ctrl, path);
                entry["label"] = val;
                string stripped = _StripTranslationPrefix(val);
                if (stripped != val) entry["displayText"] = stripped;
                entry["layerIndex"] = layerIndex;
                if (layerName.Length > 0) entry["layerName"] = layerName;
                results.Add(entry);
                matchCount.n++;
                if (matchCount.n >= maxResults) return;
            }
        }

        auto frame = cast<CGameManialinkFrame>(ctrl);
        if (frame is null) return;
        uint nb = 0;
        try { nb = frame.Controls.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameManialinkControl@ child = null;
            try { @child = frame.Controls[i]; } catch { @child = null; }
            if (child is null) continue;
            string childId = "";
            try { childId = string(child.ControlId); } catch { childId = ""; }
            string childPath = path + "/" + (childId.Length > 0 ? childId : ("#" + i));
            _WalkForLabel(child, childPath, depth + 1, maxDepth, onlyVisible, needleCmp, caseInsensitive, results, matchCount, maxResults, layerIndex, layerName);
        }
    }

    Json::Value@ FindControlsByLabel(Json::Value &in input) {
        if (!input.HasKey("substring")) return MakeError("missing substring");
        string needle = string(input["substring"]);
        bool caseInsensitive = input.HasKey("caseInsensitive") ? bool(input["caseInsensitive"]) : true;
        bool onlyVisible = input.HasKey("onlyVisible") ? bool(input["onlyVisible"]) : true;
        int maxDepth = input.HasKey("maxDepth") ? int(input["maxDepth"]) : 12;
        int maxResults = input.HasKey("maxResults") ? int(input["maxResults"]) : 100;
        string needleCmp = caseInsensitive ? needle.ToLower() : needle;

        auto menuApp = _GetMenuApp();
        if (menuApp is null) return MakeError("menu mania app not available (not in menu?)");
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        uint nb = 0;
        try { nb = menuApp.UILayers.Length; } catch { nb = 0; }
        _Counter@ matchCount = _Counter();
        for (uint li = 0; li < nb; li++) {
            if (matchCount.n >= maxResults) break;
            CGameUILayer@ layer = null;
            try { @layer = menuApp.UILayers[li]; } catch { @layer = null; }
            if (layer is null) continue;
            if (onlyVisible) {
                bool vis = true;
                try { vis = bool(layer.IsVisible); } catch { vis = true; }
                if (!vis) continue;
            }
            CGameManialinkPage@ page = null;
            try { @page = layer.LocalPage; } catch { @page = null; }
            if (page is null) continue;
            CGameManialinkFrame@ mainFrame = null;
            try { @mainFrame = page.MainFrame; } catch { @mainFrame = null; }
            if (mainFrame is null) continue;

            string layerName = _ExtractManialinkName(layer);
            _WalkForLabel(mainFrame, "L" + li, 0, maxDepth, onlyVisible, needleCmp, caseInsensitive, arr, matchCount, maxResults, int(li), layerName);
        }
        output["matches"] = arr;
        output["count"] = int(arr.Length);
        if (matchCount.n >= maxResults) output["truncated"] = true;
        return MakeSuccess(output);
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
