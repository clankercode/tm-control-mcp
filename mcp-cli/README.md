# mcp-cli

`tm-control-mcp` is the Rust adapter for the localhost `tm-control-mcp` socket. It is
one binary with three modes:

```sh
# MCP stdio (the default; stdout contains only JSON-RPC frames)
tm-control-mcp

# Check native status and catalog
tm-control-mcp doctor

# Streamable HTTP on loopback
tm-control-mcp serve --transport http --listen 127.0.0.1:30007

# HTTP plus a terminal monitor
tm-control-mcp monitor --events-jsonl /tmp/tm-control-events.jsonl
```

The native bridge remains the authority for tool names, descriptions, and raw
`input_schema` values. The adapter polls `route=catalog`, tracks its instance
and revision, validates every call with Draft 2020-12 JSON Schema, and sends one
bounded newline-delimited TCP request per native call. A timeout or disconnect
is returned as an error and is never replayed.

HTTP is loopback-only and enables rmcp's explicit Origin validation. The
default Origin allowlist is empty: missing Origin is accepted, and every
present Origin is rejected unless explicitly allowed with `--origin`. The rmcp
transport handles both the modern stateless protocol and the legacy initialize
session lifecycle. Supported protocol versions are `2026-07-28`, `2025-11-25`,
and `2025-06-18`.

The built-in resources are `tm-control://guide/index`, `readiness`,
`placement`, and `screenshots`. Screenshot calls expose bounded native path
metadata with `verified: false`; this binary does not read or claim to decode
image bytes.

## Configuration

All options are command-line options so a stdio launcher can keep its config
small:

```text
serve --transport stdio|http | monitor | doctor
--native-host 127.0.0.1
--native-port 30006
--listen 127.0.0.1:30007
--poll-ms 2000
--events-jsonl /path/to/events.jsonl
--origin http://localhost:30007
```

The monitor keeps at most 256 events. Event payloads are bounded and redact
keys containing token, password, secret, authorization, access-key, or private
key. JSONL writes use a bounded async queue and never hold up MCP dispatch.

Build and test this crate on `x-p35`; the repository lane intentionally does
not run Cargo on the workstation.
