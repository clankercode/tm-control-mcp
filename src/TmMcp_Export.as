// TmMcp_Export.as — in-process import surface (issue #1).
//
// Consumers (e.g. tm-agent) import from "TmMcp" to call tools directly
// without going through the TCP socket.
//
// NOTE: individual tool functions in tm-control-mcp use `Json::Value &in`
// signatures (not `Json::Value@`). AngelScript `import` requires matching
// signatures, so we export the dispatch utilities (CallTool/IsToolName)
// rather than individual tool functions. Consumers call tools by name:
//
//   Json::Value@ result = TmMcp::CallTool("PlaceBlock", input);
//
// For non-blocking dispatch, use DispatchAsync + GetResult (issue #3).
// Those live in AsyncDispatchLocal.as (NOT shared) but are still exported
// here for in-process consumers within the same compile dependency chain.

namespace TmMcp {
    // Core dispatch — call any tool by name.
    import Json::Value@ CallTool(const string &in name, Json::Value &in input) from "TmMcp";
    import bool IsToolName(const string &in name) from "TmMcp";

    // Tool registry — names, descriptions, and input schemas in Anthropic
    // tool format ({name, description, input_schema}). Lets in-process
    // consumers (tm-agent) forward the live registry instead of
    // maintaining a duplicate list that drifts.
    import Json::Value@ GetToolList() from "TmMcp";

    // Async dispatch (issue #3) — non-blocking + poll.
    import Json::Value@ DispatchAsync(const string &in tool, Json::Value@ input) from "TmMcp";
    import Json::Value@ GetResult(Json::Value &in input) from "TmMcp";

    // Socket lifecycle — no plugin reload required.
    import void SetSocketEnabled(bool enabled) from "TmMcp";
    import void StartSocket() from "TmMcp";
    import void StopSocket() from "TmMcp";
    import bool IsSocketEnabled() from "TmMcp";
    import bool IsSocketListening() from "TmMcp";
    import Json::Value@ GetSocketStatus() from "TmMcp";

    // Tool packs — other plugins register tools into this surface.
    import Json::Value@ RegisterToolPack(ToolPackBuilder@ builder) from "TmMcp";
    import Json::Value@ UnregisterToolPack(const string &in packId) from "TmMcp";
    import Json::Value@ ListToolPacks(Json::Value &in input) from "TmMcp";
}
