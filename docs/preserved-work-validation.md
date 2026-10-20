# Preserved work validation — 2026-10-20

Implementing owner: Codex (`codex-vermic-lumi-8amm`).
Reviewed implementation: `116c5b3670781b16ddbf2f7538bf1885a2ab12b7`.

## Offline and static checks

- `TCM_REQUIRE_ANGELSCRIPT=1 python3 -m pytest tests -q`:
  **593 passed, 6 skipped, 41 subtests passed**. The SDK is the same pinned
  `0b8dacb8acac4e844a312c4405f124d97fc33af0` used by CI. Skips require an opt-in
  live game; separately executed live probes are recorded below.
- Behavioral tests execute production AngelScript for replacement planning,
  writer/readback faults, numeric and mode restrictions, auth availability and
  rejected old modes, editor reload/map lifetime, pack identity/ownership/teardown,
  and trace privacy. Python tests exercise the recovery CLI and exclusive writes.
- Release and staged DEV LSP: zero errors, the same 11 warnings as base `a3d217a`
  (signedness and existing pass-by-reference suggestions). Full JSON diagnostics
  preserve all information-level entries too: 88 DEV and 94 release.
- All 42 staged source files match canonical source byte for byte, both in the
  isolated development staging check and the actual loaded plugin directory.
- `git diff --check` passes. New source/docs were inspected for personal paths,
  research links, secret literals, private consumer schema and credential access.
  No excluded native carrier or credential-acquisition history is ported.

## Native review and CI

Two native T3 Codex review rounds used `ocx/gpt-6.1-sol`, ultra reasoning and the
ultrafast tier. Round one requested two fixes: verify every canonical pack
ancestor child slot and reject unrecognized tool names before lifecycle logging
while bounding both log sinks. Both were fixed with production-code regressions.
Round two approved implementation `116c5b3`: **source/offline PASS, no unresolved
findings or regressions**; its independent focused run passed 27 tests. The
reviewer did no live mutation. Runtime evidence was subsequently gathered by the
implementing owner. GitHub's Linux offline suite and native Windows client checks
passed on that implementation; the final PR head carries the CI receipt.

## In-game compile and behavior

The initial game exited during read-only inspection at 19:33:38, before any
implementation deployment. It returned independently at 19:49:23; this session
never restarted Trackmania. Once existing map loading settled and shadows were
clear, the repository `./build.sh dev` workflow staged this plugin and reloaded it
through RemoteBuild. Local dependency staging was disabled. No other plugin
source was changed and no release build/tag was made.

A fresh Openplanet log window begins at byte **433958** in the returned game's
log. It contains a target build and **Loaded plugin 'tm-control-mcp' at
19:54:10.438**, with no subsequent target compilation failure. Openplanet is
**1.29.14 (next, Public, 6fd4200f)**; the game engine reports
**2026-02-03 03:51:19**. The loaded source matches the reviewed SHA-256 manifest.

Both LSP and the game accepted the source. The target compile has 13 warnings:
the 11 LSP warnings plus pre-existing signedness warnings in
`PackUpdatePolicy.as:109` and `ToolPacks.as:42` that LSP did not report. The game
reports signedness columns two characters after LSP and groups the existing five
pass-by-reference suggestions at the function start. No new file has a compiler
warning. Full compile transcripts and diagnostic JSON are retained locally.

Fourteen live assertions passed through `tools/call.py` on port 30006:

- Auth availability status succeeds with `credentialValuesRead:false`; removed
  legacy/v2 acquisition modes are refused.
- Editor-script status succeeds outside the editor; confirmed reload is refused
  in Race mode.
- FID writes refuse driving mode, missing confirmation and native/game scripts.
- Menu-page writes refuse driving mode and fractional indices.
- Pack mount refuses driving mode; status refuses traversal and missing files.
- An unknown synthetic tool name produces the fixed error and appears in neither
  the Openplanet nor request-trace log.

The full pre-reload loaded plugin set was retained and compared afterward. The
build helper restored seven registered consumers; two additional previously
loaded consumers were then restored in dependency order. The final loaded set
contains every previously loaded plugin. No unrelated plugin was enabled. The
same race/map remains loaded and no map changes were made by the probes.

Native compile and safe/refusal behavior are observed. Successful editor reload,
text assignment and pack mount/unmount transitions are covered by offline
production-code fixtures rather than live mutation of the current race. These
results do not claim those unexecuted happy paths or ManiaScript health were
observed in game.

## Preserved branches

`local/preserved-work-20261020` remains unchanged at `90be5a0` in both local
clones. The [decision table](preserved-work-decisions.md) identifies the remaining
held functionality. None of that mixed history is an ancestor of the public
implementation. After the PR merge commit, both local masters are fast-forwarded
to the public master; the preserved branch is retained as the recovery source.
