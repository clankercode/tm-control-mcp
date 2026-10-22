// Host-side tool pack registry. Not shared — lives only in TmMcp.

namespace TmMcp {
    class RegisteredPack {
        string packId;
        string pluginId;
        string latestReleaseUrl;
        array<string> toolNames;
        array<string> descriptions;
        array<Json::Value@> schemas;
        ToolPackDispatch@ dispatch;
        string generation;
        array<Json::Value@> metadata;
        bool retired = false;
        uint running = 0;

        RegisteredPack() {}
    }

    array<RegisteredPack@> g_Packs;
    array<RegisteredPack@> g_RetiredPacks;
    uint64 g_NextPackGeneration = 0;

    bool IsReservedPackId(const string &in id) {
        return id == "core" || id == "tm-control-mcp" || id == "TmMcp";
    }

    bool IsValidPackIdCharset(const string &in id) {
        if (id.Length == 0 || id.Length > 64) return false;
        string letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        string restOk = letters + "0123456789_-";
        if (letters.IndexOf(id.SubStr(0, 1)) < 0) return false;
        for (uint i = 1; i < id.Length; i++) {
            if (restOk.IndexOf(id.SubStr(i, 1)) < 0) return false;
        }
        return true;
    }

    int FindPackIndex(const string &in packId) {
        for (uint i = 0; i < g_Packs.Length; i++) {
            if (g_Packs[i].packId == packId) return int(i);
        }
        return -1;
    }

    bool SplitPackToolName(const string &in name, string &out packId, string &out local) {
        int dot = name.IndexOf(".");
        if (dot <= 0 || uint(dot) + 1 >= name.Length) return false;
        packId = name.SubStr(0, uint(dot));
        local = name.SubStr(uint(dot) + 1);
        if (packId.Length == 0 || local.Length == 0 || local.IndexOf(".") >= 0) return false;
        return true;
    }

    void DropPackAt(uint i) {
        auto pack = g_Packs[i];
        for (uint t = 0; t < pack.toolNames.Length; t++) {
            UnregisterToolSchema(pack.packId + "." + pack.toolNames[t]);
        }
        pack.retired = true;
        if (pack.running > 0) g_RetiredPacks.InsertLast(pack);
        trace("TM Control MCP pack dropped " + pack.packId);
        g_Packs.RemoveAt(i);
    }

    void SweepDeadPacks() {
        for (int i = int(g_RetiredPacks.Length) - 1; i >= 0; i--) {
            auto pack = g_RetiredPacks[uint(i)];
            if (!IsPackGenerationRunning(pack.generation)) g_RetiredPacks.RemoveAt(uint(i));
        }
        bool changed = false;
        for (int i = int(g_Packs.Length) - 1; i >= 0; i--) {
            auto p = Meta::GetPluginFromID(g_Packs[i].pluginId);
            if (p is null || !p.Enabled) {
                DropPackAt(uint(i));
                changed = true;
            }
        }
        if (changed) InvalidateToolList();
    }

    bool IsPackToolName(const string &in name) {
        SweepDeadPacks();
        string packId;
        string local;
        if (!SplitPackToolName(name, packId, local)) return false;
        int idx = FindPackIndex(packId);
        if (idx < 0) return false;
        auto pack = g_Packs[uint(idx)];
        for (uint i = 0; i < pack.toolNames.Length; i++) {
            if (pack.toolNames[i] == local) return true;
        }
        return false;
    }

    bool GetPackToolGeneration(const string &in name, string &out generation) {
        generation = "";
        string packId;
        string local;
        if (!SplitPackToolName(name, packId, local)) return false;
        int idx = FindPackIndex(packId);
        if (idx < 0) return false;
        auto pack = g_Packs[uint(idx)];
        for (uint i = 0; i < pack.toolNames.Length; i++) {
            if (pack.toolNames[i] == local) {
                generation = pack.generation;
                return generation.Length > 0;
            }
        }
        return false;
    }

    bool IsValidPublicToolName(const string &in name) {
        if (name.Length == 0 || name.Length > 128) return false;
        string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
        string packId, local;
        if (!SplitPackToolName(name, packId, local)) return false;
        for (uint i = 0; i < uint(name.Length); i++) {
            if (name[i] == 46) continue;
            if (allowed.IndexOf(name.SubStr(i, 1)) < 0) return false;
        }
        return true;
    }

    bool ValidateToolMetadata(Json::Value@ supplied, string &out err) {
        err = "";
        if (supplied is null || supplied.GetType() != Json::Type::Object) {
            err = "tool metadata must be an object"; return false;
        }
        auto keys = supplied.GetKeys();
        for (uint i = 0; i < keys.Length; i++) {
            string key = keys[i];
            if (key != "annotations" && key != "output_schema") {
                err = "metadata supports annotations/output_schema objects"; return false;
            }
            if (supplied[key].GetType() != Json::Type::Object) {
                err = key + " must be an object"; return false;
            }
        }
        if (supplied.HasKey("annotations")) {
            auto annotations = supplied["annotations"];
            auto annotationKeys = annotations.GetKeys();
            for (uint i = 0; i < annotationKeys.Length; i++) {
                string key = annotationKeys[i];
                if (key != "title" && key != "readOnlyHint" && key != "destructiveHint"
                    && key != "idempotentHint" && key != "openWorldHint") {
                    err = "unknown tool annotation: " + key; return false;
                }
                auto value = annotations[key];
                if (key == "title") {
                    if (value.GetType() != Json::Type::String || string(value).Length > 256) {
                        err = "annotation title must be a string of at most 256 characters"; return false;
                    }
                } else if (value.GetType() != Json::Type::Boolean) {
                    err = "boolean tool annotations must be boolean"; return false;
                }
            }
        }
        if (supplied.HasKey("output_schema") && Json::Write(supplied["output_schema"]).Length > 262144) {
            err = "output_schema exceeds 256 KiB"; return false;
        }
        return true;
    }

    Json::Value@ RegisterToolPack(ToolPackBuilder@ builder) {
        auto options = Json::Object();
        return RegisterToolPackEx(builder, options);
    }

    // Ordinary export: metadata/CAS options do not change the shared builder.
    // options: {replace:false, expectedGeneration:"...", tools:{LocalName:{annotations:{}, output_schema:{}}}}
    Json::Value@ RegisterToolPackEx(ToolPackBuilder@ builder, Json::Value &in options) {
        SweepDeadPacks();
        auto plugin = Meta::ExecutingPlugin();
        if (plugin is null) return MakeError("RegisterToolPack: no executing plugin", "pack_no_plugin");
        if (builder is null) return MakeError("RegisterToolPack: builder is null", "pack_null_builder");
        if (options.GetType() != Json::Type::Object) return MakeError("options must be an object", "pack_bad_options");
        auto optionKeys = options.GetKeys();
        for (uint i = 0; i < optionKeys.Length; i++) {
            if (optionKeys[i] != "replace" && optionKeys[i] != "expectedGeneration" && optionKeys[i] != "tools")
                return MakeError("unknown registration option", "pack_bad_options");
        }
        if (options.HasKey("replace") && options["replace"].GetType() != Json::Type::Boolean)
            return MakeError("replace must be boolean", "pack_bad_options");
        if (options.HasKey("expectedGeneration") && options["expectedGeneration"].GetType() != Json::Type::String)
            return MakeError("expectedGeneration must be string", "pack_bad_options");
        if (options.HasKey("tools") && options["tools"].GetType() != Json::Type::Object)
            return MakeError("tools metadata must be an object", "pack_bad_options");
        if (Json::Write(options).Length > 1048576) return MakeError("registration metadata exceeds 1 MiB", "pack_bad_options");
        bool replace = options.HasKey("replace") && bool(options["replace"]);
        string expected = options.HasKey("expectedGeneration") ? string(options["expectedGeneration"]) : "";
        string customId = builder.packId.Trim();
        string packId = customId.Length > 0 ? customId : plugin.ID;
        if (customId.Length > 0 && !IsValidPackIdCharset(packId)) return MakeError("invalid packId", "pack_bad_id");
        if (packId.Length == 0 || packId.IndexOf(".") >= 0) return MakeError("invalid packId", "pack_bad_id");
        if (IsReservedPackId(packId)) return MakeError("reserved packId", "pack_reserved_id");
        int existingIndex = FindPackIndex(packId);
        for (uint i = 0; i < g_RetiredPacks.Length; i++) {
            if (g_RetiredPacks[i].packId == packId)
                return MakeError("retired pack generation is still running", "pack_busy", true);
        }
        RegisteredPack@ existing = existingIndex < 0 ? null : g_Packs[uint(existingIndex)];
        if (existing !is null) {
            if (!replace) return MakeError("pack already registered; use owner replacement with expectedGeneration", "pack_already_registered");
            if (existing.pluginId != plugin.ID) return MakeError("only the owner can replace a pack", "pack_not_owner");
            if (expected.Length == 0 || expected != existing.generation) return MakeError("pack generation is stale", "stale_generation");
            if (existing.running > 0 && IsPackGenerationRunning(existing.generation))
                return MakeError("pack generation is still running", "pack_busy", true);
        } else if (replace || expected.Length > 0) return MakeError("replacement pack is no longer registered", "stale_generation");
        if (builder.dispatch is null) return MakeError("dispatch is null", "pack_null_dispatch");
        if (builder.tools.Length == 0 || builder.tools.Length > 512) return MakeError("pack needs 1..512 tools", "pack_empty");

        auto pack = RegisteredPack();
        pack.packId = packId; pack.pluginId = plugin.ID;
        pack.latestReleaseUrl = builder.latestReleaseUrl.Trim().SubStr(0, UPDATE_URL_LIMIT + 1);
        @pack.dispatch = builder.dispatch;
        array<ToolSchema@> records;
        for (uint i = 0; i < builder.tools.Length; i++) {
            auto t = builder.tools[i];
            if (t is null || t.name.Length == 0) return MakeError("empty tool name", "pack_bad_tool");
            string prefixed = packId + "." + t.name;
            if (!IsValidPublicToolName(prefixed)) return MakeError("invalid public tool name", "pack_bad_tool_name");
            if (pack.toolNames.Find(t.name) >= 0) return MakeError("duplicate tool name", "pack_dup_tool");
            if (FindSchema(prefixed) >= 0 && (existing is null || existing.toolNames.Find(t.name) < 0))
                return MakeError("tool already registered", "pack_tool_collision");
            Json::Value@ schema;
            try { @schema = Json::Parse(t.schemaJson); }
            catch { return MakeError("invalid schema JSON", "pack_bad_schema"); }
            string err;
            auto record = BuildToolSchemaRecord(prefixed, schema, err);
            if (record is null) return MakeError("invalid tool schema: " + err, "pack_bad_schema");
            auto meta = Json::Object();
            if (options.HasKey("tools") && options["tools"].HasKey(t.name)) {
                auto supplied = options["tools"][t.name];
                string metadataError;
                if (!ValidateToolMetadata(supplied, metadataError)) return MakeError(metadataError, "pack_bad_metadata");
                @meta = CloneJsonValue(supplied);
                if (meta is null) return MakeError("could not detach metadata", "pack_bad_metadata");
            }
            pack.toolNames.InsertLast(t.name); pack.descriptions.InsertLast(t.description);
            pack.schemas.InsertLast(schema); pack.metadata.InsertLast(meta); records.InsertLast(record);
        }
        if (options.HasKey("tools")) {
            auto keys = options["tools"].GetKeys();
            for (uint i = 0; i < keys.Length; i++) {
                if (pack.toolNames.Find(keys[i]) < 0) return MakeError("metadata names an unknown local tool", "pack_bad_metadata");
            }
        }
        // Prepare complete successor tables without touching the current tables.
        array<string> names;
        array<ToolSchema@> schemas;
        for (uint i = 0; i < g_schemaToolNames.Length; i++) {
            if (existing !is null && g_schemaToolNames[i].StartsWith(packId + ".")) continue;
            names.InsertLast(g_schemaToolNames[i]); schemas.InsertLast(g_schemaRecords[i]);
        }
        for (uint i = 0; i < records.Length; i++) {
            names.InsertLast(records[i].toolName); schemas.InsertLast(records[i]);
        }
        auto packs = g_Packs;
        if (existingIndex < 0) packs.InsertLast(pack);
        else @packs[uint(existingIndex)] = pack;
        pack.generation = "" + (g_NextPackGeneration + 1);
        // No yields/callbacks between CAS validation and publication.
        if (existing !is null) existing.retired = true;
        g_schemaToolNames = names; g_schemaRecords = schemas; g_Packs = packs;
        g_NextPackGeneration++;
        InvalidateToolList();
        string updateWarning = PackUpdateUrlError(pack.latestReleaseUrl);
        if (updateWarning.Length > 0) warn("TM Control MCP pack '" + packId + "': " + updateWarning);
        auto output = Json::Object();
        output["pack"] = packId; output["plugin"] = plugin.ID;
        output["generation"] = pack.generation; output["toolCount"] = int(pack.toolNames.Length);
        output["replaced"] = existing !is null;
        AppendPackUpdateStatus(output, pack.pluginId, pack.latestReleaseUrl);
        return MakeSuccess(output);
    }

    Json::Value@ UnregisterOwnedPacks(const string &in pluginId) {
        auto dropped = Json::Array();
        for (int i = int(g_Packs.Length) - 1; i >= 0; i--) {
            if (g_Packs[uint(i)].pluginId != pluginId) continue;
            dropped.Add(g_Packs[uint(i)].packId);
            DropPackAt(uint(i));
        }
        if (dropped.Length == 0) {
            return MakeError("pack not registered: " + pluginId, "pack_not_found", false);
        }
        InvalidateToolList();
        auto output = Json::Object();
        output["pack"] = pluginId;
        output["packs"] = dropped;
        output["unregistered"] = true;
        return MakeSuccess(output);
    }

    Json::Value@ UnregisterToolPack(const string &in packId) {
        SweepDeadPacks();
        auto caller = Meta::ExecutingPlugin();
        auto self = SelfPlugin();
        bool host = self !is null && caller !is null && caller.ID == self.ID;
        // A plugin ID is the explicit remove-all-owned form. Resolve it
        // before exact pack lookup so a custom prefix collision cannot make
        // cleanup depend on which interpretation happened to win first.
        if (caller !is null && packId == caller.ID) {
            return UnregisterOwnedPacks(caller.ID);
        }
        int idx = FindPackIndex(packId);
        if (idx < 0) {
            return MakeError("pack not registered: " + packId, "pack_not_found", false);
        }
        bool owner = caller !is null && caller.ID == g_Packs[uint(idx)].pluginId;
        if (!host && !owner) {
            return MakeError("only the owning plugin can unregister pack " + packId, "pack_not_owner", false);
        }
        DropPackAt(uint(idx));
        InvalidateToolList();
        auto output = Json::Object();
        output["pack"] = packId;
        output["unregistered"] = true;
        return MakeSuccess(output);
    }

    Json::Value@ DispatchPackTool(const string &in name, Json::Value &in input) {
        SweepDeadPacks();
        string packId;
        string local;
        if (!SplitPackToolName(name, packId, local)) return null;
        int idx = FindPackIndex(packId);
        if (idx < 0) return null;
        auto pack = g_Packs[uint(idx)];
        bool found = false;
        for (uint i = 0; i < pack.toolNames.Length; i++) {
            if (pack.toolNames[i] == local) { found = true; break; }
        }
        if (!found) return null;
        if (pack.retired) return MakeError("pack generation is retired", "stale_generation");
        if (pack.dispatch is null) {
            return MakeError("pack '" + packId + "' has no dispatch", "pack_null_dispatch", false);
        }
        // Disabled: these fire on every pack tool call and flood the Openplanet log.
        // uint started = Time::Now;
        // trace("TM Control MCP pack start " + name);
        Json::Value@ result = null;
        pack.running++;
        try {
            @result = pack.dispatch(local, input);
        } catch {
            @result = MakeError("pack tool threw: " + getExceptionInfo(), "pack_exception", true);
        }
        pack.running--;
        if (pack.retired) return MakeError("pack generation retired during dispatch", "stale_generation");
        // string status = "err";
        // if (result !is null && result.HasKey("success") && bool(result["success"])) status = "ok";
        // trace("TM Control MCP pack done " + name + " " + status + " " + (Time::Now - started) + "ms");
        if (result is null) {
            return MakeError("pack '" + packId + "' returned null for " + local, "pack_null_result", true);
        }
        return result;
    }

    void AppendPackTools(Json::Value@ tools) {
        SweepDeadPacks();
        if (tools is null) return;
        for (uint i = 0; i < g_Packs.Length; i++) {
            auto pack = g_Packs[i];
            for (uint t = 0; t < pack.toolNames.Length; t++) {
                Json::Value tool = Json::Object();
                tool["name"] = pack.packId + "." + pack.toolNames[t];
                tool["description"] = pack.descriptions[t];
                tool["input_schema"] = pack.schemas[t];
                tool["pack"] = pack.packId;
                if (t < pack.metadata.Length && pack.metadata[t] !is null) {
                    auto meta = pack.metadata[t];
                    if (meta.HasKey("annotations")) tool["annotations"] = meta["annotations"];
                    if (meta.HasKey("output_schema")) tool["output_schema"] = meta["output_schema"];
                }
                tools.Add(tool);
            }
        }
    }

    Json::Value@ ListToolPacks(Json::Value &in input) {
        SweepDeadPacks();
        auto packs = Json::Array();
        for (uint i = 0; i < g_Packs.Length; i++) {
            auto pack = g_Packs[i];
            auto o = Json::Object();
            o["id"] = pack.packId;
            o["plugin"] = pack.pluginId;
            o["generation"] = pack.generation;
            o["toolCount"] = int(pack.toolNames.Length);
            auto p = Meta::GetPluginFromID(pack.pluginId);
            o["enabled"] = p !is null && p.Enabled;
            AppendPackUpdateStatus(o, pack.pluginId, pack.latestReleaseUrl);
            packs.Add(o);
        }
        auto output = Json::Object();
        output["packs"] = packs;
        output["bridge"] = BridgeUpdateStatus();
        output["count"] = int(g_Packs.Length);
        return MakeSuccess(output);
    }

}
