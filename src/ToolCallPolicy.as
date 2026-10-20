// Scheduling-independent admission and termination policy. No shared state is
// exported: every invocation, including legacy imports, gets a known worker.
namespace TmMcp {
    interface IToolCallOwner { bool IsRunning(); }

    class CallLease {
        uint64 id;
        string name;
        uint64 started;
        uint64 budget;
        IToolCallOwner@ owner;
        bool finished = false;

        string Failure(uint64 now) {
            if (finished) return "";
            if (owner !is null && !owner.IsRunning()) return "tool_terminated";
            if (now - started >= budget) return "tool_timeout";
            return "";
        }
    }

    class ToolCallRegistry {
        array<CallLease@> calls;
        uint64 nextId = 0;

        bool Admit(CallLease@ call) {
            if (Find(call.name) !is null) return false;
            call.id = ++nextId;
            calls.InsertLast(call);
            return true;
        }

        CallLease@ Find(const string &in name) {
            for (uint i = 0; i < calls.Length; i++) {
                if (calls[i].name == name) return calls[i];
            }
            return null;
        }

        // Completion order is unrelated to admission order. Never pop a stack.
        void Release(uint64 id) {
            for (uint i = 0; i < calls.Length; i++) {
                if (calls[i].id == id) { calls.RemoveAt(i); return; }
            }
        }
    }
}
