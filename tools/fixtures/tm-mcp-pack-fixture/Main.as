// In-repo fixture pack: Ping, Echo, GetMode (wraps TmMcp::CallTool).

string g_PackId = "";

Json::Value@ Ok(Json::Value@ output) {
    Json::Value r = Json::Object();
    r["success"] = true;
    r["output"] = output;
    return r;
}

Json::Value@ Err(const string &in msg) {
    Json::Value r = Json::Object();
    r["success"] = false;
    r["error"] = msg;
    return r;
}

Json::Value@ FixtureDispatch(const string &in name, Json::Value &in input) {
    if (name == "Ping") {
        auto o = Json::Object();
        o["pong"] = true;
        return Ok(o);
    }
    if (name == "Echo") {
        string text = input.HasKey("text") ? string(input["text"]) : "";
        auto o = Json::Object();
        o["text"] = text;
        return Ok(o);
    }
    if (name == "GetMode") {
        Json::Value empty = Json::Object();
        return TmMcp::CallTool("GetMode", empty);
    }
    return Err("unknown fixture tool: " + name);
}

void RegisterFixturePack() {
    auto plugin = Meta::ExecutingPlugin();
    if (plugin is null) {
        warn("tm-mcp-pack-fixture: no executing plugin");
        return;
    }
    g_PackId = plugin.ID;
    auto b = TmMcp::ToolPackBuilder();
    b.AddTool("Ping", "Fixture ping. Returns {pong:true}.", '{"type":"object","properties":{},"additionalProperties":false}');
    b.AddTool("Echo", "Fixture echo. input: {text}.", '{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}');
    b.AddTool("GetMode", "Wraps TmMcp::CallTool(\"GetMode\").", '{"type":"object","properties":{},"additionalProperties":false}');
    b.SetDispatch(FixtureDispatch);
    auto r = TmMcp::RegisterToolPack(b);
    if (r is null || !r.HasKey("success") || !bool(r["success"])) {
        string err = (r !is null && r.HasKey("error")) ? string(r["error"]) : "null result";
        warn("tm-mcp-pack-fixture register failed: " + err);
        return;
    }
    print("tm-mcp-pack-fixture registered pack=" + g_PackId);
}

void UnregisterFixturePack() {
    if (g_PackId.Length == 0) return;
    TmMcp::UnregisterToolPack(g_PackId);
    g_PackId = "";
}

void Main() {
    RegisterFixturePack();
}

void OnEnabled() {
    RegisterFixturePack();
}

void OnDisabled() {
    UnregisterFixturePack();
}

void OnDestroyed() {
    UnregisterFixturePack();
}
