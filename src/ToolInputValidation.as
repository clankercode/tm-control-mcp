namespace TmMcp {
    // Per-tool schema record (top-level properties only).
    class ToolSchema {
        string toolName;
        array<string> allowedKeys;
        array<string> allowedKeyTypes; // parallel to allowedKeys: type string per key
        array<string> requiredKeys;

        ToolSchema() {}
    }

    // Flat parallel arrays instead of dictionary (avoids 'set'/'get' reserved keyword issue).
    array<string>       g_schemaToolNames;
    array<ToolSchema@>  g_schemaRecords;

    int FindSchema(const string &in toolName) {
        for (uint i = 0; i < g_schemaToolNames.Length; i++) {
            if (g_schemaToolNames[i] == toolName) return int(i);
        }
        return -1;
    }

    // Called once at plugin startup. Parses GetToolList() schemas into the registry.
    void InitToolSchemas() {
        g_schemaToolNames.Resize(0);
        g_schemaRecords.Resize(0);

        Json::Value@ tools = GetToolList();
        if (tools is null || tools.GetType() != Json::Type::Array) return;

        uint count = tools.Length;
        for (uint i = 0; i < count; i++) {
            Json::Value@ entry = tools[i];
            if (entry is null || !entry.HasKey("name") || !entry.HasKey("input_schema")) continue;
            string toolName = string(entry["name"]);
            Json::Value@ schema = entry["input_schema"];
            if (schema is null || schema.GetType() != Json::Type::Object) continue;

            ToolSchema@ rec = ToolSchema();
            rec.toolName = toolName;

            // Parse properties.
            if (schema.HasKey("properties") && schema["properties"].GetType() == Json::Type::Object) {
                Json::Value@ props = schema["properties"];
                array<string> keys = props.GetKeys();
                for (uint k = 0; k < keys.Length; k++) {
                    string key = keys[k];
                    rec.allowedKeys.InsertLast(key);

                    // Extract type string from property definition.
                    string typeStr = "";
                    Json::Value@ propDef = props[key];
                    if (propDef !is null && propDef.GetType() == Json::Type::Object && propDef.HasKey("type")) {
                        Json::Value@ typeVal = propDef["type"];
                        if (typeVal !is null && typeVal.GetType() == Json::Type::String) {
                            typeStr = string(typeVal);
                        }
                        // Union types (e.g. ["string","integer"] in DevSafeRead.ptr) leave
                        // typeStr empty so the validator skips the type check for that key
                        // while still enforcing unknown-key / required-key rules.
                    }
                    rec.allowedKeyTypes.InsertLast(typeStr);
                }
            }

            // Parse required list.
            if (schema.HasKey("required") && schema["required"].GetType() == Json::Type::Array) {
                Json::Value@ req = schema["required"];
                uint reqLen = req.Length;
                for (uint r = 0; r < reqLen; r++) {
                    Json::Value@ rv = req[r];
                    if (rv !is null && rv.GetType() == Json::Type::String) {
                        rec.requiredKeys.InsertLast(string(rv));
                    }
                }
            }

            g_schemaToolNames.InsertLast(toolName);
            g_schemaRecords.InsertLast(rec);
        }
        trace("TM Control MCP: InitToolSchemas loaded " + g_schemaToolNames.Length + " tool schemas");
    }

    // Returns empty string on success, or an error description.
    // Only validates top-level input keys (not nested object sub-properties).
    string ValidateToolInput(const string &in toolName, Json::Value@ input) {
        int idx = FindSchema(toolName);
        if (idx < 0) {
            // Unknown tool — let dispatch emit the unknown-tool error.
            return "";
        }
        ToolSchema@ rec = g_schemaRecords[idx];

        // Check for unknown keys.
        array<string> inputKeys = input.GetKeys();
        for (uint i = 0; i < inputKeys.Length; i++) {
            string k = inputKeys[i];
            bool found = false;
            for (uint j = 0; j < rec.allowedKeys.Length; j++) {
                if (rec.allowedKeys[j] == k) { found = true; break; }
            }
            if (!found) {
                string allowed = "";
                for (uint j = 0; j < rec.allowedKeys.Length; j++) {
                    if (j > 0) allowed += ", ";
                    allowed += rec.allowedKeys[j];
                }
                if (allowed.Length == 0) allowed = "(none)";
                return "unknown parameter '" + k + "' (allowed: " + allowed + ")";
            }
        }

        // Check required keys are present.
        for (uint i = 0; i < rec.requiredKeys.Length; i++) {
            string k = rec.requiredKeys[i];
            if (!input.HasKey(k)) {
                return "missing required parameter '" + k + "'";
            }
        }

        // Check types of provided keys.
        for (uint i = 0; i < inputKeys.Length; i++) {
            string k = inputKeys[i];
            // Find the type string for this key.
            string typeStr = "";
            for (uint j = 0; j < rec.allowedKeys.Length; j++) {
                if (rec.allowedKeys[j] == k) { typeStr = rec.allowedKeyTypes[j]; break; }
            }
            if (typeStr.Length == 0) continue;

            Json::Value@ val = input[k];
            if (val is null) continue;
            Json::Type actualType = val.GetType();

            bool ok = false;
            if (typeStr == "string") {
                ok = (actualType == Json::Type::String);
            } else if (typeStr == "integer" || typeStr == "number") {
                // AS JSON parser doesn't distinguish int vs float; both come as Number.
                ok = (actualType == Json::Type::Number);
            } else if (typeStr == "boolean") {
                ok = (actualType == Json::Type::Boolean);
            } else if (typeStr == "object") {
                ok = (actualType == Json::Type::Object);
            } else if (typeStr == "array") {
                ok = (actualType == Json::Type::Array);
            } else {
                // Unknown type constraint — pass through.
                ok = true;
            }

            if (!ok) {
                string actualName = JsonTypeName(actualType);
                return "parameter '" + k + "' must be " + typeStr + ", got " + actualName;
            }
        }

        return "";
    }

    string JsonTypeName(Json::Type t) {
        if (t == Json::Type::Null)    return "null";
        if (t == Json::Type::Boolean) return "boolean";
        if (t == Json::Type::Number)  return "number";
        if (t == Json::Type::String)  return "string";
        if (t == Json::Type::Array)   return "array";
        if (t == Json::Type::Object)  return "object";
        return "unknown";
    }
}
