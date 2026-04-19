namespace TmMcp {
    Json::Value@ HandlePayload(const string &in payload) {
        if (payload.Length == 0) {
            return MakeResponse("", "", null, "empty request payload");
        }

        Json::Value@ request;
        try {
            @request = Json::Parse(payload);
        } catch {
            return MakeResponse("", "", null, "invalid JSON: " + getExceptionInfo());
        }

        if (request is null || request.GetType() != Json::Type::Object) {
            return MakeResponse("", "", null, "request must be a JSON object");
        }

        return HandleRequest(request);
    }

    Json::Value@ HandleRequest(Json::Value@ request) {
        string id = request.HasKey("id") ? string(request["id"]) : "";
        string route = request.HasKey("route") ? string(request["route"]) : "";
        if (route.Length == 0 && request.HasKey("tool")) route = "call";

        if (route == "status") {
            Json::Value data = Json::Object();
            data["alive"] = true;
            data["port"] = S_TmMcpPort;
            data["plugin"] = "TM Control MCP";
            data["version"] = "0.1.0";
            return MakeResponse(id, route, data, "");
        }

        if (route == "tools") {
            return MakeResponse(id, route, GetToolList(), "");
        }

        if (route == "call") {
            return HandleCall(id, route, request);
        }

        if (IsToolName(route)) {
            request["tool"] = route;
            return HandleCall(id, route, request);
        }

        return MakeResponse(id, route, null, "unknown route: " + route);
    }

    Json::Value@ HandleCall(const string &in id, const string &in route, Json::Value@ request) {
        string tool = request.HasKey("tool") ? string(request["tool"]) : "";
        if (tool.Length == 0) return MakeResponse(id, route, null, "missing tool");

        Json::Value input = Json::Object();
        if (request.HasKey("input")) {
            input = request["input"];
        } else if (request.HasKey("data")) {
            input = request["data"];
        }

        if (input.GetType() != Json::Type::Object) {
            return MakeResponse(id, route, null, "input must be a JSON object");
        }

        Json::Value@ result = CallTool(tool, input);
        if (result is null) {
            return MakeResponse(id, route, null, "unknown tool: " + tool);
        }

        Json::Value data = Json::Object();
        data["tool"] = tool;
        data["result"] = result;
        return MakeResponse(id, route, data, "");
    }

    Json::Value@ MakeResponse(
        const string &in id,
        const string &in route,
        Json::Value@ data,
        const string &in errorMessage
    ) {
        Json::Value response = Json::Object();
        response["ok"] = errorMessage.Length == 0;
        response["id"] = id.Length == 0 ? Json::Value() : Json::Value(id);
        response["route"] = route;
        response["error"] = errorMessage;
        response["data"] = data is null ? Json::Value() : data;
        return response;
    }
}
