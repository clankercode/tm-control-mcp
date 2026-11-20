namespace TmMcp {
    // ListManialinkPages + ViewManialinkPage: the ManiaLink UI that is on
    // screen now, as a concise indented tree. Covers the menu app, the
    // playground client app and its UI configs, and the map editor's plugin
    // app, unlike GetUILayers/GetLayerTree which read only the menu. Read-only.
    // Pure formatting lives in ManialinkViewPolicy.as.

    const uint ML_VIEW_MAX_LINES_DEFAULT = 400;
    const uint ML_VIEW_MAX_LINES_CAP = 4000;
    const uint ML_VIEW_MAX_DEPTH_DEFAULT = 24;

    class MlPageRef {
        string ref;          // "<source>:<index>", stable while the layer list is unchanged
        string source;       // menu | playground | ui | clientUi | uiConfig<N> | editor
        CGameUILayer@ layer;
        bool nameRead = false;
        string name;         // <manialink name>, read lazily (copies the page XML)

        string Name() {
            if (!nameRead) { name = _ExtractManialinkName(layer); nameRead = true; }
            return name;
        }
    }

    void _MlAddLayer(array<MlPageRef@>@ pages, const string &in source, uint index, CGameUILayer@ layer) {
        if (layer is null) return;
        auto r = MlPageRef();
        r.ref = source + ":" + index;
        r.source = source;
        @r.layer = layer;
        pages.InsertLast(r);
    }

    // MwFastBuffer is a value type: index it through its owner, never by handle
    // or copy (a copy would alias, then destruct, game memory).
    void _MlAddLayers(array<MlPageRef@>@ pages, const string &in source, CGameManiaApp@ owner) {
        if (owner is null) return;
        for (uint i = 0; i < owner.UILayers.Length; i++) _MlAddLayer(pages, source, i, owner.UILayers[i]);
    }

    void _MlAddLayers(array<MlPageRef@>@ pages, const string &in source, CGamePlaygroundUIConfig@ owner) {
        if (owner is null) return;
        for (uint i = 0; i < owner.UILayers.Length; i++) _MlAddLayer(pages, source, i, owner.UILayers[i]);
    }

    void _MlAppend(array<MlPageRef@>@ into, array<MlPageRef@>@ from) {
        for (uint i = 0; i < from.Length; i++) {
            bool seen = false;
            for (uint k = 0; k < into.Length && !seen; k++) seen = into[k].layer is from[i].layer;
            if (!seen) into.InsertLast(from[i]);
        }
    }

    // Every UI layer the game currently owns. The current context's sources
    // come first (menu layers stay IsVisible under a map or the editor), and a
    // layer listed by several sources keeps its first ref.
    array<MlPageRef@>@ CollectManialinkPages() {
        array<MlPageRef@> menuPages, playPages, editorPages, unique;
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return unique;
        try { _MlAddLayers(menuPages, "menu", _GetMenuApp()); } catch { /* menu app unavailable */ }
        try {
            auto net = app.Network;
            if (net !is null && net.ClientManiaAppPlayground !is null) {
                auto pg = net.ClientManiaAppPlayground;
                _MlAddLayers(playPages, "playground", pg);
                _MlAddLayers(playPages, "ui", pg.UI);
                _MlAddLayers(playPages, "clientUi", pg.ClientUI);
            }
        } catch { /* playground app unavailable */ }
        try {
            auto playground = app.CurrentPlayground;
            if (playground !is null) {
                for (uint i = 0; i < playground.UIConfigs.Length; i++)
                    _MlAddLayers(playPages, "uiConfig" + i, playground.UIConfigs[i]);
            }
        } catch { /* playground UI configs unavailable */ }
        try {
            auto editor = cast<CGameCtnEditorFree>(app.Editor);
            if (editor !is null) _MlAddLayers(editorPages, "editor", editor.PluginMapType);
        } catch { /* editor app unavailable */ }
        string context = DetectCurrentMlContext();
        if (context == "in-map") { _MlAppend(unique, playPages); _MlAppend(unique, editorPages); _MlAppend(unique, menuPages); }
        else if (context == "in-editor") { _MlAppend(unique, editorPages); _MlAppend(unique, playPages); _MlAppend(unique, menuPages); }
        else { _MlAppend(unique, menuPages); _MlAppend(unique, playPages); _MlAppend(unique, editorPages); }
        return unique;
    }

    // Drawn: the layer is visible AND its page's root frame is. Menu layers
    // keep IsVisible under a map; the menu hides their MainFrame instead.
    bool _MlLayerVisible(CGameUILayer@ layer) {
        try {
            if (!layer.IsVisible) return false;
            auto page = layer.LocalPage;
            if (page is null || page.MainFrame is null) return true;
            return page.MainFrame.Visible;
        } catch { return false; }
    }

    string _MlLayerType(CGameUILayer@ layer) {
        try { return _LayerTypeName(int(layer.Type)); } catch { return "?"; }
    }

    CGameManialinkFrame@ _MlMainFrame(CGameUILayer@ layer) {
        try {
            auto page = layer.LocalPage;
            return page is null ? null : page.MainFrame;
        } catch { return null; }
    }

    Json::Value@ _MlPageJson(MlPageRef@ r) {
        auto o = Json::Object();
        o["ref"] = r.ref;
        o["source"] = r.source;
        o["name"] = r.Name();
        o["visible"] = _MlLayerVisible(r.layer);
        o["type"] = _MlLayerType(r.layer);
        string attach;
        try { attach = r.layer.AttachId; } catch { attach = ""; }
        if (attach.Length > 0) o["attachId"] = attach;
        o["hasPage"] = _MlMainFrame(r.layer) !is null;
        return o;
    }

    Json::Value@ ListManialinkPages(Json::Value &in input) {
        bool includeHidden = bool(input.Get("includeHidden", false));
        auto pages = CollectManialinkPages();
        auto arr = Json::Array();
        uint visible = 0;
        for (uint i = 0; i < pages.Length; i++) {
            bool vis = _MlLayerVisible(pages[i].layer);
            if (vis) visible++;
            if (vis || includeHidden) arr.Add(_MlPageJson(pages[i]));
        }
        auto output = Json::Object();
        output["context"] = DetectCurrentMlContext();
        output["total"] = int(pages.Length);
        output["visible"] = int(visible);
        output["pages"] = arr;
        return MakeSuccess(output);
    }

    bool _MlIsPasswordFormat(int fmt) {
        // Entry ETextFormat and TextEdit EControlScriptEditorTextFormat share
        // the order Basic, Script, Password, Newpassword.
        return fmt == int(CGameManialinkEntry::ETextFormat::Password)
            || fmt == int(CGameManialinkEntry::ETextFormat::Newpassword);
    }

    // Key value of one control, already formatted ("" when none).
    string _MlControlValue(CGameManialinkControl@ ctrl, bool rawText) {
        auto lbl = cast<CGameManialinkLabel>(ctrl);
        if (lbl !is null) {
            string v = _ReadLabelValue(ctrl);
            if (!rawText) v = Text::StripFormatCodes(_StripTranslationPrefix(v));
            return v.Length > 0 ? MlQuoteText(v) : "";
        }
        auto entry = cast<CGameManialinkEntry>(ctrl);
        if (entry !is null) {
            try {
                if (_MlIsPasswordFormat(int(entry.TextFormat))) return "value=<password>";
                return "value=" + MlQuoteText(string(entry.Value));
            } catch { return ""; }
        }
        auto edit = cast<CGameManialinkTextEdit>(ctrl);
        if (edit !is null) {
            try {
                if (_MlIsPasswordFormat(int(edit.TextFormat))) return "value=<password>";
                return "value=" + MlQuoteText(string(edit.Value));
            } catch { return ""; }
        }
        auto quad = cast<CGameManialinkQuad>(ctrl);
        if (quad !is null) {
            try {
                string url = quad.ImageUrl;
                if (url.Length > 0) return "img=" + MlQuoteText(url, true);
                string style = quad.Style;
                if (style.Length > 0) return "style=" + style + (quad.Substyle.Length > 0 ? "/" + quad.Substyle : "");
            } catch { return ""; }
            return "";
        }
        auto gauge = cast<CGameManialinkGauge>(ctrl);
        if (gauge !is null) {
            try { return "ratio=" + Text::Format("%.2f", gauge.Ratio); } catch { return ""; }
        }
        return "";
    }

    class _MlWalk {
        array<string> lines;
        uint maxLines;
        uint maxDepth;
        bool rawText;
        bool includeHidden;
        bool full;               // false: brief view (decoration pruned)
        uint controls = 0;       // control lines printed
        bool truncated = false;  // maxLines cut the output
        bool depthLimited = false;
        CGameManialinkControl@ focused;
    }

    class _MlNode {
        string type, id, value;
        array<string> classes;
        bool isFrame, hidden, focused, clickable;
        uint cutChildren = 0;    // shown children not walked (maxDepth)
        array<_MlNode@> kids;
    }

    bool _MlShown(CGameManialinkControl@ ctrl, bool includeHidden) {
        if (ctrl is null) return false;
        if (includeHidden) return true;
        try { return ctrl.Visible; } catch { return false; }
    }

    // Read one control and its shown subtree. Brief mode returns null for
    // controls that carry nothing an agent acts on (see MlBriefKeep).
    _MlNode@ _MlBuild(_MlWalk@ w, CGameManialinkControl@ ctrl, uint depth) {
        auto n = _MlNode();
        auto frame = cast<CGameManialinkFrame>(ctrl);
        n.isFrame = frame !is null;
        try { n.id = ctrl.ControlId; } catch { n.id = ""; }
        try {
            for (uint i = 0; i < ctrl.ControlClasses.Length; i++) n.classes.InsertLast(ctrl.ControlClasses[i]);
        } catch { /* no classes */ }
        bool visible = true;
        try { visible = ctrl.Visible; } catch { visible = false; }
        n.hidden = !visible;
        n.focused = ctrl is w.focused;
        n.clickable = MlIsClickable(n.classes);
        try { n.type = MlShortType(Reflection::TypeOf(ctrl).Name); } catch { n.type = "?"; }
        n.value = _MlControlValue(ctrl, w.rawText);
        if (frame !is null) {
            uint nb = 0;
            try { nb = frame.Controls.Length; } catch { nb = 0; }
            array<CGameManialinkControl@> shown;
            for (uint i = 0; i < nb; i++) {
                CGameManialinkControl@ child = null;
                try { @child = frame.Controls[i]; } catch { @child = null; }
                if (_MlShown(child, w.includeHidden)) shown.InsertLast(child);
            }
            if (shown.Length > 0 && depth >= w.maxDepth) {
                n.cutChildren = shown.Length;
                w.depthLimited = true;
            } else {
                for (uint i = 0; i < shown.Length; i++) {
                    auto kid = _MlBuild(w, shown[i], depth + 1);
                    if (kid !is null) n.kids.InsertLast(kid);
                }
            }
        }
        if (w.full) return n;
        // A clickable whose only kept child is plain text shows that text
        // itself: "frame#button-play .component-navigation-item "Play"".
        if (n.clickable && n.value.Length == 0 && n.kids.Length == 1 && n.cutChildren == 0
            && MlBriefAbsorb(n.kids[0].type, n.kids[0].kids.Length, n.kids[0].hidden, n.kids[0].focused)) {
            n.value = n.kids[0].value;
            n.kids.RemoveAt(0);
        }
        bool hasValue = n.value.Length > 0 && n.type != "quad";
        if (!MlBriefKeep(n.isFrame, hasValue, n.kids.Length + n.cutChildren, n.focused, n.clickable)) return null;
        // Collapse layout wrappers here, not at emit, so a clickable parent
        // sees the label beneath them.
        if (MlBriefCollapse(n.isFrame, n.clickable, n.kids.Length, n.cutChildren, n.hidden, n.focused)) return n.kids[0];
        return n;
    }

    void _MlEmit(_MlWalk@ w, _MlNode@ n, uint depth) {
        if (w.truncated) return;
        // Brief mode collapsed its wrappers in _MlBuild.
        if (w.full && MlCollapseFrame(n.isFrame, n.id, n.classes.Length, n.kids.Length, n.hidden, n.focused)) {
            _MlEmit(w, n.kids[0], depth);
            return;
        }
        if (w.lines.Length >= w.maxLines) { w.truncated = true; return; }
        array<string> extras;
        extras.InsertLast(w.full || n.type != "quad" ? n.value : "");
        if (n.hidden) extras.InsertLast("[hidden]");
        if (n.focused) extras.InsertLast("[focused]");
        if (n.cutChildren > 0) extras.InsertLast("(+" + n.cutChildren + " children)");
        w.lines.InsertLast(MlNodeLine(depth, n.type, n.id, n.classes, extras));
        w.controls++;
        for (uint i = 0; i < n.kids.Length && !w.truncated; i++) _MlEmit(w, n.kids[i], depth + 1);
    }

    Json::Value@ ViewManialinkPage(Json::Value &in input) {
        string selector = input.HasKey("page") ? string(input["page"]) : "";
        auto w = _MlWalk();
        w.maxLines = uint(Math::Clamp(int(input.Get("maxLines", int(ML_VIEW_MAX_LINES_DEFAULT))), 2, int(ML_VIEW_MAX_LINES_CAP)));
        w.maxDepth = uint(Math::Clamp(int(input.Get("maxDepth", int(ML_VIEW_MAX_DEPTH_DEFAULT))), 0, 64));
        w.rawText = bool(input.Get("rawText", false));
        w.includeHidden = bool(input.Get("includeHidden", false));
        w.full = bool(input.Get("full", false));
        auto pages = CollectManialinkPages();
        auto viewed = Json::Array();
        auto omitted = Json::Array();
        auto empty = Json::Array();
        auto skippedLoading = Json::Array();
        uint matchedNoPage = 0;
        for (uint i = 0; i < pages.Length; i++) {
            auto r = pages[i];
            // Cheap filters first: the name read copies the page XML.
            if (selector.Length == 0) {
                if (!_MlLayerVisible(r.layer)) continue;
                // Loading-screen layers report visible in every context but
                // draw only during loads; view them by ref or name.
                if (_MlLayerType(r.layer) == "LoadingScreen") { skippedLoading.Add(r.ref); continue; }
            } else if (!MlPageMatches(selector, r.ref, MlSelectorIsRef(selector) ? "" : MlLower(r.Name()))) {
                continue;
            }
            auto mainFrame = _MlMainFrame(r.layer);
            if (mainFrame is null) { matchedNoPage++; continue; }
            // A header needs room for itself and at least its root line.
            // Omitted pages report the ref only: a name costs a page-XML copy.
            if (w.truncated || w.lines.Length + 2 > w.maxLines) {
                w.truncated = true;
                omitted.Add(r.ref);
                continue;
            }
            string name = r.Name();
            @w.focused = null;
            try { @w.focused = r.layer.LocalPage.FocusedControl; } catch { /* none */ }
            string header = "== " + r.ref + " " + (name.Length > 0 ? name : "(unnamed)");
            string type = _MlLayerType(r.layer);
            if (type != "Normal") header += " [" + type + "]";
            if (!_MlLayerVisible(r.layer)) header += " [not drawn]";
            auto root = _MlBuild(w, mainFrame, 0);
            if (root is null) {
                // Brief mode: nothing but decoration. List the page, print nothing.
                empty.Add(r.ref);
                continue;
            }
            w.lines.InsertLast(header);
            _MlEmit(w, root, 0);
            viewed.Add(r.ref);
        }
        if (viewed.Length == 0 && omitted.Length == 0 && empty.Length == 0 && skippedLoading.Length == 0) {
            if (matchedNoPage > 0) return MakeError((selector.Length > 0 ? "'" + selector + "' matched only layers" : "every visible layer is a layer")
                                                    + " with no loaded page (LocalPage/MainFrame missing)", "NO_PAGE");
            if (selector.Length > 0) return MakeError("no page matches '" + selector + "'; call ListManialinkPages for refs and names", "NOT_FOUND");
            return MakeError("no visible ManiaLink pages", "NOT_FOUND");
        }
        if (w.truncated) w.lines.InsertLast("... truncated at maxLines=" + w.maxLines + (omitted.Length > 0 ? "; " + omitted.Length + " more page(s) in omittedPages" : ""));
        string tree = "";
        for (uint i = 0; i < w.lines.Length; i++) tree += (i > 0 ? "\n" : "") + w.lines[i];
        auto output = Json::Object();
        output["context"] = DetectCurrentMlContext();
        output["pages"] = viewed;
        output["tree"] = tree;
        output["controls"] = int(w.controls);
        output["truncated"] = w.truncated;
        output["depthLimited"] = w.depthLimited;
        if (omitted.Length > 0) output["omittedPages"] = omitted;
        if (empty.Length > 0) output["emptyPages"] = empty;
        if (skippedLoading.Length > 0) output["loadingScreenPages"] = skippedLoading;
        return MakeSuccess(output);
    }
}
