namespace TmMcp {
    // Act on and wait for ManiaLink UI in any context (menu, map, editor),
    // addressed the same way ViewManialinkPage prints it: a page ref or name
    // plus a ControlId. ClickMenuButton/GetActiveMenuPages are menu-only.

    // Manialink names by layer, so a WaitUntil polling by name does not copy
    // every page's XML each poll. A layer's page can be replaced, so entries
    // are refreshed when its XML length changes.
    class _MlNameCacheEntry {
        CGameUILayer@ layer;
        int xmlLength;
        string name;
    }
    array<_MlNameCacheEntry@> g_MlNameCache;

    string _MlCachedName(MlPageRef@ r) {
        int len = -1;
        try { len = int(r.layer.ManialinkPageUtf8.Length); } catch { len = -1; }
        for (uint i = 0; i < g_MlNameCache.Length; i++) {
            auto e = g_MlNameCache[i];
            if (e.layer !is r.layer) continue;
            if (e.xmlLength != len) { e.xmlLength = len; e.name = r.Name(); }
            return e.name;
        }
        if (g_MlNameCache.Length >= 512) g_MlNameCache.RemoveRange(0, 256);
        auto e = _MlNameCacheEntry();
        @e.layer = r.layer;
        e.xmlLength = len;
        e.name = r.Name();
        g_MlNameCache.InsertLast(e);
        return e.name;
    }

    // First page matching selector (ref or exact name), or null.
    MlPageRef@ FindManialinkPage(const string &in selector) {
        if (selector.Length == 0) return null;
        auto pages = CollectManialinkPages();
        bool byRef = MlSelectorIsRef(selector);
        for (uint i = 0; i < pages.Length; i++) {
            if (MlPageMatches(selector, pages[i].ref, byRef ? "" : MlLower(_MlCachedName(pages[i])))) return pages[i];
        }
        return null;
    }

    // Shown on screen: the control and every ancestor up to the root frame
    // are Visible, and the layer is drawn.
    bool ManialinkControlDrawn(MlPageRef@ page, CGameManialinkControl@ ctrl) {
        if (!_MlLayerVisible(page.layer)) return false;
        CGameManialinkControl@ cur = ctrl;
        for (uint guard = 0; cur !is null && guard < 128; guard++) {
            try {
                if (!cur.Visible) return false;
                @cur = cur.Parent;
            } catch { return false; }
        }
        return true;
    }

    // Text a control shows: a label's value, else its first label
    // descendant's (buttons), translation prefix and $ codes stripped.
    string ManialinkControlText(CGameManialinkControl@ ctrl) {
        string raw = _ReadLabelValue(ctrl);
        if (raw.Length == 0) raw = _FindFirstLabelValue(ctrl, 8);
        return Text::StripFormatCodes(_StripTranslationPrefix(raw));
    }

    Json::Value@ _MlPageNotFound(const string &in selector) {
        return MakeError("no page matches '" + selector + "'; call ListManialinkPages for refs and names", "NOT_FOUND");
    }

    // Click what a player would click: the *-navigation-item-zone hitbox under
    // a Nadeo button, else the control itself. Fires CControlBase::OnAction,
    // which runs the page script's click handling.
    Json::Value@ ClickManialinkControl(Json::Value &in input) {
        string selector = input.HasKey("page") ? string(input["page"]) : "";
        string controlId = input.HasKey("id") ? string(input["id"]) : "";
        if (selector.Length == 0 || controlId.Length == 0) return MakeError("page and id are required", "BAD_INPUT");
        bool allowHidden = bool(input.Get("allowHidden", false));
        auto page = FindManialinkPage(selector);
        if (page is null) return _MlPageNotFound(selector);
        int index = int(input.Get("index", 0));
        if (index < 0) return MakeError("index must be >= 0", "BAD_INPUT");
        bool full = bool(input.Get("full", false));
        // index counts the lines ViewManialinkPage {page, full, includeHidden:
        // allowHidden} prints with this id, in print order.
        auto matches = ManialinkPrintedControls(page, controlId, full, allowHidden);
        if (matches.Length == 0) {
            bool anyHidden = !allowHidden && ManialinkPrintedControls(page, controlId, true, true).Length > 0;
            if (anyHidden) return MakeError("'" + controlId + "' on " + page.ref + " is not drawn (it or an ancestor is hidden,"
                                            + " or the page is not shown); a player could not click it. allowHidden:true clicks anyway", "NOT_DRAWN");
            return MakeError("no control '" + controlId + "' on " + page.ref + " " + page.Name()
                             + (full ? "" : " in the brief view (full:true counts every control)") + "; ViewManialinkPage {page} lists ids", "NOT_FOUND");
        }
        if (uint(index) >= matches.Length) return MakeError("ViewManialinkPage prints '" + controlId + "' " + matches.Length + " time(s) on " + page.ref
                                                            + "; index is 0.." + (matches.Length - 1), "NOT_FOUND");
        auto ctrl = matches[uint(index)].ctrl;
        bool drawn = ManialinkControlDrawn(page, ctrl);
        if (!drawn && !allowHidden) return MakeError("'" + controlId + "' on " + page.ref + " is not drawn; allowHidden:true clicks anyway", "NOT_DRAWN");
        auto target = _FindNavZoneInSubtree(ctrl, 10);
        if (target is null) @target = ctrl;
        CControlBase@ base = null;
        try { @base = target.Control; } catch { @base = null; }
        if (base is null) return MakeError("'" + controlId + "' has no engine control to click", "NOT_CLICKABLE");
        try { base.OnAction(); } catch { return MakeError("OnAction failed: " + getExceptionInfo(), "CLICK_FAILED"); }
        auto output = Json::Object();
        output["page"] = page.ref;
        output["name"] = page.Name();
        output["id"] = controlId;
        output["index"] = index;
        output["matches"] = int(matches.Length);
        string targetId;
        try { targetId = target.ControlId; } catch { targetId = ""; }
        output["clicked"] = target is ctrl ? "control" : "navigation zone";
        if (target !is ctrl && targetId.Length > 0) output["zoneId"] = targetId;
        string text = ManialinkControlText(ctrl);
        if (text.Length > 0) output["text"] = text;
        output["drawn"] = drawn;
        output["note"] = "Clicks are handled by the page script on later frames: confirm with WaitUntil {condition:manialink, ...} or ViewManialinkPage.";
        return MakeSuccess(output);
    }

    // WaitUntil {condition:manialink, page, id?, index?, full?, text?, state?}.
    // state is "shown" (default) or "gone". text is a case-insensitive
    // substring of the control's text (needs id). "gone" is also true when the
    // page is not found at all, which a mistyped selector would cause: the
    // wait reports pageFound and pageEverFound so that is visible.
    bool ManialinkConditionMet(Json::Value &in input, Json::Value@ last) {
        string selector = input.HasKey("page") ? string(input["page"]) : "";
        string controlId = input.HasKey("id") ? string(input["id"]) : "";
        string wantText = input.HasKey("text") ? string(input["text"]) : "";
        string state = input.HasKey("state") ? string(input["state"]).ToLower() : "shown";
        last["page"] = selector;
        last["state"] = state;
        bool shown = false;
        auto page = FindManialinkPage(selector);
        last["pageFound"] = page !is null;
        if (page !is null) {
            last["ref"] = page.ref;
            if (controlId.Length == 0) {
                shown = _MlLayerVisible(page.layer);
            } else {
                last["id"] = controlId;
                // index counts what ViewManialinkPage {page, full} prints, as
                // ClickManialinkControl does; only drawn lines count here.
                uint index = uint(Math::Max(0, int(input.Get("index", 0))));
                auto matches = ManialinkPrintedControls(page, controlId, bool(input.Get("full", false)), false);
                last["matches"] = int(matches.Length);
                CGameManialinkControl@ ctrl = index < matches.Length ? matches[index].ctrl : null;
                shown = ctrl !is null && ManialinkControlDrawn(page, ctrl);
                if (shown && wantText.Length > 0) {
                    string text = ManialinkControlText(ctrl);
                    last["text"] = text;
                    shown = MlTextContains(text, wantText);
                }
            }
        }
        last["shown"] = shown;
        return state == "gone" ? !shown : shown;
    }
}
