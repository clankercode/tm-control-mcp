# In-flight calls and bridge recovery

`python3 tools/call.py status` returns `data.calls` independently of tool admission:
instance identity, source path, uptime, active `{id,tool,ageMs,budgetMs,workerRunning}`
records, expired workers, and `recoveryRequired`. These records are concurrent
invocations, not a nesting stack. The name exclusion remains conservative: both
recursion and an independent overlapping invocation of the same tool receive
`reentrant_tool`, with the blocking invocation and its age attached.

Except for the nonyielding bridge-self-reload acknowledgement, every `CallTool`,
including imported calls and pack callbacks, dispatches through
a bridge-owned coroutine. The public signature is unchanged, but calls now yield
even when the tool itself is immediate; use a coroutine/`DispatchAsync` from
nonyieldable UI callbacks. Different nested tools remain callable. Input is copied
at admission. Disconnecting a socket does not cancel an already admitted mutation.

Normal return and caught errors release the exact invocation ID. An independent
monitor detects a worker whose `awaitable.IsRunning()` becomes false without a
result and returns `tool_terminated`. Limits are wall time: 60s for ControlPlugin,
120s for other tools, and 35 minutes for WaitUntil's loading-aware wait. These do
not change the manifest's independent 15s script execution limit.

A wall-time expiry returns `tool_timeout`. Openplanet 1.29.14 has no supported
per-coroutine cancellation API. If that worker is still running, it is quarantined
and subsequent tool calls receive `recovery_required` until it exits or the bridge
is genuinely reloaded. A timeout does not roll back mutations. Status remains
reachable. Clearing an old name while its coroutine can resume would be unsafe.

To recover without restarting Trackmania, read the current instance and request:

```bash
python3 tools/call.py status
python3 tools/call.py recover '{"instance":"COPY data.calls.instance HERE"}'
python3 tools/call.py status
```

`recover` is a direct socket route; its response result lives in `data`, rather
than `data.result`. A stale/missing instance is refused. It queues
`Meta::ReloadPlugin` for the cached bridge instance before yielding. Require a new
instance ID, empty active/expired lists, a fresh `Loaded plugin 'tm-control-mcp'`
log entry, and no later attributable compilation error. If the source fails to
compile, use the repository dev build/RemoteBuild workflow to deploy a good build;
a queued response alone is insufficient.

**Preserve dependent plugins.** Reloading tm-control unloads its required reverse
dependents. Snapshot the loaded transitive closure first using `ListPlugins` and
the `dependencies` fields. After a healthy bridge load, restore only that prior
loaded set in provider-before-consumer order with ControlPlugin `action=load` (or
the lifecycle bridge/RemoteBuild). Keep the snapshot across failures. Do not load
unrelated disabled plugins. The recovery route does not silently enable consumers.

Admissions, rejections (including blocking ID and age), completion and recovery
are appended to the rotating plugin-storage `request-trace.log` even when
`traceRequests` is off. Payload tracing remains opt-in. Openplanet trace filtering
and retention can hide older evidence; record a fresh log offset plus instance ID
for each lifecycle action.

## Regression evidence

`python3 -m pytest tests/test_call_guard.py -q` executes the production policy in
stock AngelScript. `python3 tools/verify_call_guard.py` exercises the DEV build in
a running game. The live probe includes worker death, recursion, out-of-order
completion, and a deliberately forever-yielding worker followed by recovery.
Coordinate exclusive game access before running it; it reloads the bridge and
restores its previously loaded dependents. It never restarts the game.
