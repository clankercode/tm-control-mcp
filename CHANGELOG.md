# Changelog

All notable changes to **tm-control-mcp** are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versions follow `info.toml` `[meta] version`.

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
