// Opt-in, owner-scoped call observers for cross-client session journals.
// Socket calls only (Protocol.as passes source="socket"); direct, imported and
// nested calls are never recorded. Hooks only enqueue: no callbacks into other
// modules from an admission stack, no yields, exceptions isolated from dispatch.
// Payloads are kept only in subscriber memory, never in request-trace.log.
namespace TmMcp {
    const uint OBSERVER_MAX_SUBSCRIBERS = 8;
    const uint OBSERVER_MAX_TOOLS = 64;
    const uint OBSERVER_QUEUE_RECORDS = 256;
    const uint OBSERVER_QUEUE_BYTES = 512 * 1024;
    const uint OBSERVER_PAYLOAD_BYTES = 16 * 1024;
    const uint OBSERVER_DRAIN_MAX = 128;

    // Exact-name allowlist: reviewed read-only tools whose whole input/result are
    // safe to record and replay. Anything else is refused at AddCallObserver.
    const array<string> OBSERVABLE_TOOLS = {
        "GetMode", "GetMapInfo", "GetReadiness", "GetDialog", "GetVehicleState", "GetRaceData",
        "GetWaypoints", "GetEditorCamera", "GetRenderCamera", "GetCursor", "GetBlockAt"
    };

    class ObserverRecord {
        string json;
    }

    class CallObserver {
        string id, owner;
        array<string> tools;
        array<ObserverRecord@> queue;
        uint bytes = 0;
        uint64 next = 0;     // count of enqueue attempts (cursor)
        uint64 drained = 0;  // last drained cursor
        uint64 overflow = 0; // cumulative dropped records
    }

    array<CallObserver@> g_CallObservers;

    string ObserverOwner() {
        auto plugin = Meta::ExecutingPlugin();
        if (plugin is null) return "";
        string id = plugin.ID;
        auto self = SelfPlugin();
        return self !is null && id == self.ID ? "" : id;
    }

    // Export-imported calls execute with the bridge as ExecutingPlugin (verified live
    // 2026-11-20), so an in-process consumer claims its plugin ID in spec.owner. The
    // claim must resolve to a loaded, enabled plugin; direct (non-imported) callers
    // still bind via ExecutingPlugin. Anything else is refused (fail-closed).
    string ResolveOwner(Json::Value@ spec) {
        string owner = ObserverOwner();
        if (owner.Length > 0) return owner;
        if (spec is null || !spec.HasKey("owner") || spec["owner"].GetType() != Json::Type::String) return "";
        auto claimed = Meta::GetPluginFromID(string(spec["owner"]));
        if (claimed is null || !claimed.Enabled) return "";
        return string(spec["owner"]);
    }

    string ObserverOwnerClaimed(const string &in claimed) {
        string owner = ObserverOwner();
        if (owner.Length > 0) return owner;
        if (claimed.Length == 0) return "";
        auto plugin = Meta::GetPluginFromID(claimed);
        return plugin !is null && plugin.Enabled ? claimed : "";
    }

    string AddCallObserver(Json::Value@ spec) {
        try {
            string owner = ResolveOwner(spec);
            if (owner.Length == 0 || spec is null || spec.GetType() != Json::Type::Object) return "";
            auto keys = spec.GetKeys(); // GetKeys is sorted alphabetically: judge by set membership
            bool hasTools = false, hasOwner = false;
            for (uint k = 0; k < keys.Length; k++) {
                if (keys[k] == "tools") hasTools = true;
                else if (keys[k] == "owner") hasOwner = true;
            }
            if (!hasTools || keys.Length != uint(hasOwner ? 2 : 1) || spec["tools"].GetType() != Json::Type::Array) return "";
            auto tools = spec["tools"];
            if (tools.Length == 0 || tools.Length > OBSERVER_MAX_TOOLS) return "";
            auto observer = CallObserver();
            for (uint i = 0; i < tools.Length; i++) {
                if (tools[i].GetType() != Json::Type::String) return "";
                string name = string(tools[i]);
                if (OBSERVABLE_TOOLS.Find(name) < 0 || observer.tools.Find(name) >= 0) return "";
                observer.tools.InsertLast(name);
            }
            uint owned = 0;
            for (uint i = 0; i < g_CallObservers.Length; i++) if (g_CallObservers[i].owner == owner) owned++;
            if (owned >= 2 || g_CallObservers.Length >= OBSERVER_MAX_SUBSCRIBERS) return "";
            observer.id = Crypto::RandomBase64(18, true);
            observer.owner = owner;
            g_CallObservers.InsertLast(observer);
            ToolCallEvent("observer added owner=" + owner + " tools=" + observer.tools.Length);
            return observer.id;
        } catch {
            return "";
        }
    }

    bool RemoveCallObserver(const string &in id, const string &in claimed = "") {
        string owner = ObserverOwnerClaimed(claimed);
        for (uint i = 0; i < g_CallObservers.Length; i++) {
            if (g_CallObservers[i].id != id || g_CallObservers[i].owner != owner) continue;
            g_CallObservers.RemoveAt(i);
            ToolCallEvent("observer removed owner=" + owner);
            return true;
        }
        return false;
    }

    Json::Value@ DrainCallObserver(const string &in id, uint limit, const string &in claimed = "") {
        string owner = ObserverOwnerClaimed(claimed);
        for (uint i = 0; i < g_CallObservers.Length; i++) {
            auto observer = g_CallObservers[i];
            if (observer.id != id || observer.owner != owner) continue;
            if (limit == 0 || limit > OBSERVER_DRAIN_MAX) limit = OBSERVER_DRAIN_MAX;
            auto records = Json::Array();
            uint count = observer.queue.Length < limit ? observer.queue.Length : limit;
            for (uint k = 0; k < count; k++) {
                records.Add(Json::Parse(observer.queue[k].json));
                observer.bytes -= uint(observer.queue[k].json.Length);
            }
            observer.queue.RemoveRange(0, count);
            observer.drained = observer.next - observer.queue.Length;
            auto output = Json::Object();
            output["records"] = records;
            output["next"] = observer.drained;
            output["overflow"] = observer.overflow;
            return output;
        }
        return null;
    }

    Json::Value@ ObservedPayload(Json::Value@ value, bool &out omitted) {
        omitted = false;
        if (value is null) return null;
        string text = Json::Write(value);
        if (uint(text.Length) <= OBSERVER_PAYLOAD_BYTES) return Json::Parse(text);
        omitted = true;
        return null;
    }

    // Called synchronously at admission (stage "admitted") and after
    // FinishToolCall releases the lease (stage "completed"). Never yields.
    void ObserveCall(ToolInvocation@ call, const string &in stage) {
        if (g_CallObservers.Length == 0 || call is null || call.source != "socket") return;
        try {
            bool omitted = false;
            Json::Value@ payload = stage == "admitted" ? ObservedPayload(call.input, omitted)
                                                       : ObservedPayload(call.result, omitted);
            auto record = Json::Object();
            record["instance"] = call.instance;
            record["generation"] = call.packGeneration.Length > 0 ? Json::Value(call.packGeneration) : Json::Value();
            record["invocationId"] = "" + call.id;
            record["tool"] = call.name;
            record["source"] = call.source;
            record["stage"] = stage;
            record["frame"] = stage == "admitted" ? call.observedFrame : Time::FrameCount;
            record["wallMs"] = stage == "admitted" ? call.observedWallMs : Time::Now;
            if (payload !is null) record[stage == "admitted" ? "input" : "result"] = payload;
            record["replayable"] = !omitted && !call.observerTruncated;
            if (omitted) call.observerTruncated = true;
            string json = Json::Write(record);
            for (uint i = 0; i < g_CallObservers.Length; i++) {
                auto observer = g_CallObservers[i];
                if (observer.tools.Find(call.name) < 0) continue;
                // Record completion only for the same sampled admission.
                if (stage == "completed" && call.observers.Find(observer.id) < 0) continue;
                if (stage == "admitted") call.observers.InsertLast(observer.id);
                observer.next++;
                if (observer.queue.Length >= OBSERVER_QUEUE_RECORDS
                    || observer.bytes + uint(json.Length) > OBSERVER_QUEUE_BYTES) {
                    observer.overflow++;
                    continue;
                }
                auto entry = ObserverRecord();
                entry.json = json;
                observer.queue.InsertLast(entry);
                observer.bytes += uint(json.Length);
            }
        } catch {
            ToolCallEvent("observer hook failed " + call.name);
        }
    }

    // Sweep subscriptions whose owner plugin is gone or disabled.
    void SweepCallObservers() {
        for (int i = int(g_CallObservers.Length) - 1; i >= 0; i--) {
            auto plugin = Meta::GetPluginFromID(g_CallObservers[uint(i)].owner);
            if (plugin is null || !plugin.Enabled) g_CallObservers.RemoveAt(uint(i));
        }
    }

    void StopCallObservers() { g_CallObservers.Resize(0); }
}
