# Changelog

All notable changes to **tm-control-mcp** are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versions follow `info.toml` `[meta] version`.

## [0.1.0] — 2026-08-12

First public GitHub release candidate surface (`clankercode/tm-control-mcp`).

### Added

- Localhost JSON TCP control socket (`127.0.0.1:30006` by default)
- **98+ MCP-style tools** for Trackmania editor, menu, placement, inventory, camera, dialogs
- **Agent ergonomics (Tier A)**
  - `GetReadiness`, `WaitUntil`
  - Provenance tags: `SetAgentTag`, `ListTagged`, `RemoveByTag`, `ClearTagIndex`
  - `ControlEditMode`, `SelectItemModel`, `SelectMacroblockModel`, `ControlInventory`
  - Durable named macroblocks: `SaveNamedMacroblock`, `LoadNamedMacroblock`, `ListSavedNamedMacroblocks`
  - `AssertPlacement`
  - `RunManialinkScript` result channel (`collectMs` / `resultEvent`)
  - Structured error fields (`code`, `retryable`, `requiredMode`, `hint`)
- **Menu automation** via `CControlBase::OnAction` (not `TriggerPageAction`)
  - `CreateMapViaMenu`, `ClickMenuButton`, layer discovery tools, `EditNewMap`, `BackToMainMenu`
- **Openplanet Meta:: plugin & settings control**
  - `ListPlugins`, `GetPlugin`, `ControlPlugin`
  - `ListPluginSettings`, `GetPluginSetting`, `SetPluginSetting`, `ResetPluginSetting`, `SavePluginSettings`
- **Map objectives** (Editor++ exports): `ControlMapObjectives` — get/set NbClones, NbLaps, IsLapRace
- Freeblock / item placement via Editor++
- Named in-memory macroblocks with skins + batch add
- DEV / RE diagnostics (`DevSafeRead`, fuzz, pointer dumps, …)
- `tools/call.py` client with process check, schema validation, wait helpers, screenshot detection
- Dual license: Unlicense **or** CC0 1.0
- In-plugin guides (`ListGuides` / `GetGuide`)

### Notes

- Script timeout: **15000 ms** (`info.toml`)
- Hard dependencies: **Editor++** (`Editor`), **MLHook**
- Socket is **unauthenticated localhost** — see [SECURITY.md](./SECURITY.md)
- GitHub dual-license UI shows as “Other” (expected)

### Verification (this cut)

- In-game Openplanet compile (folder plugin)
- **DEV-off** stage + reload compile gate (see [RELEASE.md](./RELEASE.md))
- `pytest tests/test_call_wait.py`
- Live smoke of readiness, placement tags, plugin settings tools
