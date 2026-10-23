# mcp-cli

`tm-control-mcp` is the Rust adapter for the localhost `tm-control-mcp` socket. It is
one binary with stdio, HTTP, monitor, and doctor modes:

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

Guide resources are discovered from the native `ListGuides` tool and read
through `GetGuide`. `TakeScreenshot` can publish fresh, magic-verified JPEG,
PNG, or WebP bytes as an MCP image plus an immutable
`tm-control://screenshot/<opaque-id>` resource. Configure the approved capture
root with `--screenshots-dir` or `TM_USER_GAME_FOLDER`.

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
--screenshots-dir /path/to/Trackmania
```

The monitor keeps at most 2,000 events within a bounded memory budget. Event
payloads are redacted and bounded; persistent JSONL contains metadata only and
rotates through five 10 MiB files. Payload export is explicit with
`--export-dir`.

## Terminal monitor

The monitor uses the same HTTP dispatcher as MCP clients. Its call history shows
tool names, outcomes and elapsed times; selecting a call opens its metadata and
separate, syntax-colored argument/result panels. Failures have a tinted result
panel, and a selected row keeps its own marker as well as the outcome icon.
Long pack tool names wrap so their function suffix remains readable.

`LIVE` describes the monitor's refresh mode. The displayed HTTP address is the
actual listener; the interface does not infer native bridge health from an old
successful call. The active filter and follow/history mode remain visible.
Pausing freezes the displayed events, elapsed times and snapshot counters.

| Key | Action |
| --- | --- |
| `↑` / `↓`, `k` / `j` | Select a call and enter history mode |
| `PageUp` / `PageDown`, `Home` / `End` | Move through retained history |
| `f` | Toggle following the newest matching call |
| `p` / Space | Pause or resume the snapshot |
| `/` | Edit a filter with a live preview |
| Enter / Escape while filtering | Apply the draft / restore the applied filter |
| `c` | Clear the applied filter |
| `[` / `]` | Scroll the selected call's wrapped details |
| Tab | Switch full-width calls/details in terminals narrower than 100 columns |
| `e` | Export the selected retained, sanitized payload when `--export-dir` is configured |
| `q`, Escape outside filtering, Ctrl-C | Quit the monitor and HTTP listener |

Filters support `tool:SummarizeMap`, `status:tool_error`, `errors`, or ordinary
text matched against tool/method, status, connection and request identity.
`errors` includes validation, unavailable-catalog and queue-full failures as well
as tool and transport errors. Cancelled calls have a separate neutral outcome.

Use `--ascii` for ASCII borders, markers and scrollbars. Payload text keeps its
original Unicode. Very small terminals use a compact view; enlarging the
terminal restores the full layout. The details viewport wraps by grapheme and
terminal cell width, and marks any display truncation explicitly. Export keeps
the retained sanitized event, which may already be bounded by the monitor's
payload limit.

For repeatable Linux captures of the actual running terminal, use
[`tools/capture_mcp_tui.py`](../tools/capture_mcp_tui.py). It drives real MCP HTTP
traffic against a deterministic native fixture and captures Alacritty window
pixels in a private Xvfb display. It never contacts the game or builds Rust:

```sh
python3 tools/capture_mcp_tui.py \
  --binary /path/to/built/tm-control-mcp \
  --output /tmp/tui-captures \
  --commit REVISION \
  --isolated-run /path/to/isolated-run
```

Use `--columns 80 --rows 24 --details-key Tab` for a narrow-terminal capture, or
`--ascii` for ASCII chrome. Each set includes PNGs and a receipt with the binary
hash, measured PTY dimensions, fixture disclosure and call counts. Existing
captures require explicit `--overwrite`. See the
[visual review](../docs/research/tui-visual-review.md) for acceptance criteria and
verification evidence.

Build and test this crate on `x-p35`; the repository lane intentionally does
not run Cargo on the workstation.
