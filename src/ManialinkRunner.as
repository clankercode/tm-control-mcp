namespace TmMcp {
    // Ad-hoc ManiaScript runner via MLHook inject (same three contexts as MLHook
    // debug UILayers browser: menu / playground / editor PluginMapType).
    //
    // MLHook wraps plain script in <script><!-- ... --></script> and injects a
    // UI layer named MLHook_<pageUid>. Manialink pages are sandboxed from each
    // other; title-control APIs and local game objects are the usual reach.
    //
    // Result channel: register HookMLEventsByType for resultEvent (default
    // McpAdHoc_Result). Injected scripts should:
    //   SendCustomEvent("MLHook_Event_McpAdHoc_Result", ["payload", ...]);
    // MLHook auto-prefixes MLHook_Event_ when registering the hook type.

    const string MCP_ADHOC_PAGE_UID_DEFAULT = "McpAdHoc";
    const string MCP_ADHOC_RESULT_EVENT_DEFAULT = "McpAdHoc_Result";
    const uint MCP_ADHOC_SCRIPT_MAX_CHARS = 120000;
    const int MCP_ADHOC_WAIT_MS_MAX = 10000;
    const int MCP_ADHOC_COLLECT_MS_MAX = 15000;
    const uint MCP_ADHOC_RESULT_MAX_EVENTS = 64;
    const uint MCP_ADHOC_RESULT_MAX_DATA_CHARS = 8000;

    class McpAdHocResultHook : MLHook::HookMLEventsByType {
        array<string> eventTypes;
        array<string> payloads; // JSON-ish joined data rows
        uint maxEvents;

        McpAdHocResultHook(const string &in typeToHook, uint maxEvents = MCP_ADHOC_RESULT_MAX_EVENTS) {
            super(typeToHook);
            this.maxEvents = maxEvents;
        }

        void OnEvent(MLHook::PendingEvent@ event) override {
            if (event is null) return;
            if (eventTypes.Length >= maxEvents) return;
            eventTypes.InsertLast(event.type);
            string row = "";
            for (uint i = 0; i < event.data.Length; i++) {
                if (i > 0) row += "\t";
                string cell = string(event.data[i]);
                if (cell.Length > int(MCP_ADHOC_RESULT_MAX_DATA_CHARS)) {
                    cell = cell.SubStr(0, MCP_ADHOC_RESULT_MAX_DATA_CHARS) + "…";
                }
                row += cell;
            }
            payloads.InsertLast(row);
        }

        Json::Value ToJson() {
            Json::Value arr = Json::Array();
            for (uint i = 0; i < eventTypes.Length; i++) {
                Json::Value e = Json::Object();
                e["type"] = eventTypes[i];
                e["data"] = payloads[i];
                // also split tabs into array for convenience
                Json::Value parts = Json::Array();
                auto bits = payloads[i].Split("\t");
                for (uint j = 0; j < bits.Length; j++) parts.Add(bits[j]);
                e["dataParts"] = parts;
                arr.Add(e);
            }
            return arr;
        }
    }

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

    string SanitizeResultEvent(const string &in raw) {
        string s = raw.Trim();
        if (s.Length == 0) return MCP_ADHOC_RESULT_EVENT_DEFAULT;
        // Strip accidental full prefix; RegisterMLHook adds MLHook_Event_
        if (s.StartsWith("MLHook_Event_")) s = s.SubStr(13);
        string sanitized = "";
        for (uint i = 0; i < s.Length; i++) {
            string ch = s.SubStr(i, 1);
            bool ok = (ch >= "a" && ch <= "z")
                || (ch >= "A" && ch <= "Z")
                || (ch >= "0" && ch <= "9")
                || ch == "_" || ch == "-";
            if (ok) sanitized += ch;
        }
        if (sanitized.Length == 0) return MCP_ADHOC_RESULT_EVENT_DEFAULT;
        if (sanitized.Length > 64) sanitized = sanitized.SubStr(0, 64);
        return sanitized;
    }

    Json::Value@ RunManialinkScript(Json::Value &in input) {
        if (!input.HasKey("script")) {
            return MakeError("missing script (ManiaScript body or manialink fragment without outer <manialink> tags)", "INVALID_INPUT");
        }
        string script = string(input["script"]);
        if (script.Trim().Length == 0) return MakeError("script is empty", "INVALID_INPUT");
        if (uint(script.Length) > MCP_ADHOC_SCRIPT_MAX_CHARS) {
            return MakeError("script too large (" + script.Length + " chars; max " + MCP_ADHOC_SCRIPT_MAX_CHARS + ")", "INVALID_INPUT");
        }
        if (script.Contains("<manialink")) {
            return MakeError("do not include outer <manialink> tags; pass raw ManiaScript or an inner fragment. MLHook wraps the page as MLHook_<pageUid>.", "INVALID_INPUT");
        }

        string ctxIn = input.HasKey("context") ? string(input["context"]) : "current";
        string ctxNorm = NormalizeMlContext(ctxIn);
        if (ctxNorm.Length == 0) {
            return MakeError("context must be one of: current, menu, in-map, in-editor (aliases: playground, editor, race)", "INVALID_INPUT");
        }
        string resolved = ctxNorm == "current" ? DetectCurrentMlContext() : ctxNorm;

        string readyDetail;
        if (!MlContextTargetReady(resolved, readyDetail)) {
            return MakeError("context '" + resolved + "' not ready: " + readyDetail, "EDITOR_BUSY", true);
        }

        string pageUid = SanitizePageUid(
            input.HasKey("pageUid") ? string(input["pageUid"]) : MCP_ADHOC_PAGE_UID_DEFAULT
        );
        bool replace = input.HasKey("replace") ? bool(input["replace"]) : true;
        bool persist = input.HasKey("persist") ? bool(input["persist"]) : true;
        int waitMs = input.HasKey("waitMs") ? int(input["waitMs"]) : 150;
        if (waitMs < 0) waitMs = 0;
        if (waitMs > MCP_ADHOC_WAIT_MS_MAX) waitMs = MCP_ADHOC_WAIT_MS_MAX;

        int collectMs = input.HasKey("collectMs") ? int(input["collectMs"]) : 0;
        if (collectMs < 0) collectMs = 0;
        if (collectMs > MCP_ADHOC_COLLECT_MS_MAX) collectMs = MCP_ADHOC_COLLECT_MS_MAX;
        string resultEvent = SanitizeResultEvent(
            input.HasKey("resultEvent") ? string(input["resultEvent"]) : MCP_ADHOC_RESULT_EVENT_DEFAULT
        );

        McpAdHocResultHook@ hook = null;
        bool hookRegistered = false;
        if (collectMs > 0) {
            @hook = McpAdHocResultHook(resultEvent, MCP_ADHOC_RESULT_MAX_EVENTS);
            try {
                MLHook::RegisterMLHook(hook, resultEvent, false);
                hookRegistered = true;
            } catch {
                return MakeError("MLHook RegisterMLHook failed: " + getExceptionInfo(), "INJECT_FAILED", true);
            }
        }

        try {
            InjectManialinkForContext(resolved, pageUid, script, replace);
        } catch {
            if (hookRegistered && hook !is null) {
                try { MLHook::UnregisterMLHookFromAll(hook); } catch {}
            }
            return MakeError("MLHook inject failed: " + getExceptionInfo(), "INJECT_FAILED", true);
        }

        // Give MLHook's inject queue a few frames to UILayerCreate / assign page.
        uint start = Time::Now;
        while (Time::Now - start < uint(waitMs)) {
            yield();
        }

        // Optional collect window for result events
        if (collectMs > 0) {
            uint c0 = Time::Now;
            while (Time::Now - c0 < uint(collectMs)) {
                yield();
            }
        }

        bool removed = false;
        if (!persist) {
            try {
                RemoveManialinkForContext(resolved, pageUid);
                removed = true;
            } catch {
                removed = false;
            }
        }

        if (hookRegistered && hook !is null) {
            try { MLHook::UnregisterMLHookFromAll(hook); } catch {}
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
        output["collectMs"] = collectMs;
        output["resultEvent"] = resultEvent;
        output["resultEventFull"] = "MLHook_Event_" + resultEvent;
        output["scriptChars"] = int(script.Length);
        if (hook !is null) {
            output["results"] = hook.ToJson();
            output["resultCount"] = int(hook.eventTypes.Length);
        } else {
            output["results"] = Json::Array();
            output["resultCount"] = 0;
        }
        output["note"] = "Inject via MLHook. For a return channel set collectMs>0 and SendCustomEvent(\"MLHook_Event_"
            + resultEvent + "\", [\"payload\", ...]) from the script. "
            + "Manialink pages are sandboxed. Bad ManiaScript can trigger game recovery — keep scripts small. "
            + "prefer persist=true and re-inject with replace=true to re-run; set persist=false to blank the layer after wait+collect.";
        return MakeSuccess(output);
    }

    void CleanupAdHocManialink() {
        try { MLHook::RemoveInjectedMLFromMenu(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::RemoveInjectedMLFromPlayground(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::RemoveInjectedMLFromEditor(MCP_ADHOC_PAGE_UID_DEFAULT); } catch {}
        try { MLHook::UnregisterMLHooksAndRemoveInjectedML(); } catch {}
    }
}
