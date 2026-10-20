// Each dispatch runs in a worker owned by the bridge, even for imported
// CallTool. The monitor outlives socket callers and observes VM-aborted workers.
void TmMcp_RunToolCall(ref@ data) { TmMcp::RunToolCall(cast<TmMcp::ToolInvocation@>(data)); }
void TmMcp_MonitorToolCalls() { TmMcp::MonitorToolCalls(); }

namespace TmMcp {
    const uint MAX_TOOL_CALLS = 32;
    class CoroutineCallOwner : IToolCallOwner {
        awaitable@ worker;
        bool IsRunning() { return worker is null || worker.IsRunning(); }
    }
    class ToolInvocation : CallLease {
        Json::Value@ input;
        Json::Value@ result;
        string instance;
    }
    ToolCallRegistry g_ToolCalls;
    array<ToolInvocation@> g_UnfinishedWorkers;
    bool g_MonitorToolCalls = false;
    string g_ToolCallInstance = "";
    uint64 g_ToolCallsStarted = 0;

    void ToolCallEvent(const string &in message) {
        trace("TM Control MCP " + message);
        // Persist admissions, rejections and terminals even with traceRequests
        // off or Openplanet's trace level hidden. No input payloads here.
        TmMcpAppendRequestTrace("call", g_ToolCallInstance + " " + message);
    }

    void StartToolCalls() {
        g_ToolCallInstance = "" + Time::Stamp + "-" + Time::Now + "-" + Math::Rand(10000, 99999);
        g_ToolCallsStarted = Time::Now;
        g_MonitorToolCalls = true;
        ToolCallEvent("dispatch instance started");
        startnew(TmMcp_MonitorToolCalls);
    }

    void FinishToolCall(ToolInvocation@ call, Json::Value@ result, const string &in reason) {
        if (call is null || call.finished) return;
        @call.result = result;
        call.finished = true;
        g_ToolCalls.Release(call.id);
        ToolCallEvent("tool done " + call.name + " #" + call.id + " " + reason + " " + (Time::Now - call.started) + "ms");
    }

    void SweepToolCalls() {
        // Iterate a snapshot: Finish removes by ID and can finish out of order.
        auto calls = g_ToolCalls.calls;
        for (uint i = 0; i < calls.Length; i++) {
            auto call = cast<ToolInvocation@>(calls[i]);
            string reason = call.Failure(Time::Now);
            if (reason.Length == 0) continue;
            if (reason == "tool_timeout" && call.owner.IsRunning()) {
                // Openplanet awaitable has no cancellation API. Do not admit
                // mutations beside a worker which may later resume. Quarantine
                // it until it exits or route=recover reloads the actual module.
                g_UnfinishedWorkers.InsertLast(call);
            }
            FinishToolCall(call, MakeError("tool did not complete: " + call.name,
                reason, false, "", "Inspect status.calls; recover reloads the bridge if a timed-out worker is still running"), reason);
        }
        for (int i = int(g_UnfinishedWorkers.Length) - 1; i >= 0; i--) {
            if (!g_UnfinishedWorkers[i].owner.IsRunning()) {
                ToolCallEvent("expired worker stopped #" + g_UnfinishedWorkers[i].id);
                g_UnfinishedWorkers.RemoveAt(uint(i));
            }
        }
    }

    void MonitorToolCalls() {
        while (g_MonitorToolCalls) { SweepToolCalls(); yield(); }
    }

    void StopToolCalls() {
        g_MonitorToolCalls = false;
        auto calls = g_ToolCalls.calls;
        for (uint i = 0; i < calls.Length; i++) {
            auto call = cast<ToolInvocation@>(calls[i]);
            FinishToolCall(call, MakeError("bridge is shutting down", "tool_shutdown", false), "tool_shutdown");
        }
        // Workers terminate with the module. Globals are deliberately not in
        // shared_exports and a genuine reload creates a fresh instance.
    }

    Json::Value@ CallTool(const string &in name, Json::Value &in input) {
        SweepToolCalls();
        if (!g_MonitorToolCalls) return MakeError("dispatch not running", "tool_shutdown", true);
        if (g_UnfinishedWorkers.Length > 0) {
            ToolCallEvent("tool rejected " + name + " recovery_required");
            return MakeError("a timed-out worker may still be running", "recovery_required", false,
                "", "Use status then recover; do not retry mutations until recovery completes");
        }
        // A self-reload must queue on the caller's stack: starting it inside
        // a worker destroys the waiting socket coroutine before it can reply.
        // This exact path never yields and deliberately destroys its module.
        if (name == "ControlPlugin" && IsBridgeReloadRequest(input)) {
            // Nested pack workers still have an outer socket waiter. Refuse
            // self-reload during any tracked invocation rather than destroy
            // that outer waiter before it receives an acknowledgement.
            if (g_ToolCalls.calls.Length > 0) {
                return MakeError("bridge reload requires idle tool dispatch", "tool_busy", true,
                    "", "Wait for status.calls.active to empty, then use direct recover with its instance token");
            }
            ToolCallEvent("self reload requested on caller stack");
            return ControlPlugin(input);
        }
        if (g_ToolCalls.calls.Length >= MAX_TOOL_CALLS) return MakeError("too many in-flight tools", "tool_busy", true);
        auto call = ToolInvocation();
        call.name = name;
        call.started = Time::Now;
        // Preserve WaitUntil's loading-aware 30-minute wait contract. Other
        // calls get 2 minutes; lifecycle calls get 60 seconds wall time, without
        // changing Openplanet's independent 15-second script execution limit.
        call.budget = name == "WaitUntil" ? 2100000 : (name == "ControlPlugin" ? 60000 : 120000);
#if DEV
        if (name == "DevCallGuardProbe") call.budget = 150;
#endif
        call.instance = g_ToolCallInstance;
        auto owner = CoroutineCallOwner();
        @call.owner = owner;
        if (!g_ToolCalls.Admit(call)) {
            auto held = g_ToolCalls.Find(name);
            ToolCallEvent("tool rejected " + name + " reentrant_tool held=#" + held.id + " ageMs=" + (Time::Now - held.started));
            auto err = MakeError("reentrant tool call: " + name, "reentrant_tool", false);
            err["inFlight"] = ToolCallToJson(held);
            return err;
        }
        try {
            // Copy caller-owned input before crossing the worker boundary.
            @call.input = Json::Parse(Json::Write(input));
            ToolCallEvent("tool start " + name + " #" + call.id);
            @owner.worker = startnew(CoroutineFuncUserdata(TmMcp_RunToolCall), call);
        } catch {
            FinishToolCall(call, MakeError("could not start tool: " + getExceptionInfo(), "tool_exception", true), "tool_exception");
        }
        while (!call.finished) { SweepToolCalls(); if (!call.finished) yield(); }
        return call.result;
    }

    void RunToolCall(ToolInvocation@ call) {
        if (call is null || call.finished || call.instance != g_ToolCallInstance) return;
#if DEV
        // Deliberately outside the catch: emulate a VM-killed worker without
        // hanging the game for the script execution timeout.
        if (call.name == "DevCallGuardProbe" && call.input.HasKey("action") && string(call.input["action"]) == "die") {
            throw("DEV call-guard worker death");
        }
#endif
        Json::Value@ result;
        try { @result = DispatchTool(call.name, call.input); }
        catch { @result = MakeError("tool threw: " + getExceptionInfo(), "tool_exception", true); }
        string reason = result !is null && result.HasKey("success") && bool(result["success"]) ? "ok" : "error";
        FinishToolCall(call, result, reason);
    }

    Json::Value@ ToolCallToJson(CallLease@ call) {
        auto o = Json::Object();
        o["id"] = call.id; o["tool"] = call.name;
        o["ageMs"] = Time::Now - call.started; o["budgetMs"] = call.budget;
        o["workerRunning"] = call.owner !is null && call.owner.IsRunning();
        return o;
    }

    Json::Value@ ToolCallStatus() {
        SweepToolCalls();
        auto o = Json::Object(); auto active = Json::Array(); auto expired = Json::Array();
        for (uint i = 0; i < g_ToolCalls.calls.Length; i++) active.Add(ToolCallToJson(g_ToolCalls.calls[i]));
        for (uint i = 0; i < g_UnfinishedWorkers.Length; i++) expired.Add(ToolCallToJson(g_UnfinishedWorkers[i]));
        o["instance"] = g_ToolCallInstance; o["uptimeMs"] = Time::Now - g_ToolCallsStarted;
        o["active"] = active; o["expiredWorkers"] = expired;
        o["recoveryRequired"] = g_UnfinishedWorkers.Length > 0;
        o["eventLog"] = TmMcpRequestTracePath();
        auto self = SelfPlugin(); if (self !is null) o["sourcePath"] = self.SourcePath;
        return o;
    }

    Json::Value@ RecoverToolCalls(Json::Value@ request) {
        string instance = request.HasKey("instance") ? string(request["instance"]) : "";
        if (instance != g_ToolCallInstance) return MakeError("instance must match status.calls.instance", "stale_instance", false);
        ToolCallEvent("explicit recovery reload requested");
        auto output = ToolCallStatus();
        try {
            Meta::ReloadPlugin(SelfPlugin());
        } catch { return MakeError("recovery reload failed: " + getExceptionInfo(), "reload_failed", true); }
        // No yield: socket response is written before the queued reload occurs.
        output["reloadQueued"] = true;
        return MakeSuccess(output);
    }

#if DEV
    Json::Value@ DevCallGuardProbe(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "ok";
        if (action == "throw") throw("DEV call-guard caught exception");
        if (action == "reenter") return CallTool("DevCallGuardProbe", input);
        if (action == "self_reload") {
            auto reload = Json::Object(); reload["action"] = "reload"; reload["id"] = SelfPlugin().ID;
            return CallTool("ControlPlugin", reload);
        }
        if (action == "wait") { uint64 until = Time::Now + 80; while (Time::Now < until) yield(); }
        if (action == "forever") { while (true) yield(); }
        return MakeSuccess(Json::Object());
    }
#endif
}
