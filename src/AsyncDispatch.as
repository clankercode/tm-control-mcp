// Shared async dispatch infrastructure (issue #3).
// This file is compiled into BOTH this module and dependent modules.
// It must NOT reference non-shared symbols (CallTool, IsToolName, etc.)
// — only self-contained types and helpers. Pattern mirrors tm-mcptm's
// McpTM_Async.as.

namespace TmMcp {
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

    // Cleanup orphaned input stash entries (call on unload / periodic GC).
    void CleanupAsyncInputs() {
        auto keys = g_AsyncInputs.GetKeys();
        if (keys is null) return;
        for (uint i = 0; i < keys.Length; i++) {
            g_AsyncInputs.Delete(keys[i]);
        }
    }

    // Cleanup completed/errored pending requests older than maxAgeMs.
    void GC_PENDING(uint maxAgeMs = 300000) {
        auto keys = g_PendingRequests.GetKeys();
        if (keys is null) return;
        for (uint i = 0; i < keys.Length; i++) {
            string id = keys[i];
            AsyncToolResult@ tr = cast<AsyncToolResult@>(g_PendingRequests[id]);
            if (tr is null) {
                g_PendingRequests.Delete(id);
                continue;
            }
            if (tr.status != "pending" && uint(Time::Now - tr.startTime) > maxAgeMs) {
                g_PendingRequests.Delete(id);
            }
        }
    }
}
