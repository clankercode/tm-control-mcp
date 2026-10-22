namespace TmMcp {
    // Bounded top-level validation shared by socket, direct and async calls.
    // The MCP adapter remains responsible for complete Draft 2020-12 validation.
    const uint TOOL_SCHEMA_MAX_KEYS = 512;
    const uint TOOL_INPUT_MAX_KEYS = 1024;
    const uint TOOL_SCHEMA_MAX_UNION = 8;
    class ToolSchema {
        string toolName;
        array<string> allowedKeys;
        array<string> allowedKeyTypes;
        array<string> requiredKeys;
        bool rejectAdditionalProperties = false;
        string additionalTypes;
    }
    array<string> g_schemaToolNames;
    array<ToolSchema@> g_schemaRecords;

    int FindSchema(const string &in toolName) {
        return g_schemaToolNames.Find(toolName);
    }

    void InitToolSchemas() {
        auto tools = GetToolList();
        if (tools is null || tools.GetType() != Json::Type::Array) return;
        array<string> names;
        array<ToolSchema@> records;
        for (uint i = 0; i < tools.Length; i++) {
            auto entry = tools[i];
            if (entry is null || !entry.HasKey("name") || !entry.HasKey("input_schema")) continue;
            string err;
            auto rec = BuildToolSchemaRecord(string(entry["name"]), entry["input_schema"], err);
            if (rec is null) {
                warn("TM Control MCP: invalid builtin schema: " + err);
                return; // Never publish partially initialized validation.
            }
            names.InsertLast(rec.toolName); records.InsertLast(rec);
        }
        g_schemaToolNames = names; g_schemaRecords = records;
        trace("TM Control MCP: InitToolSchemas loaded " + g_schemaToolNames.Length + " tool schemas");
    }

    bool IsSchemaTypeName(const string &in name) {
        return name == "string" || name == "integer" || name == "number"
            || name == "boolean" || name == "object" || name == "array" || name == "null";
    }

    bool ReadSchemaTypes(Json::Value@ schema, string &out types, string &out err) {
        types = "";
        if (schema is null || schema.GetType() != Json::Type::Object) {
            err = "property schemas must be objects"; return false;
        }
        if (!schema.HasKey("type")) return true;
        auto value = schema["type"];
        if (value.GetType() == Json::Type::String && IsSchemaTypeName(string(value))) {
            types = string(value); return true;
        }
        if (value.GetType() != Json::Type::Array || value.Length == 0 || value.Length > TOOL_SCHEMA_MAX_UNION) {
            err = "type must be a known type or a union of 1..8 known types"; return false;
        }
        for (uint i = 0; i < value.Length; i++) {
            if (value[i].GetType() != Json::Type::String || !IsSchemaTypeName(string(value[i]))) {
                err = "union contains an invalid type"; return false;
            }
            if (i > 0) types += "|";
            types += string(value[i]);
        }
        return true;
    }

    ToolSchema@ BuildToolSchemaRecord(const string &in toolName, Json::Value@ schema, string &out err) {
        err = "";
        if (schema is null || schema.GetType() != Json::Type::Object) {
            err = "schema must be a JSON object"; return null;
        }
        string rootTypes;
        if (!ReadSchemaTypes(schema, rootTypes, err)) return null;
        if (rootTypes.Length > 0 && rootTypes != "object") {
            err = "tool input schema type must be object"; return null;
        }
        auto rec = ToolSchema(); rec.toolName = toolName;
        if (schema.HasKey("properties")) {
            auto props = schema["properties"];
            if (props.GetType() != Json::Type::Object || props.GetKeys().Length > TOOL_SCHEMA_MAX_KEYS) {
                err = "properties must be an object with at most 512 keys"; return null;
            }
            auto keys = props.GetKeys();
            for (uint i = 0; i < keys.Length; i++) {
                string types;
                if (!ReadSchemaTypes(props[keys[i]], types, err)) return null;
                rec.allowedKeys.InsertLast(keys[i]); rec.allowedKeyTypes.InsertLast(types);
            }
        }
        if (schema.HasKey("required")) {
            auto required = schema["required"];
            if (required.GetType() != Json::Type::Array || required.Length > TOOL_SCHEMA_MAX_KEYS) {
                err = "required must be an array with at most 512 names"; return null;
            }
            for (uint i = 0; i < required.Length; i++) {
                if (required[i].GetType() != Json::Type::String) {
                    err = "required names must be strings"; return null;
                }
                rec.requiredKeys.InsertLast(string(required[i]));
            }
        }
        if (schema.HasKey("additionalProperties")) {
            auto extra = schema["additionalProperties"];
            if (extra.GetType() == Json::Type::Boolean) rec.rejectAdditionalProperties = !bool(extra);
            else if (!ReadSchemaTypes(extra, rec.additionalTypes, err)) return null;
        }
        return rec;
    }

    bool RegisterToolSchema(const string &in toolName, Json::Value@ schema, string &out err) {
        err = "";
        if (toolName.Length == 0 || FindSchema(toolName) >= 0) {
            err = "empty or duplicate tool name"; return false;
        }
        auto rec = BuildToolSchemaRecord(toolName, schema, err);
        if (rec is null) return false;
        g_schemaToolNames.InsertLast(toolName); g_schemaRecords.InsertLast(rec); return true;
    }

    void UnregisterToolSchema(const string &in toolName) {
        int idx = FindSchema(toolName);
        if (idx < 0) return;
        g_schemaToolNames.RemoveAt(uint(idx)); g_schemaRecords.RemoveAt(uint(idx));
    }

    bool JsonTypeMatches(Json::Value@ value, const string &in expected) {
        Json::Type actual = value is null ? Json::Type::Null : value.GetType();
        if (expected == "null") return actual == Json::Type::Null;
        if (expected == "string") return actual == Json::Type::String;
        if (expected == "integer") {
            if (actual != Json::Type::Number) return false;
            double number = double(value); return number == Math::Floor(number);
        }
        if (expected == "number") return actual == Json::Type::Number;
        if (expected == "boolean") return actual == Json::Type::Boolean;
        if (expected == "object") return actual == Json::Type::Object;
        if (expected == "array") return actual == Json::Type::Array;
        return false;
    }

    string ValidateToolInput(const string &in toolName, Json::Value@ input) {
        if (input is null || input.GetType() != Json::Type::Object) return "input must be a JSON object";
        auto inputKeys = input.GetKeys();
        if (inputKeys.Length > TOOL_INPUT_MAX_KEYS) return "input exceeds 1024 top-level keys";
        int idx = FindSchema(toolName);
        if (idx < 0) return ""; // Unknown names are rejected by dispatch.
        auto rec = g_schemaRecords[uint(idx)];
        for (uint i = 0; i < rec.requiredKeys.Length; i++) {
            if (!input.HasKey(rec.requiredKeys[i])) return "missing required parameter '" + rec.requiredKeys[i] + "'";
        }
        for (uint i = 0; i < inputKeys.Length; i++) {
            string key = inputKeys[i];
            int propertyIndex = rec.allowedKeys.Find(key);
            if (propertyIndex < 0 && rec.rejectAdditionalProperties) return "unknown parameter '" + key + "'";
            string types = propertyIndex < 0 ? rec.additionalTypes : rec.allowedKeyTypes[uint(propertyIndex)];
            if (types.Length == 0) continue;
            auto unionTypes = types.Split("|");
            bool matched = false;
            for (uint t = 0; t < unionTypes.Length; t++) {
                if (JsonTypeMatches(input[key], unionTypes[t])) { matched = true; break; }
            }
            if (!matched) return "parameter '" + key + "' must be " + types + ", got " + JsonTypeName(input[key].GetType());
        }
        return "";
    }

    string JsonTypeName(Json::Type t) {
        if (t == Json::Type::Null) return "null";
        if (t == Json::Type::Boolean) return "boolean";
        if (t == Json::Type::Number) return "number";
        if (t == Json::Type::String) return "string";
        if (t == Json::Type::Array) return "array";
        if (t == Json::Type::Object) return "object";
        return "unknown";
    }
}
