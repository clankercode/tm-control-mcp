# TM Control MCP

Local Openplanet bridge for controlling Trackmania from external tools.

The plugin listens on `127.0.0.1:30006` by default and accepts one newline
terminated JSON request per TCP connection. Responses are newline terminated
JSON, and the socket is closed after each response.

## Protocol

Status:

```json
{"route":"status"}
```

List tools:

```json
{"route":"tools"}
```

Call a tool:

```json
{"route":"call","tool":"GetMode","input":{}}
```

Tool names can also be used as routes:

```json
{"route":"GetMapInfo","input":{}}
```

## Current tools (84)

Ground truth: every `MakeTool("…")` registration in `src/McpTools.as`.
Prefer `{"route":"tools"}` at runtime if this list drifts.

### Mode / map / dialogs

| Tool | Summary |
|------|---------|
| `GetMode` | Current game mode (Menu / Editor / Race / …). |
| `OpenMapInEditor` | Open a local map file in the editor (`path`). |
| `GetMapInfo` | Current editor map name and counts (+ bounds). |
| `GetMapEnvironment` | Collection, decoration, map type/style, mood, collection-unit metadata. |
| `SaveMapAs` | Save under user Maps (`name`+`folder` or `fileName`; `overwrite`). |
| `GetDialog` | Inspect `BasicDialogs` state / active frame. |
| `RespondDialog` | Respond: `yes`, `no`, `cancel`, `ok`, `validate`, `hide`, … |

### Editor selection / cursor / camera

| Tool | Summary |
|------|---------|
| `ControlValidation` | Validation / test / playground. Actions: `status`, `validate`, `requestEnterPlayground`, `requestLeavePlayground`, `testFromStart`, `testFromCoord`. |
| `ControlSelection` | Copy-paste / custom selection. Actions: `status`, `showCustom`, `hideCustom`, `resetSelection`, `selectAll`, `addSelection`, `copy`, `cut`, `remove`, `symmetrize`. |
| `GetCursor` | Editor cursor **coord** + selected block name/id. |
| `GetEditorSelectionState` | Placement modes, picked block, selected models, cursor coord, variant. |
| `ControlCursor` | Cursor API: `status`, `raise`, `lower`, `rotate`, `move`, `moveToCameraTarget`, `followCamera`, `disableMouseDetection`, `releaseLock`, `resetRGB`, `setRGB`. Relative moves via `direction` + `directionKind` are intentional. |
| `GetEditorCamera` | Camera target, angles, distance, orbital position. |
| `SetEditorCamera` | Set target/angles/distance (degrees default; `hAngleRad`/`vAngleRad` for radians). |
| `ControlCamera` | Camera API: `status`, `centerOnCursor`, `moveToMapCenter`, `watchWholeMap`, `watchStart`, `watchClosestFinishLine`, `watchClosestCheckpoint`, `zoom`/`zoomIn`/`zoomOut`, `look`, `followCursor`, `ignoreCollisions`, `releaseLock`, `setVStep`. |
| `FocusCamera` | Focus camera on world `(x,y,z)` via E++ animation (`distance` optional). |
| `TakeScreenshot` | Built-in viewport screenshot; `format` optional. |

### Blocks / items (read)

| Tool | Summary |
|------|---------|
| `GetBlocks` | Blocks by optional grid/world radius, model `query`, freeblock filter. |
| `GetRecentBlocks` | Last N blocks (freeblock `pos`/`rot`/`rotDeg`/`isFree` readback). |
| `GetBlockAt` | Block at exact grid `(x,y,z)`. |
| `GetItems` | Anchored items near world pos, or all up to `limit`. |
| `GetRecentItems` | Last N anchored items in map order. |

### Inventory / models

| Tool | Summary |
|------|---------|
| `GetInventorySummary` | E++ inventory cache counts + scan status. |
| `FindInventory` | Search blocks/items/macroblocks (`type`: `block`\|`item`\|`macroblock`\|`all`). |
| `RefreshInventory` | Trigger E++ InventoryCache rescan (after mid-session item adds). |
| `BrowseInventoryTree` | Read-only inventory tree (`root`, `rootIndex`, `path`, `depth`, `limit`, `query`, `includeArticles`). |
| `InspectMacroblockModel` | Loaded macroblock by `name`/`path`/`index` via E++ MacroblockSpec. |
| `ListMacroblockInstances` | Placed map macroblock instances (`limit`/`offset`/`recent`/`unitCoordLimit`). |
| `FindBlockModels` | Search loaded block models (variant counts, base sizes). |

### DEV / RE diagnostics

| Tool | Summary |
|------|---------|
| `RunGizmoApplyBlock` | DEV: free block through E++ gizmo apply path + mapPre/mapPost. |
| `RunRandomFuzz` | DEV: N random blocks/items in world bbox (`bboxMin`/`bboxMax`/`iterations`/`blockRatio`). |
| `RunComputeItemsDiagnostic` | DEV: `ComputeItemsForMacroblockInstance` + optional skin probe. |
| `DevSafeRead` | `Dev::SafeRead*` at `ptr` (+ `offset`/`offsets`, `kind`, `len`). |
| `DevGetPointers` | Editor/PMT/Challenge/Cursor/App pointers; optional item/block lists. |
| `DevComputeItemsPointers` | Like compute diagnostic but pointer-only (no wrapper field access). |
| `DumpMacroblockHeader` | RE: macroblock flags, buffers, raw words `0x100..0x1FC`. |

### Named macroblocks (in-memory)

| Tool | Summary |
|------|---------|
| `CreateNamedMacroblock` | Create/replace named handle (`name`, `replace`). |
| `GetNamedMacroblock` | Inspect stored block/item specs. |
| `ListNamedMacroblocks` | List in-memory named macroblocks. |
| `ClearNamedMacroblock` | Clear one (`name`) or all (`all=true`). |
| `AddBlockToNamedMacroblock` | Add free block spec (deg rotation default; optional skins). |
| `AddBlocksToNamedMacroblock` | Batch free block specs. |
| `AddItemToNamedMacroblock` | Add flying item by inventory path. |
| `AddItemsToNamedMacroblock` | Batch flying item specs. |
| `PlaceNamedMacroblock` | Place via E++ with offset/pivot rotation + mapPre/mapPost. |
| `PreflightNamedMacroblockPlacement` | Non-mutating extents/bounds/model checks. |

### Placement / deletion / undo

| Tool | Summary |
|------|---------|
| `CanPlaceBlock` | Grid/terrain place check without mutating. |
| `PlaceBlock` | Place grid block (`allowDestruction` optional). |
| `PlaceBlockViaEditorPlusPlus` | Free blocks via E++ macroblock path (deg default). |
| `PlaceItemViaEditorPlusPlus` | Flying items via E++ item path. |
| `RemoveBlock` | Remove block at grid coords. |
| `ClearBlocks` | `PluginMapType.RemoveAllBlocks()`. |
| `ClearItems` | `PluginMapType.RemoveAllObjects()`. |
| `ClearMapContent` | Clear blocks+items (`includeTerrain` optional). |
| `RemoveRecentBlocks` | Delete last N blocks via E++ deletion. |
| `RemoveRecentItems` | Delete last N items via **`Editor::DeleteItems`** (see below). |
| `RemoveBlocksByIndex` | Delete explicit block indices via E++. |
| `RemoveItemsByIndex` | Delete explicit item indices via **`Editor::DeleteItems`**. |
| `SelectBlockModel` | Set selected block model by name (E++). |
| `SetCursorBlock` | Alias for `SelectBlockModel`. |
| `Undo` / `Redo` | Editor undo/redo. |

### Guides

| Tool | Summary |
|------|---------|
| `ListGuides` | List self-doc guide topics. |
| `GetGuide` | Fetch guide body by `topic`. |

### Menu automation (landed)

Menu stack is **landed**. Clicks use `CControlBase::OnAction` — **not**
`TriggerPageAction` (that path crashes). Poll `GetActiveMenuPages` / `GetMode` /
`GetDialog` after navigation or clicks.

| Tool | Summary |
|------|---------|
| `SetMenuPage` | MLHook `Router_Push` to hierarchical `route` (e.g. `/create/mapeditorsettings`). Optional JSON strings `extra`, `history`. Side-effect routes blocked unless `allowPlaygroundLaunch:true`. Main-menu module only. |
| `GetMenuPage` | Top-level mode + whether main-menu module is active (not the specific route). |
| `ListKnownMenuRoutes` | Hardcoded catalogue of known working routes. |
| `EditNewMap` | `EditNewMap2` with Environment + Decoration + mapType. Returns immediately; poll `GetMode` → Editor. |
| `BackToMainMenu` | Unwind Editor/Race → main menu. Async; poll `GetMode` → Menu. |
| `GetUILayers` | List menu UI layers (index, type, visibility, attachId, pageUrl, manialink name). |
| `GetActiveMenuPages` | Visible layers named `Page_*` (where-am-I after `SetMenuPage`). |
| `GetLayerTree` | Walk one layer’s control tree (`layerIndex`, optional `rootPath`). |
| `GetLayerXml` | Slice or substring-grep a layer’s Manialink XML. |
| `ListMenuManialinkControls` | Walk menu control tree (ids/classes/visibility/path). |
| `FindMenuButtons` | Flat list of nav buttons (`component-navigation-item` default). |
| `FindControlsByClass` | Search controls by class pattern. |
| `FindControlsByLabel` | Search Label values by substring. |
| `InspectMenuControl` | Resolve ControlId; paths (`path` index, `idPath` ids); optional recursive descendants. |
| `FocusMenuControl` | `Focus()` a control by id (no click). |
| `SetMenuControlVisible` | `Show()`/`Hide()` by id or index path. |
| `ClickMenuButton` | High-level nav-item click → leaf `component-navigation-item-zone` → `OnAction`. |
| `TriggerControlOnAction` | Direct `CControlBase.OnAction()` by id or index path; optional recursive DFS. |
| `CreateMapViaMenu` | Single-call 7-step click-chain on `Page_MapEditorSettings` → Editor. Requires QuickStart off. |

### `RunManialinkScript`

Registered and implemented (`src/ManialinkRunner.as`). Injects ad-hoc ManiaScript
via MLHook into the same three contexts as MLHook’s UILayers browser.

| Arg | Default | Notes |
|-----|---------|--------|
| `script` | *(required)* | Raw ManiaScript or inner fragment. **No outer `<manialink>` tags** — MLHook wraps as `MLHook_<pageUid>`. |
| `context` | `current` | `current` (auto), `menu`, `in-map`, `in-editor` (aliases: playground, editor, race, …). |
| `pageUid` | `McpAdHoc` | Sanitized attach id stem. |
| `replace` | `true` | Replace existing injected page with same uid. |
| `persist` | `true` | If `false`, blank/remove layer after `waitMs`. |
| `waitMs` | `150` | Yield while inject queue runs (max 10000). |

Inject targets:

- `menu` → `MLHook::InjectManialinkToMenu`
- `in-map` → `MLHook::InjectManialinkToPlayground`
- `in-editor` → `MLHook::InjectManialinkToEditor`

**Semantics:** fire-and-forget. No return channel unless the script emits events
your hooks observe. Manialink pages are sandboxed from each other; use
TitleControl / local APIs available in that context. Bad ManiaScript can force
the game recovery restart — keep scripts small.

```bash
python3 tools/call.py RunManialinkScript '{"script":"main() {}","context":"menu"}'
```

## Quick Test

`tools/call.py` checks for a real Wine/Proton `Trackmania.exe` process before
opening the socket on every route, including `status` and `tools`. This avoids
waiting on a stale wrapper or frozen plugin when the game is not actually
running. Use `--skip-process-check` only for raw socket debugging.

`tools/call.py` returns **compact JSON** by default. Use `--pretty` when reading
responses manually. It returns compact JSON errors if Trackmania or the plugin
socket is unavailable.

```bash
./build.sh dev
python3 tools/call.py status
python3 tools/call.py --pretty status
python3 tools/call.py GetMode
python3 tools/call.py GetMapInfo
python3 tools/call.py GetMapEnvironment
python3 tools/call.py SaveMapAs '{"name":"codex-save-test","folder":"MCP","overwrite":true}'
python3 tools/call.py GetDialog
python3 tools/call.py RespondDialog '{"action":"no"}'
python3 tools/call.py ControlValidation '{"action":"status"}'
python3 tools/call.py ControlSelection '{"action":"status"}'
python3 tools/call.py GetCursor
python3 tools/call.py GetEditorCamera
python3 tools/call.py FocusCamera '{"x":338,"y":108.8,"z":196.25,"distance":60}'
python3 tools/call.py ControlCamera '{"action":"status"}'
python3 tools/call.py ControlCamera '{"action":"watchWholeMap","smooth":true}'
python3 tools/call.py ControlCursor '{"action":"status"}'
python3 tools/call.py ControlCursor '{"action":"move","direction":"Forward","directionKind":"relative"}'
python3 tools/call.py GetEditorSelectionState
python3 tools/call.py TakeScreenshot '{"format":"jpg"}'
python3 tools/call.py GetInventorySummary
python3 tools/call.py FindInventory '{"query":"RoadTech","type":"block","limit":5}'
python3 tools/call.py FindInventory '{"query":"LightCube","type":"item","limit":5}'
python3 tools/call.py RefreshInventory
python3 tools/call.py BrowseInventoryTree '{"root":"items","path":"Official","depth":5,"query":"LightCube","limit":35}'
python3 tools/call.py InspectMacroblockModel '{"index":0,"limit":5}'
python3 tools/call.py ListMacroblockInstances '{"recent":true,"limit":5}'
python3 tools/call.py PreflightNamedMacroblockPlacement '{"name":"stress-a","offsetX":32}'
python3 tools/call.py GetItems '{"limit":10}'
python3 tools/call.py GetRecentItems '{"count":5}'
python3 tools/call.py FindBlockModels '{"query":"TechnicsScreen","limit":5}'
python3 tools/call.py SelectBlockModel '{"blockName":"RoadTechStraight"}'
python3 tools/call.py PlaceBlockViaEditorPlusPlus '{"blockName":"RoadTechStraight","x":128,"y":64,"z":128,"pitch":12,"yaw":18,"roll":7,"repeat":8,"spacingX":30,"spacingY":6.4,"spacingZ":9.75}'
python3 tools/call.py GetRecentBlocks '{"count":8}'
python3 tools/call.py CreateNamedMacroblock '{"name":"stress-a","replace":true}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"stress-a","blockName":"RoadTechStraight","x":430,"y":128,"z":226,"pitch":12,"yaw":18,"roll":7}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"skin-a","blockName":"TechnicsScreen1x1Straight","x":900,"y":188,"z":560,"bgSkin":"Skins\\\\Stadium\\\\LightColors\\\\Pink.dds"}'
python3 tools/call.py AddBlocksToNamedMacroblock '{"name":"stress-a","blocks":[{"blockName":"RoadTechStraight","x":494,"y":142,"z":245,"yaw":30},{"blockName":"RoadTechStraight","x":526,"y":148,"z":254,"yaw":35}]}'
python3 tools/call.py AddItemToNamedMacroblock '{"name":"stress-a","itemPath":"LightCube4m","x":494,"y":142,"z":245,"yaw":30}'
python3 tools/call.py AddItemsToNamedMacroblock '{"name":"stress-a","items":[{"itemPath":"LightCube2m","x":510,"y":154,"z":250,"yaw":20}]}'
python3 tools/call.py GetNamedMacroblock '{"name":"stress-a","limit":5}'
python3 tools/call.py PlaceNamedMacroblock '{"name":"stress-a","offsetX":0,"offsetY":0,"offsetZ":0}'
python3 tools/call.py PlaceNamedMacroblock '{"name":"stress-a","offsetX":64,"yaw":25,"pivotX":430,"pivotY":128,"pivotZ":226}'
python3 tools/call.py CanPlaceBlock '{"blockName":"RoadTechStraight","x":24,"y":20,"z":24}'
python3 tools/call.py PlaceItemViaEditorPlusPlus '{"itemPath":"LightCube2m","x":710,"y":190,"z":320,"yaw":20}'
python3 tools/call.py ClearItems
python3 tools/call.py ClearBlocks
python3 tools/call.py ClearMapContent '{"includeTerrain":false}'
python3 tools/call.py RemoveRecentItems '{"count":1}'
python3 tools/call.py RemoveRecentBlocks '{"count":1}'
python3 tools/call.py RemoveBlocksByIndex '{"index":2307}'
python3 tools/call.py RemoveItemsByIndex '{"index":1,"forceBufferFallback":true}'
# Menu stack (main menu)
python3 tools/call.py ListKnownMenuRoutes
python3 tools/call.py GetMenuPage
python3 tools/call.py GetActiveMenuPages
python3 tools/call.py SetMenuPage '{"route":"/create"}'
python3 tools/call.py FindMenuButtons
python3 tools/call.py ClickMenuButton '{"controlId":"button-map-editor"}'
python3 tools/call.py ListGuides
python3 tools/call.py GetGuide '{"topic":"menu-navigation"}'
python3 tools/call.py BackToMainMenu
python3 tools/call.py EditNewMap '{"environment":"Stadium","decoration":"48x48Day"}'
# Full menu create flow (QuickStart off)
python3 tools/call.py CreateMapViaMenu '{"mapType":"race","environment":"Stadium","mood":"Day","inputDevice":"mouse","difficulty":"simple","timeoutMs":10000}'
python3 tools/call.py RunManialinkScript '{"script":"main() {}","context":"current"}'
```

## Behavioral notes

### Placement and map metadata

`CanPlaceBlock` checks normal grid or terrain block placement without mutating
the map. `PlaceBlock` uses no-destruction placement unless `allowDestruction`
is true. Prefer checking `canPlace` / `placed` and verifying with `GetBlockAt`;
raw editor undo can group adjacent direct API actions. Mutating placement tools
include `mapPre` and `mapPost` metadata with map name, size, block count, baked
block count, item count, and vertex count.

`GetMapInfo` and mutating tool map summaries include `bounds` in editor coords
and meters. Coord bounds are `[0,0,0]` through `size - 1`, with
`maxExclusive=size`. Meter bounds use 32m X/Z units, 8m Y units, and the usual
64m base-height offset; on a 48x40x48 map the Y max-exclusive is 256m.

`GetMapEnvironment` is a read-only vista/mood metadata probe. It reports the
challenge collection, decoration, map type/style, vehicle collection text,
editor mood time fields, and `PluginMapType` collection unit dimensions.

`SaveMapAs` saves the current editor map to a named `.Map.Gbx` under the user
`Maps` folder. Pass either `fileName` relative to `Maps`, or `name` plus
`folder`; for example `{"name":"stress-01","folder":"MCP","overwrite":true}`
saves as `MCP/stress-01.Map.Gbx`. The tool treats `SaveMap` returning without
exception as success and returns a Wine/Trackmania `gamePathHint`; external
Linux-side file checks should map that through the active Proton prefix.

### Dialogs, validation, selection

`GetDialog` / `RespondDialog` expose Trackmania `BasicDialogs` (unsaved map
prompts, etc.). `RespondDialog` accepts `yes`, `no`, `cancel`, `ok`, `wait-ok`,
`validate`, `saveas-cancel`, and `hide`.

`ControlValidation` exposes map validation and test/playground controls.
`ControlSelection` exposes editor copy-paste/custom selection.

### Cursor and camera

`GetCursor` returns the editor cursor **`coord`** (nat3 JSON array), `dir`, and
selected block `blockName` / `blockIdName` (from current or ghost block info).
It does not move the cursor.

`ControlCursor` uses the game’s cursor methods (no direct coordinate writes).
`action=move` with `direction` + `directionKind` (`relative` / cardinal /
cardinal8) is the supported way to nudge the cursor — relative moves are
intentional. Also: raise/lower, rotate, moveToCameraTarget, followCamera,
disableMouseDetection, releaseLock, setRGB/resetRGB.

`ControlCamera` reports API state and can center on cursor, move to map center,
watch whole map/start/closest finish/checkpoint, zoom, look, follow cursor,
ignore collisions, release lock, set V step. `GetEditorCamera` /
`SetEditorCamera` / `FocusCamera` remain for exact numeric control.

### Free placement and inventory

`PlaceBlockViaEditorPlusPlus` places free blocks through E++ macroblock
placement. Rotation inputs are degrees by default (`pitch`, `yaw`, `roll`);
use `pitchRad`, `yawRad`, or `rollRad` for radians. Placement autofocus is on by
default; pass `autofocus=false` or `autofocusDistance` (default 60).

`PlaceItemViaEditorPlusPlus` places flying items through E++ item placement
(inventory paths from `FindInventory`; same rotation/repeat/autofocus options).

`FindInventory` searches loaded block models, macroblock models, and E++ item
inventory. `RefreshInventory` rescans after the user adds items mid-session
(cache is normally scanned once on editor load). `BrowseInventoryTree` is
read-only hierarchy browse.

`InspectMacroblockModel` resolves a loaded macroblock and converts via E++
`MakeMacroblockSpec` (block skins not currently exposed). `ListMacroblockInstances`
lists native placed instances — E++ placement may materialize blocks/items
without leaving native instances (`total=0` can be valid).

### Named macroblocks

Named macroblock tools keep E++ `MacroblockSpec` handles in plugin memory.
They support free block specs, flying item specs, and placement-time translation
and rotation around a world-space pivot. Free block specs accept `variant`,
`bgSkin`, and `fgSkin`; item specs also accept skins. Skins apply after
`PlaceNamedMacroblock` succeeds. Handles are in-memory only and clear on plugin
reload. Prefer `AddBlocksToNamedMacroblock` / `AddItemsToNamedMacroblock` for
generated builds. `PreflightNamedMacroblockPlacement` is non-mutating.

### Item delete via `Editor::DeleteItems`

`RemoveRecentItems` and `RemoveItemsByIndex` call **`Editor::DeleteItems`**
(E++: macroblock donor + `RemoveMacroblock` with `Initialized`/`Connected` set
true). That path works when `PluginMapType.Items` is empty.

- Default: `forceBufferFallback=false`.
- On success: response includes `method=DeleteItems`, `undoSupported=true`,
  `deleted=true`, plus `mapPre`/`mapPost` and `removed` entries.
- Direct `AnchoredObjects` buffer removal is **opt-in only** via
  `forceBufferFallback=true`. That path reports `undoSupported=false` and is
  cleanup tooling, not normal undoable deletion. After buffer cleanup,
  save-reload is the cheapest full reset.

```bash
python3 tools/call.py RemoveRecentItems '{"count":1,"forceBufferFallback":false}'
# → deleted=true, method=DeleteItems, undoSupported=true (when OK)
```

`RemoveRecentBlocks` / `RemoveBlocksByIndex` use E++ freeblock deletion queue
and `DeleteBlocks` for non-free blocks.

`ClearBlocks` / `ClearItems` / `ClearMapContent` call PluginMapType remove-all
methods directly (`RemoveAllBlocks`, `RemoveAllObjects`, or
`RemoveAllBlocksAndTerrain` when `includeTerrain=true`).

### Screenshots

`TakeScreenshot` triggers Trackmania’s built-in viewport capture. Through
`tools/call.py`, the caller indexes the Wine user game folder before/after,
waits for the async write, and may add `detectedScreenshot.linuxPath` / `size`.
Default Linux lookup is the Steam Proton prefix for app `2225070`; set
`TM_USER_GAME_FOLDER` for other installs.

### Menu automation details

- **Routes are hierarchical.** Pass `/create/mapeditorsettings`, not
  `/mapeditorsettings`. Use `ListKnownMenuRoutes` and the `menu-navigation`
  guide.
- **`SetMenuPage`** only works while the main-menu module is active
  (`GetMode` / `GetMenuPage`). Known playground-launching routes (e.g.
  `/solo/campaigndisplay`) are blocked unless `allowPlaygroundLaunch:true`.
- **Clicks:** `ClickMenuButton` / `TriggerControlOnAction` invoke
  `CControlBase::OnAction` (same dispatch as a real click). Do **not** use
  `TriggerPageAction` — it crashes. For Nadeo expendable-button nav-items the
  leaf is often the `component-navigation-item-zone` under the button.
- **Observe:** after push/click, poll `GetActiveMenuPages`, `GetMode`,
  `GetDialog`.
- **Enter editor:**
  - Fast path: `EditNewMap` (title-control `EditNewMap2`) or
    `SetMenuPage` + `EditNewMap`.
  - Full UI path: `CreateMapViaMenu` (SetMenuPage + 6 OnAction clicks; QuickStart
    must be off). Verified click-chain 2026-04-20.
- **Leave editor/race:** `BackToMainMenu`, then poll until `mode=="Menu"`.
- Layer introspection: `GetUILayers` → `GetLayerTree` / `GetLayerXml` /
  `FindMenuButtons` / `FindControlsByClass` / `FindControlsByLabel` /
  `InspectMenuControl`.

### Guides

`ListGuides` / `GetGuide` expose in-plugin docs (topics include
`menu-navigation`, `map-vistas`, `item-skins`, `block-skins`,
`macroblock-placement`, `crash-debugging`, `item-placement-debris`).

### DEV tools

`RunGizmoApplyBlock`, `RunRandomFuzz`, `RunComputeItemsDiagnostic`,
`DevSafeRead`, `DevGetPointers`, `DevComputeItemsPointers`, and
`DumpMacroblockHeader` are diagnostics/RE helpers. Prefer them for crash
investigation and pointer layout work; they are not required for normal map
authoring flows.
