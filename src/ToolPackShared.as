// Shared tool-pack types. Compiled into TmMcp and every dependent plugin.
// Must not touch non-shared host symbols (registry, CallTool, etc.).

namespace TmMcp {
    shared funcdef Json::Value@ ToolPackDispatch(const string &in name, Json::Value &in input);

    shared class ToolPackTool {
        string name;
        string description;
        string schemaJson;

        ToolPackTool() {}
    }

    shared class ToolPackBuilder {
        string packId;
        array<ToolPackTool@> tools;
        ToolPackDispatch@ dispatch;

        ToolPackBuilder() {}
        ToolPackBuilder(const string &in id) { packId = id; }

        // Public MCP prefix (packId.FuncName). Empty = Openplanet plugin id.
        ToolPackBuilder@ SetPackId(const string &in id) {
            packId = id;
            return this;
        }

        ToolPackBuilder@ AddTool(const string &in name, const string &in description, const string &in schemaJson) {
            auto t = ToolPackTool();
            t.name = name;
            t.description = description;
            t.schemaJson = schemaJson;
            tools.InsertLast(t);
            return this;
        }

        ToolPackBuilder@ SetDispatch(ToolPackDispatch@ fn) {
            @dispatch = fn;
            return this;
        }
    }
}
