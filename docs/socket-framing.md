# Socket request framing

Each connection carries one JSON request terminated by a newline. Legacy clients
can half-close their write side instead. The server waits for a complete frame;
a pause between TCP fragments is not an end-of-message marker.

Requests are read in 1024-byte chunks, with at most 64 chunks drained per rendered
frame, a 16 MiB size limit, and a 10-second total read deadline. Size/time failures
return explicit framing errors instead of parsing partial JSON. Callers must send
the terminator or close their write side after sending the request.

Observed failure: passing Socket.Available() directly to ReadRaw lost most of a
24 KB request, leaving 3840 bytes and producing `request must be a JSON object`.
An additional three-quiet-frame heuristic prematurely parsed delayed fragments.
Bounded reads and explicit framing fix both paths. The old behavior failed all
four initial regression cases; the regression suite covers large requests,
delayed fragments, UTF-8 split across a read boundary, and legacy EOF framing.

Run the read-only live regression against a running game:

```sh
TM_MCP_LIVE_TESTS=1 python3 -m pytest -q tests/test_socket_large_live.py
```

It exercises only the status route and makes no map or plugin changes.

## Trace privacy and bounds

The optional exchange trace records byte counts only. Raw arguments and responses
have a **zero-character** logging budget: even a short prefix can contain a whole
token, script, setting value, or private path. Lifecycle metadata lines are capped
at 512 characters before a truncation marker, enough for an invocation ID, tool
name, timing, and outcome. Files rotate at 2 MB. The unused argument-serialization
helper was removed rather than increasing its old 180-character limit to 2048.
