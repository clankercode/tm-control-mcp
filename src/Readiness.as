namespace TmMcp {
    string DetectGameModeName() {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return "Unknown";
        if (IsLoadingLike(app)) return "Loading";
        if (app.Editor !is null) return "Editor";
        if (app.CurrentPlayground !is null) return "Race";
        return "Menu";
    }

    bool DialogIsBlocking(Json::Value@ dialog) {
        if (dialog is null) return false;
        if (!bool(dialog["available"])) return false;
        string kind = string(dialog["dialogKind"]);
        return kind != "none" && kind.Length > 0;
    }

    bool MenuModuleAvailable() {
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null || app.Switcher is null) return false;
        if (app.Switcher.ModuleStack.Length == 0) return false;
        return cast<CTrackManiaMenus>(app.Switcher.ModuleStack[app.Switcher.ModuleStack.Length - 1]) !is null;
    }

    bool ActiveMenuPageVisible(const string &in pageName) {
        if (pageName.Length == 0) return false;
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.MenuManager is null) return false;
        auto maniaApp = app.MenuManager.MenuCustom_CurrentManiaApp;
        if (maniaApp is null) return false;
        string needle = pageName.ToLower();
        uint nb = 0;
        try { nb = maniaApp.UILayers.Length; } catch { nb = 0; }
        for (uint i = 0; i < nb; i++) {
            CGameUILayer@ layer = null;
            try { @layer = maniaApp.UILayers[i]; } catch { @layer = null; }
            if (layer is null) continue;
            string idName = "";
            try { idName = string(layer.IdName).ToLower(); } catch { idName = ""; }
            if (!idName.Contains(needle)) continue;
            bool vis = true;
            try { vis = bool(layer.IsVisible); } catch { vis = true; }
            if (vis) return true;
        }
        return false;
    }

    Json::Value BuildReadinessSnapshot(const string &in wantRaw) {
        string want = wantRaw.ToLower();
        if (want.Length == 0) want = "any";
        if (want != "editor" && want != "menu" && want != "any" && want != "race") want = "any";

        string mode = DetectGameModeName();
        auto dialog = BasicDialogSummary();
        bool dialogClear = !DialogIsBlocking(dialog);

        auto editor = GetEditor();
        bool hasChallenge = editor !is null && editor.Challenge !is null;
        bool editorReadyForRequest = false;
        if (editor !is null && editor.PluginMapType !is null) {
            editorReadyForRequest = editor.PluginMapType.IsEditorReadyForRequest;
        }

        Json::Value inventory = Json::Object();
        bool inventoryReady = true;
        if (editor !is null && editor.PluginMapType !is null) {
            inventory = InventorySummary(editor.PluginMapType);
            inventoryReady = !bool(inventory["isScanningItems"]);
        } else {
            inventory["available"] = false;
            inventoryReady = want != "editor";
        }

        Json::Value map = Json::Object();
        if (hasChallenge) {
            map = MapSummary(editor);
        } else {
            map["available"] = false;
        }

        bool modeOk = true;
        if (want == "editor") modeOk = mode == "Editor";
        else if (want == "menu") modeOk = mode == "Menu";
        else if (want == "race") modeOk = mode == "Race";

        bool menuOk = true;
        if (want == "menu") menuOk = MenuModuleAvailable();

        array<string> blocking;
        if (!modeOk) blocking.InsertLast("mode is " + mode + ", want " + want);
        if (!dialogClear) blocking.InsertLast("dialog active");
        if (want == "editor" && !editorReadyForRequest) blocking.InsertLast("editor not ready for request");
        if (want == "editor" && !hasChallenge) blocking.InsertLast("no challenge/map loaded");
        if (want == "menu" && !menuOk) blocking.InsertLast("menu module not on stack");

        Json::Value warnings = Json::Array();
        if (want == "editor" && !inventoryReady) warnings.Add("inventory still scanning items");

        Json::Value checks = Json::Object();
        checks["socketAlive"] = true;
        checks["modeOk"] = modeOk;
        checks["dialogClear"] = dialogClear;
        checks["editorReadyForRequest"] = editorReadyForRequest;
        checks["inventoryReady"] = inventoryReady;
        checks["hasChallenge"] = hasChallenge;
        checks["menuModuleAvailable"] = MenuModuleAvailable();
        checks["eppToolPack"] = IsEditorPlusPlusAvailable();

        bool ready = blocking.Length == 0;
        // Soft: inventory scanning alone shouldn't hard-fail "any"
        if (want == "any" && mode != "Unknown" && dialogClear) {
            ready = true;
            // still list soft reasons
        }

        Json::Value reasons = Json::Array();
        for (uint i = 0; i < blocking.Length; i++) reasons.Add(blocking[i]);

        Json::Value output = Json::Object();
        output["ready"] = ready;
        output["mode"] = mode;
        output["want"] = want;
        output["checks"] = checks;
        output["dialog"] = dialog;
        output["map"] = map;
        output["inventory"] = inventory;
        output["blockingReasons"] = reasons;
        output["warnings"] = warnings;
        return output;
    }

    Json::Value@ GetReadiness(Json::Value &in input) {
        string want = input.HasKey("want") ? string(input["want"]) : "any";
        return MakeSuccess(BuildReadinessSnapshot(want));
    }

    bool ConditionSatisfied(const string &in condition, Json::Value &in input, Json::Value@ &out last) {
        string cond = condition.ToLower();
        @last = Json::Object();

        if (cond == "mode") {
            string equals = input.HasKey("equals") ? string(input["equals"]) : "";
            string mode = DetectGameModeName();
            last["mode"] = mode;
            last["equals"] = equals;
            return equals.Length == 0 || mode.ToLower() == equals.ToLower();
        }

        if (cond == "dialogclear" || cond == "dialog_clear" || cond == "dialog-clear") {
            auto dialog = BasicDialogSummary();
            @last = dialog;
            return !DialogIsBlocking(dialog);
        }

        if (cond == "editorready" || cond == "editor_ready" || cond == "editor-ready") {
            auto editor = GetEditor();
            bool ready = editor !is null && editor.PluginMapType !is null && editor.PluginMapType.IsEditorReadyForRequest;
            last["editorReadyForRequest"] = ready;
            last["mode"] = DetectGameModeName();
            return ready;
        }

        if (cond == "pagevisible" || cond == "page_visible" || cond == "page-visible") {
            string page = input.HasKey("page") ? string(input["page"]) : "";
            bool visible = ActiveMenuPageVisible(page);
            last["page"] = page;
            last["visible"] = visible;
            return visible;
        }

        if (cond == "mapitems" || cond == "map_items" || cond == "map-items") {
            auto editor = GetEditor();
            int count = 0;
            if (editor !is null && editor.Challenge !is null) count = int(editor.Challenge.AnchoredObjects.Length);
            string op = input.HasKey("op") ? string(input["op"]).ToLower() : "eq";
            int target = input.HasKey("count") ? int(input["count"]) : 0;
            last["count"] = count;
            last["op"] = op;
            last["target"] = target;
            if (op == "gte" || op == ">=") return count >= target;
            if (op == "lte" || op == "<=") return count <= target;
            return count == target;
        }

        if (cond == "mapblocks" || cond == "map_blocks" || cond == "map-blocks") {
            auto editor = GetEditor();
            int count = 0;
            if (editor !is null && editor.Challenge !is null) count = int(editor.Challenge.Blocks.Length);
            string op = input.HasKey("op") ? string(input["op"]).ToLower() : "eq";
            int target = input.HasKey("count") ? int(input["count"]) : 0;
            last["count"] = count;
            last["op"] = op;
            last["target"] = target;
            if (op == "gte" || op == ">=") return count >= target;
            if (op == "lte" || op == "<=") return count <= target;
            return count == target;
        }

        if (cond == "readiness" || cond == "ready") {
            string want = input.HasKey("want") ? string(input["want"]) : "editor";
            auto snap = BuildReadinessSnapshot(want);
            @last = snap;
            return bool(snap["ready"]);
        }

        last["error"] = "unknown condition: " + condition;
        return false;
    }

    Json::Value@ WaitUntil(Json::Value &in input) {
        if (!input.HasKey("condition")) {
            return MakeError("missing condition", "INVALID_INPUT", false, "", "condition: mode|dialogClear|editorReady|pageVisible|mapItems|mapBlocks|readiness");
        }
        string condition = string(input["condition"]);
        int timeoutMs = input.HasKey("timeoutMs") ? int(input["timeoutMs"]) : 20000;
        int pollMs = input.HasKey("pollMs") ? int(input["pollMs"]) : 100;
        if (timeoutMs < 0) timeoutMs = 0;
        if (timeoutMs > 1800000) timeoutMs = 1800000;
        if (pollMs < 50) pollMs = 50;
        if (pollMs > 2000) pollMs = 2000;

        // Validate condition early
        Json::Value@ probe;
        string condLower = condition.ToLower();
        bool known = condLower == "mode"
            || condLower == "dialogclear" || condLower == "dialog_clear" || condLower == "dialog-clear"
            || condLower == "editorready" || condLower == "editor_ready" || condLower == "editor-ready"
            || condLower == "pagevisible" || condLower == "page_visible" || condLower == "page-visible"
            || condLower == "mapitems" || condLower == "map_items" || condLower == "map-items"
            || condLower == "mapblocks" || condLower == "map_blocks" || condLower == "map-blocks"
            || condLower == "readiness" || condLower == "ready";
        if (!known) {
            return MakeError("unknown condition: " + condition, "INVALID_INPUT", false, "", "mode|dialogClear|editorReady|pageVisible|mapItems|mapBlocks|readiness");
        }

        uint64 t0 = Time::Now;
        uint64 lastTick = t0;
        uint chargedMs = 0;
        bool sawLoading = false;
        Json::Value@ last;
        bool ok = false;
        while (true) {
            ok = ConditionSatisfied(condition, input, last);
            if (ok) break;
            uint64 now = Time::Now;
            uint dt = uint(now - lastTick);
            lastTick = now;
            auto app = cast<CTrackMania>(GetApp());
            bool loading = IsLoadingLike(app);
            if (loading) {
                sawLoading = true;
                if (now - t0 >= 1800000) break;
            } else {
                chargedMs += dt;
                if (timeoutMs == 0 || chargedMs >= uint(timeoutMs)) break;
            }
            uint slice = uint(pollMs);
            if (!loading && timeoutMs > 0 && uint(timeoutMs) > chargedMs) {
                slice = Math::Min(slice, uint(timeoutMs) - chargedMs);
            }
            uint64 sliceStart = Time::Now;
            while (Time::Now - sliceStart < slice) {
                yield();
            }
        }

        uint elapsedMs = uint(Time::Now - t0);
        Json::Value output = Json::Object();
        output["ok"] = ok;
        output["timedOut"] = !ok;
        output["elapsedMs"] = int(elapsedMs);
        output["chargedMs"] = int(chargedMs);
        output["loading"] = sawLoading;
        output["condition"] = condition;
        output["timeoutMs"] = timeoutMs;
        output["pollMs"] = pollMs;
        if (last !is null) output["last"] = last;
        if (!ok) {
            output["code"] = "TIMEOUT";
            output["retryable"] = true;
            output["hint"] = sawLoading
                ? "Still loading or load finished without reaching the condition. Check GetMode / GetDialog."
                : "Increase timeoutMs or check GetReadiness / GetMode / GetDialog";
            output["error"] = "WaitUntil timed out after " + elapsedMs + "ms waiting for " + condition;
        }
        // Always success envelope so agents can branch on timedOut/ok without
        // treating a legitimate timeout as a hard tool failure.
        return MakeSuccess(output);
    }
}
