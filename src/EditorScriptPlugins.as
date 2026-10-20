namespace TmMcp {
    const uint EDITOR_SCRIPT_PLUGIN_NAME_LIMIT = 64;
    const uint EDITOR_SCRIPT_PLUGIN_NAME_BYTES = 256;

    // A game nod handle alone does not own the native nod's lifetime. Retain
    // the map until the post-yield identity comparison, including error exits.
    class EditorScriptPluginMapLease {
        CGameCtnChallenge@ map;
        EditorScriptPluginMapLease(CGameCtnChallenge@ value) {
            @map = value;
            if (map !is null) map.MwAddRef();
        }
        ~EditorScriptPluginMapLease() {
            Release();
        }
        void Release() {
            if (map is null) return;
            map.MwRelease();
            @map = null;
        }
    }

    string BoundedEditorScriptPluginName(const string &in name) {
        if (uint(name.Length) <= EDITOR_SCRIPT_PLUGIN_NAME_BYTES) return name;
        uint end = EDITOR_SCRIPT_PLUGIN_NAME_BYTES;
        // Openplanet strings are UTF-8: avoid cutting through a code point.
        while (end > 0 && (name[end] & 0xC0) == 0x80) end--;
        return name.SubStr(0, end);
    }

    Json::Value EditorScriptPluginsSnapshot(CGameCtnEditorFree@ editor) {
        Json::Value output = Json::Object();
        output["editorAvailable"] = editor !is null;
        output["mapAvailable"] = GetChallenge() !is null;
        output["loading"] = IsLoadingLike(cast<CTrackMania>(GetApp()));
        // Use the public wait-dialog observation, without native memory reads.
        output["calculatingShadows"] = WaitLooksLikeLightmapCompute();
        auto diagnostics = ManiaScriptDiagnostics();
        output["crashDialogDetected"] = bool(diagnostics["crashDialogDetected"]);
        output["reloadInvoked"] = false;
        output["reloadReturned"] = false;
        output["reloadVerified"] = false;
        output["sourceVersionVerified"] = false;
        output["readinessVerified"] = false;
        Json::Value names = Json::Array();
        uint total = editor is null ? 0 : editor.ForcedPluginsNames.Length;
        bool truncated = total > EDITOR_SCRIPT_PLUGIN_NAME_LIMIT;
        uint count = total > EDITOR_SCRIPT_PLUGIN_NAME_LIMIT ? EDITOR_SCRIPT_PLUGIN_NAME_LIMIT : total;
        for (uint i = 0; i < count; i++) {
            string name = string(editor.ForcedPluginsNames[i]);
            if (uint(name.Length) > EDITOR_SCRIPT_PLUGIN_NAME_BYTES) truncated = true;
            names.Add(BoundedEditorScriptPluginName(name));
        }
        output["forcedPluginNames"] = names;
        output["forcedPluginNameCount"] = total;
        output["forcedPluginNamesTruncated"] = truncated;
        output["note"] = "Forced plugin names and native dialog observations only. A returned reload call or an absent crash dialog does not verify script execution, source version, or readiness.";
        return output;
    }

    Json::Value@ EditorScriptPluginsError(const string &in message, const string &in code, Json::Value &in output) {
        auto error = MakeError(message, code);
        error["output"] = output;
        return error;
    }

    Json::Value@ ControlEditorScriptPlugins(Json::Value &in input) {
        if (input.GetType() != Json::Type::Object)
            return MakeError("input must be an object", "INVALID_INPUT");
        if (input.HasKey("action") && input["action"].GetType() != Json::Type::String)
            return MakeError("action must be status or reload", "INVALID_INPUT");
        string action = input.HasKey("action") ? string(input["action"]) : "status";
        if (action != "status" && action != "reload")
            return MakeError("action must be status or reload", "INVALID_INPUT");
        if (input.HasKey("confirm") && input["confirm"].GetType() != Json::Type::Boolean)
            return MakeError("confirm must be a boolean", "INVALID_INPUT");
        if (action == "reload" && (!input.HasKey("confirm") || !bool(input["confirm"])))
            return MakeError("reload requires confirm:true", "CONFIRMATION_REQUIRED");

        auto editor = GetEditor();
        auto before = EditorScriptPluginsSnapshot(editor);
        before["action"] = action;
        if (action == "status") return MakeSuccess(before);
        if (DetectGameModeName() != "MapEditor")
            return EditorScriptPluginsError("idle map editor required", "EDITOR_BUSY", before);
        if (editor is null)
            return EditorScriptPluginsError("map editor not available", "NO_EDITOR", before);
        if (!bool(before["mapAvailable"]))
            return EditorScriptPluginsError("map not available", "NO_MAP", before);
        if (bool(before["loading"]) || bool(before["calculatingShadows"]))
            return EditorScriptPluginsError("loading or shadow computation observed; reload refused", "EDITOR_BUSY", before);
        if (bool(before["crashDialogDetected"]))
            return EditorScriptPluginsError("script crash dialog observed; preserve diagnostics before recovery", "MANIASCRIPT_CRASH", before);

        // No yield occurs between these guards and the single native call.
        auto retained = EditorScriptPluginMapLease(GetChallenge());
        before["reloadInvoked"] = true;
        try {
            editor.ReloadPlugins();
            before["reloadReturned"] = true;
            @editor = null;
            yield();

            // Never read an editor or its plugin buffers retained across a yield.
            @editor = GetEditor();
            auto after = EditorScriptPluginsSnapshot(editor);
            after["action"] = action;
            after["reloadInvoked"] = true;
            after["reloadReturned"] = true;
            bool sameMap = GetChallenge() is retained.map;
            after["mapIdentityMatches"] = sameMap;
            // Release explicitly: script-class destruction may wait for GC.
            retained.Release();
            if (!sameMap || editor is null)
                return EditorScriptPluginsError("editor or map context changed after reload; outcome unverified", "CONTEXT_CHANGED", after);
            if (bool(after["loading"]) || bool(after["calculatingShadows"]) || bool(after["crashDialogDetected"]))
                return EditorScriptPluginsError("busy state or script crash observed after reload; outcome unverified", "RELOAD_UNVERIFIED", after);
            return MakeSuccess(after);
        } catch {
            retained.Release();
            return EditorScriptPluginsError("reload or post-call observation raised an exception; outcome unverified", "RELOAD_UNVERIFIED", before);
        }
    }
}
