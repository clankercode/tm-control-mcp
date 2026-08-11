namespace TmMcp {
    // Ad-hoc ManiaScript runner via MLHook inject (same three contexts as MLHook
    // debug UILayers browser: menu / playground / editor PluginMapType).
    //
    // MLHook wraps plain script in <script><!-- ... --></script> and injects a
    // UI layer named MLHook_<pageUid>. Manialink pages are sandboxed from each
    // other; title-control APIs and local game objects are the usual reach.

    const string MCP_ADHOC_PAGE_UID_DEFAULT = "McpAdHoc";
    const uint MCP_ADHOC_SCRIPT_MAX_CHARS = 120000;
    const int MCP_ADHOC_WAIT_MS_MAX = 10000;

    string NormalizeMlContext(const string &in raw) {
        string c = raw.ToLower();
        c = c.Replace("_", "-").Replace(" ", "-");
        if (c == "current" || c == "auto" || c == "") return "current";
        if (c == "menu" || c == "main-menu" || c == "mainmenu") return "menu";
        if (c == "in-map" || c == "inmap" || c == "map" || c == "playground" || c == "pg" || c == "race") return "in-map";
        if (c == "in-editor" || c == "ineditor" || c == "editor" || c == "ed") return "in-editor";
        return "";
    }

    string DetectCurrentMlContext() {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return "menu";
        if (cast<CGameCtnEditorFree>(app.Editor) !is null) return "in-editor";
        // Playground / race / solo map (not main menu).
        if (app.CurrentPlayground !is null) return "in-map";
        if (app.RootMap !is null && app.Editor is null) return "in-map";
        return "menu";
    }

    bool MlContextTargetReady(const string &in ctx, string &out detail) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) {
            detail = "app unavailable";
            return false;
        }
        if (ctx == "menu") {
            if (app.MenuManager is null || app.MenuManager.MenuCustom_CurrentManiaApp is null) {
                detail = "MenuCustom_CurrentManiaApp is null (not in main-menu module?)";
                return false;
            }
            return true;
        }
        if (ctx == "in-map") {
            if (app.Network is null || app.Network.ClientManiaAppPlayground is null) {
                // Fall back: some builds expose playground via CurrentPlayground only.
                if (app.CurrentPlayground is null) {
                    detail = "no playground ManiaApp (load a map / enter race)";
                    return false;
                }
            }
            return true;
        }
        if (ctx == "in-editor") {
            auto editor = cast<CGameCtnEditorFree>(app.Editor);
            if (editor is null || editor.PluginMapType is null) {
                detail = "editor PluginMapType unavailable (enter the map editor)";
                return false;
            }
            return true;
        }
        detail = "unknown context";
        return false;
    }

    void InjectManialinkForContext(const string &in ctx, const string &in pageUid, const string &in script, bool replace) {
        if (ctx == "menu") {
            MLHook::InjectManialinkToMenu(pageUid, script, replace);
        } else if (ctx == "in-map") {
            MLHook::InjectManialinkToPlayground(pageUid, script, replace);
        } else if (ctx == "in-editor") {
            MLHook::InjectManialinkToEditor(pageUid, script, replace);
        }
    }

    void RemoveManialinkForContext(const string &in ctx, const string &in pageUid) {
        if (ctx == "menu") {
            MLHook::RemoveInjectedMLFromMenu(pageUid);
        } else if (ctx == "in-map") {
            MLHook::RemoveInjectedMLFromPlayground(pageUid);
        } else if (ctx == "in-editor") {
            MLHook::RemoveInjectedMLFromEditor(pageUid);
        }
    }

    string SanitizePageUid(const string &in raw) {
        string sanitized = "";
        for (uint i = 0; i < raw.Length; i++) {
            string ch = raw.SubStr(i, 1);
            bool ok = (ch >= "a" && ch <= "z")
                || (ch >= "A" && ch <= "Z")
                || (ch >= "0" && ch <= "9")
                || ch == "_" || ch == "-";
            if (ok) sanitized += ch;
        }
        if (sanitized.Length == 0) return MCP_ADHOC_PAGE_UID_DEFAULT;
        if (sanitized.Length > 48) sanitized = sanitized.SubStr(0, 48);
        return sanitized;
    }

    Json::Value@ RunManialinkScript(Json::Value &in input) {
        if (!input.HasKey("script")) {
            return MakeError("missing script (ManiaScript body or manialink fragment without outer <manialink> tags)");
        }
        string script = string(input["script"]);
        if (script.Trim().Length == 0) return MakeError("script is empty");
        if (uint(script.Length) > MCP_ADHOC_SCRIPT_MAX_CHARS) {
            return MakeError("script too large (" + script.Length + " chars; max " + MCP_ADHOC_SCRIPT_MAX_CHARS + ")");
        }
        // MLHook refuses outer <manialink> tags; fail fast with a clearer error.
        if (script.Contains("<manialink")) {
            return MakeError("do not include outer <manialink> tags; pass raw ManiaScript or an inner fragment. MLHook wraps the page as MLHook_<pageUid>.");
        }

        string ctxIn = input.HasKey("context") ? string(input["context"]) : "current";
        string ctxNorm = NormalizeMlContext(ctxIn);
        if (ctxNorm.Length == 0) {
            return MakeError("context must be one of: current, menu, in-map, in-editor (aliases: playground, editor, race)");
        }
        string resolved = ctxNorm == "current" ? DetectCurrentMlContext() : ctxNorm;

        string readyDetail;
        if (!MlContextTargetReady(resolved, readyDetail)) {
            return MakeError("context '" + resolved + "' not ready: " + readyDetail);
        }

        string pageUid = SanitizePageUid(
            input.HasKey("pageUid") ? string(input["pageUid"]) : MCP_ADHOC_PAGE_UID_DEFAULT
        );
        bool replace = input.HasKey("replace") ? bool(input["replace"]) : true;
        bool persist = input.HasKey("persist") ? bool(input["persist"]) : true;
        int waitMs = input.HasKey("waitMs") ? int(input["waitMs"]) : 150;
        if (waitMs < 0) waitMs = 0;
        if (waitMs > MCP_ADHOC_WAIT_MS_MAX) waitMs = MCP_ADHOC_WAIT_MS_MAX;

        try {
            InjectManialinkForContext(resolved, pageUid, script, replace);
        } catch {
            return MakeError("MLHook inject failed: " + getExceptionInfo());
        }

        // Give MLHook's inject queue a few frames to UILayerCreate / assign page.
        uint start = Time::Now;
        while (Time::Now - start < uint(waitMs)) {
            yield();
        }

        bool removed = false;
        if (!persist) {
            try {
                RemoveManialinkForContext(resolved, pageUid);
                removed = true;
            } catch {
                // Still report inject success; cleanup is best-effort.
                removed = false;
            }
        }

        Json::Value output = Json::Object();
        output["injected"] = true;
        output["contextRequested"] = ctxIn;
        output["contextResolved"] = resolved;
        output["pageUid"] = pageUid;
        output["attachIdHint"] = "MLHook_" + pageUid;
        output["replace"] = replace;
        output["persist"] = persist;
        output["removedAfter"] = removed;
        output["waitMs"] = waitMs;
        output["scriptChars"] = int(script.Length);
        output["note"] = "Fire-and-forget inject via MLHook (same path as UILayers browser Create). "
            + "Manialink pages are sandboxed; use TitleControl / local APIs available in that context. "
            + "There is no return channel unless the script sends events your hooks observe. "
            + "Bad ManiaScript can trigger the game recovery restart — keep scripts small and linted. "
            + "prefer persist=true and re-inject with replace=true to re-run; set persist=false to blank the layer after waitMs.";
        return MakeSuccess(output);
    }

    void CleanupAdHocManialink() {
        // Best-effort unload of default + any leftover ad-hoc pages on plugin disable.
        try { MLHook::RemoveInjectedMLFromMenu(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::RemoveInjectedMLFromPlayground(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::RemoveInjectedMLFromEditor(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::UnregisterMLHooksAndRemoveInjectedML(); } catch {}
    }
}
