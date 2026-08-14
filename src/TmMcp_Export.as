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

    // Async dispatch (issue #3) — non-blocking + poll.
    import Json::Value@ DispatchAsync(const string &in tool, Json::Value@ input) from "TmMcp";
    import Json::Value@ GetResult(Json::Value &in input) from "TmMcp";
}
