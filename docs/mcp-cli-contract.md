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

The HTTP monitor observes the shared dispatcher, not the native socket as a
second client. Events contain an opaque invocation id, connection id, request
id, tool/method, start/end timestamps, status, byte counts, and bounded copies
of arguments/results. The observer is lossy under pressure and never blocks
MCP execution. TUI payloads are sanitized before rendering.
