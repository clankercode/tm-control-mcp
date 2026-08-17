// Host-side tool pack registry. Not shared — lives only in TmMcp.

namespace TmMcp {
    class RegisteredPack {
        string packId;
        string pluginId;
        array<string> toolNames;
        array<string> descriptions;
        array<Json::Value@> schemas;
        ToolPackDispatch@ dispatch;

        RegisteredPack() {}
    }

    array<RegisteredPack@> g_Packs;
    array<string> g_CallStack;

    bool IsReservedPackId(const string &in id) {
        return id == "core" || id == "tm-control-mcp" || id == "TmMcp";
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
        trace("TM Control MCP pack dropped " + pack.packId);
        g_Packs.RemoveAt(i);
        InvalidateToolList();
    }

    void SweepDeadPacks() {
        for (int i = int(g_Packs.Length) - 1; i >= 0; i--) {
            auto p = Meta::GetPluginFromID(g_Packs[i].pluginId);
            if (p is null || !p.Enabled) {
                DropPackAt(uint(i));
            }
        }
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

    Json::Value@ RegisterToolPack(ToolPackBuilder@ builder) {
        SweepDeadPacks();
        auto plugin = Meta::ExecutingPlugin();
        if (plugin is null) {
            return MakeError("RegisterToolPack: no executing plugin", "pack_no_plugin", false);
        }
        string packId = plugin.ID;
        if (IsReservedPackId(packId)) {
            return MakeError("packId '" + packId + "' is reserved", "pack_reserved_id", false);
        }
        if (FindPackIndex(packId) >= 0) {
            return MakeError("pack '" + packId + "' is already registered; UnregisterToolPack first", "pack_already_registered", false);
        }
        if (builder is null) {
            return MakeError("RegisterToolPack: builder is null", "pack_null_builder", false);
        }
        if (builder.dispatch is null) {
            return MakeError("RegisterToolPack: dispatch is null", "pack_null_dispatch", false);
        }
        if (builder.tools.Length == 0) {
            return MakeError("RegisterToolPack: no tools", "pack_empty", false);
        }

        auto pack = RegisteredPack();
        pack.packId = packId;
        pack.pluginId = plugin.ID;
        @pack.dispatch = builder.dispatch;

        for (uint i = 0; i < builder.tools.Length; i++) {
            auto t = builder.tools[i];
            if (t is null || t.name.Length == 0) {
                return MakeError("RegisterToolPack: tool " + i + " has empty name", "pack_bad_tool", false);
            }
            if (t.name.IndexOf(".") >= 0) {
                return MakeError("tool name must not contain '.': " + t.name, "pack_bad_tool_name", false);
            }
            for (uint d = 0; d < pack.toolNames.Length; d++) {
                if (pack.toolNames[d] == t.name) {
                    return MakeError("duplicate tool name in pack: " + t.name, "pack_dup_tool", false);
                }
            }
            string prefixed = packId + "." + t.name;
            if (FindSchema(prefixed) >= 0 || IsPackToolName(prefixed)) {
                return MakeError("tool already registered: " + prefixed, "pack_tool_collision", false);
            }
            Json::Value@ schema = null;
            if (t.schemaJson.Length > 0) {
                try {
                    @schema = Json::Parse(t.schemaJson);
                } catch {
                    return MakeError("invalid schema JSON for " + prefixed + ": " + getExceptionInfo(), "pack_bad_schema", false);
                }
            }
            if (schema is null || schema.GetType() != Json::Type::Object) {
                return MakeError("schema for " + prefixed + " must be a JSON object", "pack_bad_schema", false);
            }
            pack.toolNames.InsertLast(t.name);
            pack.descriptions.InsertLast(t.description);
            pack.schemas.InsertLast(schema);
        }

        for (uint i = 0; i < pack.toolNames.Length; i++) {
            string err = "";
            if (!RegisterToolSchema(packId + "." + pack.toolNames[i], pack.schemas[i], err)) {
                for (uint j = 0; j < i; j++) {
                    UnregisterToolSchema(packId + "." + pack.toolNames[j]);
                }
                return MakeError("schema register failed for " + pack.toolNames[i] + ": " + err, "pack_schema_register", false);
            }
        }

        g_Packs.InsertLast(pack);
        InvalidateToolList();
        trace("TM Control MCP pack registered " + packId + " tools=" + pack.toolNames.Length);
        auto output = Json::Object();
        output["pack"] = packId;
        output["plugin"] = plugin.ID;
        output["toolCount"] = int(pack.toolNames.Length);
        return MakeSuccess(output);
    }

    Json::Value@ UnregisterToolPack(const string &in packId) {
        SweepDeadPacks();
        int idx = FindPackIndex(packId);
        if (idx < 0) {
            return MakeError("pack not registered: " + packId, "pack_not_found", false);
        }
        auto caller = Meta::ExecutingPlugin();
        auto self = SelfPlugin();
        bool host = self !is null && caller !is null && caller.ID == self.ID;
        bool owner = caller !is null && caller.ID == g_Packs[uint(idx)].pluginId;
        if (!host && !owner) {
            return MakeError("only the owning plugin can unregister pack " + packId, "pack_not_owner", false);
        }
        DropPackAt(uint(idx));
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
        if (pack.dispatch is null) {
            return MakeError("pack '" + packId + "' has no dispatch", "pack_null_dispatch", false);
        }
        uint started = Time::Now;
        trace("TM Control MCP pack start " + name);
        Json::Value@ result = null;
        try {
            @result = pack.dispatch(local, input);
        } catch {
            @result = MakeError("pack tool threw: " + getExceptionInfo(), "pack_exception", true);
        }
        string status = "err";
        if (result !is null && result.HasKey("success") && bool(result["success"])) status = "ok";
        trace("TM Control MCP pack done " + name + " " + status + " " + (Time::Now - started) + "ms");
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
            o["toolCount"] = int(pack.toolNames.Length);
            auto p = Meta::GetPluginFromID(pack.pluginId);
            o["enabled"] = p !is null && p.Enabled;
            packs.Add(o);
        }
        auto output = Json::Object();
        output["packs"] = packs;
        output["count"] = int(g_Packs.Length);
        return MakeSuccess(output);
    }

    bool PushCallStack(const string &in name) {
        for (uint i = 0; i < g_CallStack.Length; i++) {
            if (g_CallStack[i] == name) return false;
        }
        g_CallStack.InsertLast(name);
        return true;
    }

    void PopCallStack() {
        if (g_CallStack.Length > 0) g_CallStack.RemoveLast();
    }
}
