# Changelog

All notable changes to **tm-control-mcp** are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versions follow `info.toml` `[meta] version`.

## [Unreleased]

### Added

- `EditNewMap` and `BackToMainMenu` now warn when leaving a dirty map pops the unsaved-changes dialog (`FrameAskYesNo`). `EditNewMap` waits `waitMs` (default 1500) like `OpenMapInEditor`; `BackToMainMenu` stops early instead of spinning 10s. Answer via `RespondDialog` or `SaveMapFlow`.
- `EditNewMap` for custom environments (RedIsland / BlueBay / GreenCoast / WhiteShore) now passes the preloaded decoration nod IdName (`Day` / `Day64` / `Sunset64` / …, not `64x64Day`) to `EditNewMap2`. Non-Day moods use the chosen nod directly instead of SwapDecoHack.
- Map-load waits: idle budget is **20s** (was 12–15s). Once a loading screen is up (`WaitMessage` / `LoadProgress`), `WaitUntil`, `EditNewMap`, and `CreateMapViaMenu` keep waiting until the map finishes (hard cap 30 min). `call.py` socket timeout follows.

### Changed

- `GetToolList()` now caches the built tool array and rebuilds only when a pack is registered, unregistered, or swept. Callers (e.g. tm-agent's chat UI) were paying ~1–2 ms per call to re-parse ~90 schemas every frame.

## [0.4.0] — 2026-08-16

### Changed

- **`TakeScreenshot`** now waits for the capture file and reports it: `fullName` (game-side path from `Viewport.ScreenShotFullName`) + `sizeBytes` + `detected`, with `waitMs` (default 5000, `noWait`/`0` for fire-and-forget) and `timedOut` on miss. New options: `hideOverlay` (native `DisableOverlayRender`, restored after), `forceRes`+`width`/`height` (native `ScreenShotForceRes/W/H`, restored after). `format` is now validated (`jpg|webp|tga|dds`). Crash-prone native paths (360°, tiling, alpha/pixel-output) remain unexposed — documented in the new `screenshots` guide.

### Added

- `screenshots` guide (`GetGuide {"topic":"screenshots"}`): native capture pipeline, file locations/numbering, safe options, and the deliberately-unexposed crash-prone viewport settings.

## [0.3.0] — 2026-08-15

### Added

- **Tool packs** (issue #5): `RegisterToolPack` / `UnregisterToolPack` / shared `ToolPackBuilder`. Pack tools are `packId.FuncName`. Builtin `ListToolPacks`. Authoring: [docs/tool-packs.md](docs/tool-packs.md). Fixture: `tools/fixtures/tm-mcp-pack-fixture/`.
- In-process export surface (`TmMcp_Export.as`, issue #1): `import` from `"TmMcp"` for all major tools + `CallTool`/`IsToolName`/`DispatchAsync`/`GetResult`
- **Socket toggle** (`S_TmMcpEnableSocket`): skip TCP listener for pure in-process use
- **Async dispatch** (`DispatchAsync` + `GetResult`, issue #3): non-blocking tool dispatch with poll semantics
- **Race tools** (issue #2): `GetRaceData`, `GetPlayers`, `GetServerInfo` — ported from tm-mcptm
- `MLFeedRaceData` dependency added
- Migration guide: [docs/migration-from-mcptm.md](docs/migration-from-mcptm.md)
- `ControlPlugin` RemoteBuild-parity: `load` by plugin id (`Plugins/<id>/` or `<id>.op`), unload-then-load rebuild, `getLogs` from `Openplanet.log`
- Socket Settings tab + exported `StartSocket` / `StopSocket` / `SetSocketEnabled` / `GetSocketStatus`
- ~~Editor++ (`Editor`) optional~~ → E++ tools moved out entirely in 0.3.0
- Request-payload trace writes to plugin storage (`request-trace.log`), not `Openplanet.log`
- `GetVehicleState` / `ListVehicleVis` / `GetVehicleVis` (VehicleState::) and `GetRenderCamera` / `ProjectWorldToScreen` / `SetEditorOrbitalTarget` (Camera::)
- One-line Openplanet `trace` at each tool start (name + args) and finish (ok/err + ms)

### Changed

- **E++ tools moved to [tm-mcp-pack-epp](https://github.com/clankercode/tm-mcp-pack-epp)** (breaking): freeblock/item placement, named macroblocks, tag provenance, inventory control/edit-mode/item-editor, macroblock inspection, E++ camera focus. `Editor` removed from `optional_dependencies`. Old builtin names return `moved_to_pack`.
- Plugin list/get default to `sourcePathBase` (basename); full path via `includeSourcePath`
- `call.py` screenshot detection adds `linuxPathHomeRelative`
- README documents tested Editor++ 0.8.x and MLHook ≥ 0.5.4
- Socket enable/host/port apply live (no plugin reload). `S_TmMcpEnableSocket` is hidden.

## [0.2.0] — 2026-08-12

First tagged public GitHub release.

### Changed

- **DEV/RE tools gated behind `#if DEV`** — release builds (no `defines = ["DEV"]`) no longer register or dispatch:
  - `RunGizmoApplyBlock`, `RunRandomFuzz`, `RunComputeItemsDiagnostic`
  - `DevSafeRead`, `DevGetPointers`, `DevComputeItemsPointers`, `DumpMacroblockHeader`
  - Folder **dev** staging (`./build.sh dev`) still injects `DEV` and exposes them
- `status` route reports live `Meta::ExecutingPlugin()` name/version/id (no hardcoded version)
- README / SECURITY note that memory tools are dev-build only

### Added

- `tools/smoke_tag_cleanup.py` — live agent recipe: readiness → tag → place → assert → `RemoveByTag`
- Release packaging docs already in `RELEASE.md` (`release-check`, GH notes + `.op` asset)

### Notes

- Script timeout remains **15000 ms**
- Dual Unlicense / CC0 unchanged

## [0.1.0] — 2026-08-12

First public GitHub surface (`clankercode/tm-control-mcp`) before the tagged release.

### Added

- Localhost JSON TCP control socket (`127.0.0.1:30006` by default)
- Large MCP-style tool surface for editor, menu, placement, inventory, camera, dialogs
- **Agent ergonomics (Tier A)**
  - `GetReadiness`, `WaitUntil`
  - Provenance tags: `SetAgentTag`, `ListTagged`, `RemoveByTag`, `ClearTagIndex`
  - `ControlEditMode`, `SelectItemModel`, `SelectMacroblockModel`, `ControlInventory`
  - Durable named macroblocks: `SaveNamedMacroblock`, `LoadNamedMacroblock`, `ListSavedNamedMacroblocks`
  - `AssertPlacement`
  - `RunManialinkScript` result channel (`collectMs` / `resultEvent`)
  - Structured error fields (`code`, `retryable`, `requiredMode`, `hint`)
- **Menu automation** via `CControlBase::OnAction` (not `TriggerPageAction`)
- **Openplanet Meta:: plugin & settings control**
- **Map objectives**: `ControlMapObjectives` (clones / laps)
- Freeblock / item placement via Editor++
- Named in-memory macroblocks with skins + batch add
- DEV / RE diagnostics (later gated in 0.2.0 for non-DEV builds)
- `tools/call.py` client with process check, wait helpers, screenshot detection
- Dual license: Unlicense **or** CC0 1.0
- In-plugin guides (`ListGuides` / `GetGuide`)
- `SECURITY.md`, `RELEASE.md`, CI pytest, `release-check` DEV-off gate
