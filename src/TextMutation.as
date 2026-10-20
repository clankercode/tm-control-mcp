namespace TmMcp {
    Json::Value@ ValidateTextPatchInput(Json::Value &in input) {
        if (!input.HasKey("confirm") || input["confirm"].GetType() != Json::Type::Boolean
            || !bool(input["confirm"])) return MakeError("Text mutation requires confirm:true", "CONFIRM_REQUIRED");
        if (!input.HasKey("find") || !input.HasKey("replace")
            || input["find"].GetType() != Json::Type::String || input["replace"].GetType() != Json::Type::String
            || (input.HasKey("replaceAll") && input["replaceAll"].GetType() != Json::Type::Boolean))
            return MakeError("find/replace must be strings and replaceAll must be boolean", "BAD_INPUT");
        if (string(input["find"]).Length == 0) return MakeError("find must be non-empty", "EMPTY_FIND");
        return null;
    }

    Json::Value@ TextPatchOutcome(TextPatchPlan@ plan, bool written, bool readbackMatches) {
        auto output = Json::Object();
        output["matched"] = plan.matched;
        output["written"] = written;
        output["changed"] = plan.changed;
        output["readbackMatches"] = readbackMatches;
        output["expectedLength"] = plan.text.Length;
        if (!readbackMatches) {
            auto error = MakeError("Text was assigned but readback could not be verified", "READBACK_UNCONFIRMED");
            error["output"] = output;
            return error;
        }
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionSetText(Json::Value &in input) {
        auto invalid = ValidateTextPatchInput(input);
        if (invalid !is null) return invalid;
        // Native/game scripts and driving sessions are outside this editor-only writer.
        if (!input.HasKey("drive") || input["drive"].GetType() != Json::Type::String
            || string(input["drive"]) != "user" || !input.HasKey("path")
            || input["path"].GetType() != Json::Type::String
            || !IsUserEditorScriptPath(string(input["path"])))
            return MakeError("setText requires a user Scripts/EditorPlugins/*.Script.txt path", "EDITOR_SCRIPT_ONLY");
        if (DetectGameModeName() != "MapEditor" || IsLoadingLike(cast<CTrackMania>(GetApp()))
            || DetectCalculatingShadows()) return MakeError("Idle map editor required", "EDITOR_BUSY");
        auto diagnostics = ManiaScriptDiagnostics();
        if (bool(diagnostics["crashDialogDetected"])) return MakeError("Resolve the script crash before writing", "SCRIPT_CRASH");
        CSystemFidFile@ file;
        auto missing = FidsNeedFile(input, "setText", file);
        if (missing !is null) return missing;
        string err;
        auto script = FidsNeedTextScript(file, err);
        if (script is null) return MakeError("Editor script cache unavailable", "NOT_TEXT_SCRIPT");
        string source;
        try { source = script.Text; } catch { return MakeError("Could not read editor script", "TEXT_READ_FAILED"); }
        auto plan = PlanTextPatch(source, string(input["find"]), string(input["replace"]), input.Get("replaceAll", false));
        if (plan.error.Length > 0) return MakeError("Text replacement rejected", plan.error);
        if (!plan.changed) return TextPatchOutcome(plan, false, true);
        try { script.Text = plan.text; } catch { return MakeError("Editor script assignment failed; inspect state before retry", "TEXT_WRITE_FAILED"); }
        bool verified = false;
        try { verified = script.Text == plan.text; } catch { }
        return TextPatchOutcome(plan, true, verified);
    }

    Json::Value@ PatchLayerXml(Json::Value &in input) {
        auto invalid = ValidateTextPatchInput(input);
        if (invalid !is null) return invalid;
        if (!input.HasKey("layerIndex") || input["layerIndex"].GetType() != Json::Type::Number)
            return MakeError("Integer layerIndex required", "BAD_INPUT");
        double index = double(input["layerIndex"]);
        if (index < 0 || index > 4096 || index != Math::Floor(index)) return MakeError("Invalid layerIndex", "BAD_INPUT");
        // Never rewrite a layer during driving, editor testing, or loading.
        if (DetectGameModeName() != "Menu") return MakeError("Menu required for page mutation", "MENU_ONLY");
        if (bool(ManiaScriptDiagnostics()["crashDialogDetected"])) return MakeError("Resolve the script crash before writing", "SCRIPT_CRASH");
        auto menu = _GetMenuApp();
        if (menu is null || uint(index) >= menu.UILayers.Length) return MakeError("Layer unavailable", "NOT_FOUND");
        auto layer = menu.UILayers[uint(index)];
        if (layer is null) return MakeError("Layer unavailable", "NOT_FOUND");
        string source;
        try { source = layer.ManialinkPageUtf8; } catch { return MakeError("Could not read page", "XML_READ_FAILED"); }
        auto plan = PlanTextPatch(source, string(input["find"]), string(input["replace"]), input.Get("replaceAll", false));
        if (plan.error.Length > 0) return MakeError("Text replacement rejected", plan.error);
        if (!plan.changed) return TextPatchOutcome(plan, false, true);
        try { layer.ManialinkPageUtf8 = plan.text; } catch { return MakeError("Page assignment failed; inspect state before retry", "XML_WRITE_FAILED"); }
        bool verified = false;
        try { verified = layer.ManialinkPageUtf8 == plan.text; } catch { }
        return TextPatchOutcome(plan, true, verified);
    }
}
