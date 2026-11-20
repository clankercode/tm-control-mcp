// Windowless sample: load-time log markers and the optional tool are its demo.
void Main() {
#if DEV
    TestKit::RunSelfChecks("testkit-sample");
#if DEPENDENCY_TM_CONTROL_MCP
    RegisterTestKitPack();
#endif
#endif
}

#if DEV && DEPENDENCY_TM_CONTROL_MCP
string g_TestKitPack = "";

Json::Value@ TestKitDispatch(const string &in name, Json::Value &in input) {
    auto result = Json::Object();
    if (name != "RunSelfChecks") {
        result["success"] = false;
        result["error"] = "unknown TestKit tool: " + name;
        return result;
    }
    // A completed suite is a successful tool call even if assertions failed.
    result["success"] = true;
    // Direct dispatch executes as tm-control-mcp, unlike load-time Main().
    // Pure/local tests only: storage, hooks, allocations and coroutines can be
    // attributed to the bridge. Inline startnew is not a proven ownership switch.
    result["output"] = TestKit::RunSelfChecks("testkit-sample");
    return result;
}

void RegisterTestKitPack() {
    if (g_TestKitPack.Length > 0) return;
    auto builder = TmMcp::ToolPackBuilder("testkit");
    builder.AddTool("RunSelfChecks", "Run the DEV TestKit sample; returns test counts and failure text.",
        '{"type":"object","properties":{},"additionalProperties":false}');
    builder.SetDispatch(TestKitDispatch);
    auto result = TmMcp::RegisterToolPack(builder);
    if (result !is null && bool(result["success"])) {
        g_TestKitPack = string(result["output"]["pack"]);
    } else {
        warn("TestKit sample: tool-pack registration failed: " + Json::Write(result));
    }
    // No release URL: this is an unpublished copyable fixture, not an updater.
}
void UnregisterTestKitPack() {
    if (g_TestKitPack.Length == 0) return;
    TmMcp::UnregisterToolPack(g_TestKitPack);
    g_TestKitPack = "";
}
void OnEnabled() { RegisterTestKitPack(); }
void OnDisabled() { UnregisterTestKitPack(); }
void OnDestroyed() { UnregisterTestKitPack(); }
#endif
