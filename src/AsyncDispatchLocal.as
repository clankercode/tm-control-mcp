// Non-shared async dispatch + coroutine (issue #3).
// This file is NOT in shared_exports — it references CallTool/IsToolName
// which are only available within the TmMcp module.

// Global-scope coroutine for startnew (AngelScript startnew requires global scope).
// Bridges into the namespace-scoped async dispatch.
void TmMcp_AsyncToolCoroutine(const string &in payload) {
    TmMcp::AsyncToolCoroutineImpl(payload);
}

namespace TmMcp {
    // Non-blocking dispatch: starts a coroutine that runs the tool and stores
    // the result in g_PendingRequests. Returns {request_id, status:"pending"}.
    Json::Value@ DispatchAsync(const string &in toolName, Json::Value@ input) {
        if (!IsToolName(toolName)) {
            return MakeError("unknown tool: " + toolName, "unknown_tool", false, "", "");
        }
        if (input is null) {
            @input = Json::Object();
        }
        string reqId = GenRequestId();
        AsyncToolResult@ tr = AsyncToolResult(reqId);
        RegisterPending(reqId, tr);

        // Stash input for the coroutine (startnew only passes a string)
        @g_AsyncInputs[reqId] = @input;
        string payload = toolName + "\t" + reqId;
        startnew(TmMcp_AsyncToolCoroutine, payload);

        Json::Value ret = Json::Object();
        ret["request_id"] = reqId;
        ret["status"] = "pending";
        return ret;
    }

    // Poll for async result. input: {requestId: "..."}.
    // Returns {request_id, status:"pending"|"done"|"error", result?/error?}.
    Json::Value@ GetResult(Json::Value &in input) {
        string reqId = input.HasKey("requestId") ? string(input["requestId"]) : "";
        if (reqId.Length == 0 && input.HasKey("request_id")) reqId = string(input["request_id"]);
        Json::Value result;
        if (GetPendingResult(reqId, result)) return result;

        Json::Value ret = Json::Object();
        ret["request_id"] = reqId;
        ret["status"] = "pending";
        return ret;
    }

    // Namespace-scoped coroutine implementation (called from global wrapper).
    void AsyncToolCoroutineImpl(const string &in payload) {
        string[] parts = payload.Split("\t");
        string toolName = parts.Length > 0 ? parts[0] : "";
        string reqId = parts.Length > 1 ? parts[1] : "";

        Json::Value@ input = null;
        if (g_AsyncInputs.Exists(reqId)) {
            @input = cast<Json::Value@>(g_AsyncInputs[reqId]);
            g_AsyncInputs.Delete(reqId);
        }
        if (input is null) @input = Json::Object();

        Json::Value@ result = CallTool(toolName, input);
        if (result is null) {
            SetAsyncResultError(reqId, "tool returned null: " + toolName);
        } else if (!result.HasKey("success") || !bool(result["success"])) {
            // Tool returned an error (or unexpected shape) — preserve full result
            AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[reqId]);
            if (tr !is null) {
                tr.status = "error";
                @tr.error = result;
            }
        } else {
            SetAsyncResultDone(reqId, result);
        }
    }
}
