# Editor script plugin control and offline value recovery

`ControlEditorScriptPlugins` has two actions: `status` (the default) and
`reload`. It uses the documented map editor `ForcedPluginsNames` and
`ReloadPlugins()` interfaces. These describe editor script plugins, separately
from Openplanet plugin management.

```json
{"action":"status"}
```

Status observes editor/map availability, loading, a shadow-computation wait
dialog, a native script crash dialog, and forced plugin names. At most 64 names
are returned, each capped at 256 UTF-8 bytes without splitting a code point.
`forcedPluginNameCount` reports the full count; `forcedPluginNamesTruncated`
reports any omitted names or shortened text. Names are observations, not a
complete inventory of running scripts, source identities, or version evidence.
Status also works without a map editor and reports unavailable state explicitly.

```json
{"action":"reload","confirm":true}
```

Reload requires the literal boolean `confirm:true`. Before the native call, it
requires idle `MapEditor` (driving, test and validation modes are refused), and
refuses a missing map/editor, loading or a shadow-computation wait dialog, and a
detected script crash dialog. Shadow guarding uses the existing public wait-UI
observation; all wait-message loading states are also refused. These observations
cannot establish health after a dismissed dialog or detect every engine state.
The tool never changes forced names or performs additional recovery actions.

One native call is followed by one frame yield. The tool retains a native
reference to the original map, resolves the current editor again after yielding,
and compares the actual map object identity. It explicitly releases that
reference on success and error paths; its lease destructor is a fallback.
Different map objects with identical metadata still fail the identity check.
A missing editor or changed map produces `CONTEXT_CHANGED`. A busy state, crash
dialog, or exception after invocation produces `RELOAD_UNVERIFIED`. No automatic
retry occurs. Preserve diagnostics before deciding what to do next.

Every status/reload observation includes `reloadInvoked`, `reloadReturned`,
`reloadVerified`, `sourceVersionVerified`, and `readinessVerified`.
`reloadInvoked:true` records entry into the native reload call, including a call
that raises an exception. `reloadReturned:true` records a normal return.
`mapIdentityMatches` is included when post-yield identity was observed and means
the same map object was seen at that point. The three verification flags remain
false: neither the native return nor the name list proves script execution,
source version, or editor readiness. A successful response means the requested
observation/invocation completed with no observed context fault. Error responses
after invocation preserve the invocation/return evidence in `output`.

## Generic offline recovery

`tools/recover_pending_value.py` consumes a user-supplied UTF-8 JSON event array.
Each row contains exactly three strings: `[type, key, base64value]`.
For example, this complete input has one matching value:

```json
[["value","draft","aGVsbG8="]]
```

```sh
python3 tools/recover_pending_value.py events.json draft-backup.bin \
  --event value --key draft
```

Both selectors are required, nonempty, and matched exactly, without case folding
or whitespace normalization. Every row's shape is validated, including unrelated
rows. Zero matches or multiple matches fail, even when duplicate values are
identical. Only the selected value is decoded. It must use canonical standard
base64: no whitespace, URL-safe alphabet, extra/missing padding, or nonzero pad
bits. Empty base64 is a valid empty binary value. No text decoding or repair is
applied to the recovered bytes.

Limits are 8 MiB of input, 4,096 rows, 1,024 UTF-8 bytes per event type/key, and
4 MiB of decoded output. Encoded values are capped at the corresponding base64
length before decoding. The file reader consumes at most the input limit plus
one byte to detect overflow. Malformed JSON, invalid Unicode selectors, and
excessive JSON nesting fail without creating a backup.

The backup is created exclusively with mode `0600`, subject to a stricter umask.
An existing file, directory, or symlink (including a dangling symlink) is refused.
The utility flushes and syncs the file before reporting success. A write failure
leaves the reserved backup in place for inspection; choose a new path for a later
attempt. It never overwrites an existing backup or writes to the input file.
Stdout contains only `bytes` and `sha256`; errors use fixed messages. Neither
raw nor encoded values, event selectors, or paths are printed.

The utility operates only on the supplied file and makes no game or network
calls. It provides a binary backup rather than an automatic import or restore.

## Offline verification

```sh
TCM_REQUIRE_ANGELSCRIPT=1 python3 -m pytest \
  tests/test_editor_script_plugins.py tests/test_recover_pending_value.py -q
```

Editor tests execute the entire production AngelScript file using the existing
stock AngelScript runner, with JSON and game API mocks. They cover guard order,
confirmation types, bounded names, map reference ownership, native exceptions,
editor replacement across a yield, map identity changes, and unverified result
semantics. The recovery tests exercise decoding and the real CLI/filesystem.
These checks do not prove live game compilation, engine scheduling, or runtime
readiness. No deployment, game mutation, restart, save, or map switch is part of
offline validation.
