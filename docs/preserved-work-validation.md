# Preserved work validation — 2026-10-20

Implementing owner: Codex (`codex-vermic-lumi-8amm`).

- Offline suite: `TCM_REQUIRE_ANGELSCRIPT=1 python3 -m pytest tests -q`:
  **588 passed, 6 skipped, 41 subtests passed**. The SDK is the same pinned
  `0b8dacb8acac4e844a312c4405f124d97fc33af0` used by CI. Skips require a live game.
- Behavioral tests execute production AngelScript for replacement planning,
  writer/readback faults, mode restrictions, auth availability and rejected old
  modes, editor reload/map lifetime, pack identity/ownership/teardown, and trace
  privacy. Python tests exercise the recovery CLI and exclusive filesystem writes.
- `./build.sh dev` ran with an isolated temporary Plugins destination,
  `TM_PLUGIN_SKIP_RELOAD=1`, `TM_PLUGIN_STAGE_LOCAL_DEPS=0`, and the separate LSP
  run below. No live plugin directory or other plugin was changed.
- All 42 staged source files match canonical source byte for byte. A SHA-256
  manifest is retained in the local validation artifacts.
- LSP checked staged DEV and canonical release source against Openplanet 1.29.14
  and game type database `2026-02-03 03:51:19`: zero errors, the same 11 warnings
  as base `a3d217a` (signedness and existing pass-by-reference suggestions).
  Full diagnostics and information-level findings are preserved in local logs.
- `git diff --check` passes. New source/docs were inspected for personal paths,
  research links, secret literals, private consumer schema and credential access.
  No excluded native carrier or credential-acquisition history is ported.

## Runtime gate remains blocked

The initial read-only control probe succeeded in Race mode. Subsequent probes
read plugin identity/state and reflected API members only. Trackmania exited
with its plugin shutdown sequence at **19:33:38**, before any implementation was
staged or reloaded into the game. The process is absent and control/reload
listeners are closed. The instruction not to restart Trackmania is respected.
There is therefore **no in-game compile, live behavioral pass, or LSP/game parity
claim for this change**. Offline mocks cannot prove native pack lifetime or
ManiaScript compilation.

Before merging, with a running game, use the repository dev build/reload workflow
and preserve a fresh target load-to-end Openplanet log plus exact staged-byte
identity. Preserve the currently loaded dependent set and restore only that set.
Exercise auth status/removed-mode refusals, writer mode/confirmation refusals,
editor status/reload in a disposable map, and owned mount → status → unmount with
an original-content pack. Verify source/readback failure reporting without
introducing an intentionally invalid script into a user's map. Do not claim
readback proves script health. The public PR stays draft until this gate closes.

## Preserved branches

`local/preserved-work-20261020` remains unchanged at `90be5a0` in both local
clones. The [decision table](preserved-work-decisions.md) identifies the remaining
held functionality. No old mixed checkpoint history should be pushed or merged.
Both local master refs remain at the verified public base until the new PR can
be merged with a merge commit and fast-forwarded in each clone.
