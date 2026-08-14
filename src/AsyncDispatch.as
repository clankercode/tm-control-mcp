// Global-scope coroutine for startnew (AngelScript startnew requires global scope).
// Bridges into the namespace-scoped async dispatch.
void TmMcp_AsyncToolCoroutine(const string &in payload) {
    TmMcp::AsyncToolCoroutineImpl(payload);
}

namespace TmMcp {
    // Async dispatch infrastructure (issue #3).
    // Lets in-process callers dispatch tools non-blocking and poll for results,
    // mirroring tm-mcptm's GetResult(reqId) pattern.

    shared class AsyncToolResult {
        string requestId;
        string status;  // "pending" | "done" | "error"
        Json::Value@ result;
        Json::Value@ error;
        int64 startTime;

        AsyncToolResult(const string &in id) {
            requestId = id;
            status = "pending";
            startTime = Time::Now;
            @result = Json::Object();
            @error = Json::Value();
        }
    }

    dictionary@ g_PendingRequests = dictionary();
    dictionary@ g_AsyncInputs = dictionary();

    string GenRequestId() {
        return "req_" + Time::Now + "_" + Math::Rand(10000, 99999);
    }

    void RegisterPending(const string &in id, AsyncToolResult@ tr) {
        if (tr is null) return;
        @g_PendingRequests[id] = @tr;
    }

    bool GetPendingResult(const string &in id, Json::Value &out result) {
        if (!g_PendingRequests.Exists(id)) return false;
        AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[id]);
        if (tr is null) return false;
        if (tr.status == "pending") return false;
        result = Json::Object();
        result["request_id"] = tr.requestId;
        result["status"] = tr.status;
        if (tr.status == "done") {
            result["result"] = tr.result;
        } else {
            result["error"] = tr.error;
        }
        g_PendingRequests.Delete(id);
        return true;
    }

    bool IsPending(const string &in id) {
        if (!g_PendingRequests.Exists(id)) return false;
        AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[id]);
        if (tr is null) return false;
        return tr.status == "pending";
    }

    void SetAsyncResultDone(const string &in reqId, Json::Value@ result) {
        if (!g_PendingRequests.Exists(reqId)) return;
        AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[reqId]);
        if (tr is null) return;
        tr.status = "done";
        @tr.result = result;
    }

    void SetAsyncResultError(const string &in reqId, const string &in error) {
        if (!g_PendingRequests.Exists(reqId)) return;
        AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[reqId]);
        if (tr is null) return;
        tr.status = "error";
        Json::Value e = Json::Object();
        e["error"] = error;
        @tr.error = e;
    }

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
        } else if (!result.Get("success", false)) {
            // Tool returned an error — preserve the full result object
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
