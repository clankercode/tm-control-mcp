# Migration from tm-mcptm

This document maps the old `tm-mcptm` (module `McpTM`) surface to the new
`tm-control-mcp` (module `TmMcp`). Use it when porting an in-process consumer
like `tm-agent`.

## Why migrate?

`tm-control-mcp` is a strict superset of `tm-mcptm` (~100 tools vs ~24). It adds
menu automation, camera control, named macroblocks, provenance tags, screenshots,
ManiaScript injection, plugin/settings management, readiness/waiting, structured
errors, and more.

## Module + dependency changes

| | `tm-mcptm` | `tm-control-mcp` |
|---|---|---|
| Module name | `McpTM` | `TmMcp` |
| `info.toml` deps | `MLHook, MLFeedRaceData, Camera, VehicleState, Editor` | `Editor, MLHook, MLFeedRaceData` |
| Export file | `McpTM_Export.as` | `TmMcp_Export.as` |
| Socket | none | `127.0.0.1:30006` (toggleable via `S_TmMcpEnableSocket`) |
| Async model | `GetResult(reqId)` polling | Blocking socket dispatch **or** `DispatchAsync` + `GetResult` |

## Renamed tools

| `tm-mcptm` | `tm-control-mcp` | Notes |
|---|---|---|
| `SearchInventory` | `FindInventory` | Same shape; richer response |
| `TestMap` | `ControlValidation {action:"testFromStart"}` | Restructured into action-based tool; async via `DispatchAsync` |
| `SaveMap` | `SaveMapAs` | Renamed; richer path options |
| `GetPickedBlock` | `GetEditorSelectionState` | Broader selection-state read |
| `SetCursorBlock` | `SelectBlockModel` (alias `SetCursorBlock`) | Both work in TmMcp |
| `SetCursorItem` | `ControlInventory` / `SelectItemModel` | Split into separate tools |
| `GetResult` | `GetResult` (same API; see [Async](#async)) | Compatible |

## Same-name tools (enriched schemas)

These exist in both plugins under the same name. `tm-control-mcp` versions may
have additional optional fields or richer response bodies:

`PlaceBlock`, `RemoveBlock`, `Undo`, `Redo`, `GetCursor`, `GetMapInfo`,
`GetBlocks`, `GetItems`, `GetBlockAt`, `GetPlacementMode`, `GetEditMode`,
`GetMode`, `GetInventorySummary`

## New-only in tm-control-mcp (~70+)

Camera (`ControlCamera`), menu automation (`ClickMenuButton`,
`CreateMapViaMenu`), named macroblocks (`CreateNamedMacroblock`,
`PlaceNamedMacroblock`), provenance tags (`SetAgentTag`, `RemoveByTag`),
readiness (`GetReadiness`, `WaitUntil`), structured errors, screenshots
(`TakeScreenshot`), ManiaScript injection (`RunManialinkScript`), plugin
management (`ListPlugins`, `ControlPlugin`, settings), edit mode
(`ControlEditMode`), inventory control (`ControlInventory`), placement preflight
(`CanPlaceBlock`, `AssertPlacement`), DEV/RE diagnostics (DEV builds only), and
more.

## Async

`tm-mcptm` uses `GetResult(reqId)` for non-blocking tool dispatch. The in-process
export surface in `tm-control-mcp` provides the same pattern:

```angelscript
import Json::Value@ DispatchAsync(const string &in tool, Json::Value@ input) from "TmMcp";
import Json::Value@ GetResult(Json::Value &in input) from "TmMcp";

// Dispatch a tool without blocking; returns a request ID
Json::Value@ pending = TmMcp::DispatchAsync("ControlValidation", input);

// Poll for completion; returns {status:"pending"|"done"|"error", result?, error?}
Json::Value@ result = TmMcp::GetResult(pollInput);
```

This is compatible with `tm-mcptm`'s async model — callers can choose blocking
(`CallTool`) or non-blocking (`DispatchAsync` + `GetResult`) per call.

## Import migration

tm-control-mcp uses `Json::Value &in` signatures (not `Json::Value@`), so individual tool functions are not directly importable with the old `@` convention. Instead, consumers call tools via `CallTool`:

```angelscript
// Before (tm-mcptm) — per-function imports
import Json::Value@ PlaceBlock(Json::Value@ input) from "McpTM";
import Json::Value@ GetResult(Json::Value@ input) from "McpTM";

// After (tm-control-mcp) — dispatch by name
import Json::Value@ CallTool(const string &in name, Json::Value &in input) from "TmMcp";
import bool IsToolName(const string &in name) from "TmMcp";

// Async (issue #3)
import Json::Value@ DispatchAsync(const string &in tool, Json::Value@ input) from "TmMcp";
import Json::Value@ GetResult(Json::Value &in input) from "TmMcp";
```

Call any of the ~100+ tools via `CallTool("ToolName", input)`. Use `IsToolName` to check availability.

## Socket toggle

When using `tm-control-mcp` as an in-process library only:

```
Openplanet Settings → TM Control MCP → Server → Enable Socket = false
```

Or programmatically:

```bash
python3 tools/call.py SetPluginSetting '{"plugin":"tm-control-mcp","key":"S_TmMcpEnableSocket","value":false}'
```

This skips the TCP listener entirely — zero socket overhead for in-process consumers.
