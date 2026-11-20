# MCP CLI contract

This is the shared contract for the Rust MCP adapter and the native bridge
catalog seam. The native socket remains backward compatible with its existing
`route=tools` and `route=call` envelopes.

## Native catalog

`{"route":"catalog"}` returns the normal native response envelope with:

```json
{
  "schemaVersion": 1,
  "instance": "bridge-instance-token",
  "revision": "42",
  "tools": [
    {
      "name": "GetMode",
      "description": "...",
      "input_schema": {"type":"object","properties":{}},
      "pack": ""
    }
  ]
}
```

`route=status` adds `data.catalog = {schemaVersion, instance, revision}`.
The instance changes whenever the bridge starts. The revision changes exactly
once for each committed tool-registry transaction, including a description or
schema-only change. Repeated reads do not change either value.

The catalog is reconciled against plugin liveness before status or catalog
responses are produced. The response is detached from the bridge's internal
JSON cache. Tool order is deterministic by canonical public name in the new
catalog route. The legacy `route=tools` shape and order remain supported.

## Native calls

The adapter calls the existing native envelope:

```json
{"route":"call","tool":"GetMode","input":{}}
```

When the catalog supplies a pack generation, the adapter may add:

```json
{"expect":{"instance":"...","generation":"..."}}
```

The bridge rejects stale instance/generation expectations before invoking a
tool. A timeout or disconnect never causes the adapter to replay a mutation.

## MCP adapter

The Rust process translates the native descriptors from `input_schema` to MCP
`inputSchema`, validates arguments with Draft 2020-12 without network `$ref`
resolution, and maps native results to MCP content plus `structuredContent`.
Known tool failures use `isError: true`; malformed MCP requests and unknown
tools use JSON-RPC errors.

The process supports MCP `2026-07-28`, `2025-11-25`, and `2025-06-18` over
stdio and Streamable HTTP. Modern requests use `server/discover`, per-request
metadata, cache hints, and `subscriptions/listen`; legacy requests use their
initialization lifecycle.

## Monitor events

The monitor observes the shared dispatcher of the process it renders — its
own for `monitor --serve`, or the attached server's via the audit endpoint —
never the native socket as a second client. Events contain an opaque
invocation id, connection id, request id, tool/method, start/end timestamps,
status, byte counts, and bounded copies of arguments/results. The observer is
lossy under pressure and never blocks MCP execution. TUI payloads are
sanitized before rendering.

## Audit endpoint

Every Streamable HTTP listener (`serve --transport http` and
`monitor --serve`) also serves a read-only audit endpoint:

```json
GET /monitor/snapshot -> 200
{"server":"tm-control-mcp","version":"0.1.0","events":[…],"stats":{…}}
```

The response carries the same sanitized, bounded events and counters the
in-process monitor renders, plus a per-listener `instance` nonce (its change
means the server restarted and invocation ids were reused) and an `ETag`
keyed on store counters, so unchanged polls are served from a cached body.
`Cache-Control: no-store` applies. The endpoint is loopback-only like the
MCP route and keeps its posture: a present `Origin` must be explicitly
allowed (`--origin`, compared as an exact `scheme://host:port` string —
stricter than rmcp's normalised matching on `/mcp`) and a present `Host`
must match the listener; local clients that omit both headers stay allowed.

`tm-control-mcp monitor` attaches to an existing listener through that
endpoint by default (`--attach ADDR`, default `127.0.0.1:30007`) and never
creates an MCP listener, native client, or catalog poller of its own. The
attach probe precedes the terminal: an unreachable target, HTTP 404 (older
binary), 403, or a foreign `server` value exits with an actionable hint.
Losing the server keeps the last snapshot and retries with backoff.
`monitor --serve` opts back into the previous single-process behaviour:
bind `--listen`, serve MCP plus the audit endpoint, and run the terminal
monitor against that dispatcher.
