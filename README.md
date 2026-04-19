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

Current tools:

- `GetMode`
- `OpenMapInEditor`
- `GetMapInfo`
- `SaveMapAs`
- `GetDialog`
- `RespondDialog`
- `ControlValidation`
- `ControlSelection`
- `GetCursor`
- `GetEditorSelectionState`
- `ControlCursor`
- `GetEditorCamera`
- `SetEditorCamera`
- `ControlCamera`
- `FocusCamera`
- `TakeScreenshot`
- `GetBlocks`
- `GetRecentBlocks`
- `GetBlockAt`
- `GetItems`
- `GetRecentItems`
- `GetInventorySummary`
- `FindInventory`
- `BrowseInventoryTree`
- `InspectMacroblockModel`
- `ListMacroblockInstances`
- `FindBlockModels`
- `RunGizmoApplyBlock`
- `CreateNamedMacroblock`
- `GetNamedMacroblock`
- `ListNamedMacroblocks`
- `ClearNamedMacroblock`
- `AddBlockToNamedMacroblock`
- `AddBlocksToNamedMacroblock`
- `AddItemToNamedMacroblock`
- `AddItemsToNamedMacroblock`
- `PlaceNamedMacroblock`
- `PreflightNamedMacroblockPlacement`
- `CanPlaceBlock`
- `PlaceBlock`
- `PlaceBlockViaEditorPlusPlus`
- `PlaceItemViaEditorPlusPlus`
- `RemoveBlock`
- `ClearBlocks`
- `ClearItems`
- `ClearMapContent`
- `RemoveRecentBlocks`
- `RemoveRecentItems`
- `RemoveBlocksByIndex`
- `RemoveItemsByIndex`
- `SelectBlockModel`
- `SetCursorBlock`
- `Undo`
- `Redo`

## Quick Test

`tools/call.py` checks for a real Wine/Proton `Trackmania.exe` process before
opening the socket on every route, including `status` and `tools`. This avoids
waiting on a stale wrapper or frozen plugin when the game is not actually
running. Use `--skip-process-check` only for raw socket debugging.

```bash
./build.sh dev
python3 tools/call.py status
python3 tools/call.py --pretty status
python3 tools/call.py GetMode
python3 tools/call.py GetMapInfo
python3 tools/call.py SaveMapAs '{"name":"codex-save-test","folder":"MCP","overwrite":true}'
python3 tools/call.py GetDialog
python3 tools/call.py RespondDialog '{"action":"no"}'
python3 tools/call.py ControlValidation '{"action":"status"}'
python3 tools/call.py ControlSelection '{"action":"status"}'
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
python3 tools/call.py BrowseInventoryTree '{"root":"items","path":"Official","depth":5,"query":"LightCube","limit":35}'
python3 tools/call.py InspectMacroblockModel '{"index":0,"limit":5}'
python3 tools/call.py ListMacroblockInstances '{"recent":true,"limit":5}'
python3 tools/call.py PreflightNamedMacroblockPlacement '{"name":"stress-a","offsetX":32}'
python3 tools/call.py GetItems '{"limit":10}'
python3 tools/call.py GetRecentItems '{"count":5}'
python3 tools/call.py FindBlockModels '{"query":"TechnicsScreen","limit":5}'
python3 tools/call.py SelectBlockModel '{"blockName":"RoadTechStraight"}'
python3 tools/call.py GetCursor
python3 tools/call.py PlaceBlockViaEditorPlusPlus '{"blockName":"RoadTechStraight","x":128,"y":64,"z":128,"pitch":12,"yaw":18,"roll":7,"repeat":8,"spacingX":30,"spacingY":6.4,"spacingZ":9.75}'
python3 tools/call.py GetRecentBlocks '{"count":8}'
python3 tools/call.py CreateNamedMacroblock '{"name":"stress-a","replace":true}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"stress-a","blockName":"RoadTechStraight","x":430,"y":128,"z":226,"pitch":12,"yaw":18,"roll":7}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"skin-a","blockName":"TechnicsScreen1x1Straight","x":900,"y":188,"z":560,"bgSkin":"Skins\\\\Stadium\\\\LightColors\\\\Pink.dds"}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"stress-a","blockName":"RoadTechStraight","x":462,"y":134.4,"z":235.75,"pitch":12,"yaw":18,"roll":7}'
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
```

`tools/call.py` returns compact JSON by default. Use `--pretty` when reading
responses manually. It returns compact JSON errors if Trackmania or the plugin
socket is unavailable.

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
editor mood time fields, and `PluginMapType` collection unit dimensions. Use it
before adding any map-type/style or mood mutation tooling.

`SaveMapAs` saves the current editor map to a named `.Map.Gbx` under the user
`Maps` folder. Pass either `fileName` relative to `Maps`, or `name` plus
`folder`; for example `{"name":"stress-01","folder":"MCP","overwrite":true}`
saves as `MCP/stress-01.Map.Gbx`. The tool treats `SaveMap` returning without
exception as success and returns a Wine/Trackmania `gamePathHint`; external
Linux-side file checks should map that through the active Proton prefix.

`GetDialog` and `RespondDialog` expose Trackmania's `BasicDialogs` state. This
is useful when editor automation hits in-game prompts such as unsaved map
confirmation. `RespondDialog` accepts `yes`, `no`, `cancel`, `ok`, `wait-ok`,
`validate`, `saveas-cancel`, and `hide`.

`ControlValidation` exposes map validation and test/playground controls. Use
`action=status` for read-only validation state. Deliberate mutating actions are
`validate`, `requestEnterPlayground`, `requestLeavePlayground`, `testFromStart`,
and `testFromCoord`.

`ControlSelection` exposes editor copy-paste/custom selection controls. Use
`action=status` for read-only selection state and selected coord counts.
Deliberate mutating actions include `showCustom`, `hideCustom`,
`resetSelection`, `selectAll`, `addSelection`, `copy`, `cut`, `remove`, and
`symmetrize`.

`ControlCamera` exposes the editor camera API. It can report camera API state,
center on the cursor, move to map center, watch the whole map/start/closest
finish/checkpoint, zoom, look cardinal or cardinal8 directions, follow the
cursor, ignore camera collisions, release the camera lock, and set vertical
step. `GetEditorCamera`, `SetEditorCamera`, and `FocusCamera` remain available
for exact numeric camera control.

`ControlCursor` exposes the editor cursor API. It can report cursor API state
with `action=status`, move relative/cardinal/cardinal8 directions, rotate,
raise/lower, move to the camera target, follow the camera target, disable mouse
detection, release the cursor lock, and set/reset custom cursor RGB. It avoids
direct coordinate writes for now and uses the game's cursor methods instead.

`PlaceBlockViaEditorPlusPlus` places free blocks through E++ macroblock
placement. Rotation inputs are degrees by default (`pitch`, `yaw`, `roll`);
use `pitchRad`, `yawRad`, or `rollRad` for radians. `GetRecentBlocks` includes
freeblock `pos`, `rot`, `rotDeg`, and `isFree` readback for verification.
Placement autofocus is enabled by default; pass `autofocus=false` to skip it or
`autofocusDistance` to change the default distance of 60.

`FindInventory` searches loaded block models, macroblock models, and E++ item
inventory wrapper exports. Use `type` as `block`, `item`, `macroblock`, or
`all`. Item results return inventory paths suitable for item placement tools.
`BrowseInventoryTree` reads the editor inventory hierarchy without selecting or
opening anything. It accepts `root` (`root`, `current`, `blocks`, `items`,
`macroblocks`, etc.), optional `rootIndex`, slash-separated `path`, `depth`,
`limit`, `query`, and `includeArticles`.
`InspectMacroblockModel` resolves a loaded macroblock model by `name`, `path`,
or `index`, then converts it through E++ `MakeMacroblockSpec` to return block
and item specs. It does not currently expose block skins.
`ListMacroblockInstances` lists native placed macroblock instances from the
editor API. E++ macroblock placement can still materialize blocks/items without
leaving native macroblock instances behind, so `total=0` is valid on those maps.
`FindBlockModels` includes block variant counts and base sizes, which is useful
for choosing nonzero variants for macroblock stress tests.
`SetCursorBlock` is an alias for `SelectBlockModel`, which sets the editor's
normal and ghost selected block model through E++ exports.
`GetEditorSelectionState` is a read-only snapshot of gizmo-relevant editor
state: placement modes, picked block, selected block models, cursor coordinate,
and current block variant.
`RunGizmoApplyBlock` is a DEV diagnostic for the actual E++ gizmo block-apply
path. It is useful for macroblock/gizmo crash regression tests because it calls
the same apply function without marker files or manual cursor interaction.

Named macroblock tools keep E++ `MacroblockSpec` handles in plugin memory.
They support free block specs, flying item specs, and placement-time translation
and rotation around a world-space pivot. Rotation inputs are degrees by default;
use `pitchRad`, `yawRad`, or `rollRad` for radians. Free block specs accept
`variant`, `bgSkin`, and `fgSkin`; item specs also accept `bgSkin` and `fgSkin`.
Skins are applied directly to newly inserted map blocks/items after
`PlaceNamedMacroblock` succeeds. Skin application is verified against the placed
block/item skin fields; unsupported targets report `skinsApplied=false` with a
per-target error. These named handles are in-memory only and are cleared when TM
Control MCP reloads.
Use `AddBlocksToNamedMacroblock` and `AddItemsToNamedMacroblock` for generated
builds; they avoid one socket round trip per block/item.
`PreflightNamedMacroblockPlacement` accepts the same transform inputs without
mutating the map, then reports world extents, map bounds issues, missing models,
and invalid variants.

`PlaceItemViaEditorPlusPlus` places flying items through E++ item placement.
It accepts item inventory paths from `FindInventory`, degree or radian rotation
inputs, `repeat` plus spacing arguments, `variant`, `addUndo`, and the same
autofocus options as block placement.

`RemoveRecentBlocks` deletes the last N blocks. Freeblocks use E++'s
freeblock deletion queue; non-free blocks fall back to E++ `DeleteBlocks`.
`RemoveBlocksByIndex` uses the same deletion paths for explicit map block
indices.

`ClearBlocks`, `ClearItems`, and `ClearMapContent` call the editor
`PluginMapType` clear methods directly. `ClearBlocks` uses `RemoveAllBlocks()`;
`ClearItems` uses `RemoveAllObjects()`; `ClearMapContent` uses both, or
`RemoveAllBlocksAndTerrain()` plus `RemoveAllObjects()` when
`includeTerrain=true`. These tools return `mapPre` / `mapPost` summaries.

`RemoveRecentItems` and `RemoveItemsByIndex` first try E++ `DeleteItems`.
Direct `AnchoredObjects` buffer removal is available only with
`forceBufferFallback=true`, reports `undoSupported=false`, and should be used
as cleanup tooling rather than normal user-facing undoable deletion.

`TakeScreenshot` triggers Trackmania's built-in viewport screenshot capture.
When called through `tools/call.py`, the caller indexes the Wine user game
folder before and after the request, waits briefly for the async write, and
adds `detectedScreenshot.linuxPath` / `size` to the response when it can find
the new file. The default Linux lookup path is the Steam Proton prefix for app
`2225070`; set `TM_USER_GAME_FOLDER` to the active Trackmania documents folder
for other Wine/Proton installs.
