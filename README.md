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
- `GetCursor`
- `GetEditorCamera`
- `SetEditorCamera`
- `FocusCamera`
- `TakeScreenshot`
- `GetBlocks`
- `GetRecentBlocks`
- `GetBlockAt`
- `GetItems`
- `GetRecentItems`
- `GetInventorySummary`
- `FindInventory`
- `FindBlockModels`
- `CreateNamedMacroblock`
- `GetNamedMacroblock`
- `ListNamedMacroblocks`
- `ClearNamedMacroblock`
- `AddBlockToNamedMacroblock`
- `AddItemToNamedMacroblock`
- `PlaceNamedMacroblock`
- `PlaceBlock`
- `PlaceBlockViaEditorPlusPlus`
- `PlaceItemViaEditorPlusPlus`
- `RemoveBlock`
- `RemoveRecentBlocks`
- `RemoveRecentItems`
- `RemoveBlocksByIndex`
- `RemoveItemsByIndex`
- `SelectBlockModel`
- `SetCursorBlock`
- `Undo`
- `Redo`

## Quick Test

```bash
./build.sh dev
python3 tools/call.py status
python3 tools/call.py GetMode
python3 tools/call.py GetMapInfo
python3 tools/call.py SaveMapAs '{"name":"codex-save-test","folder":"MCP","overwrite":true}'
python3 tools/call.py GetDialog
python3 tools/call.py RespondDialog '{"action":"no"}'
python3 tools/call.py GetEditorCamera
python3 tools/call.py FocusCamera '{"x":338,"y":108.8,"z":196.25,"distance":60}'
python3 tools/call.py TakeScreenshot '{"format":"jpg"}'
python3 tools/call.py GetInventorySummary
python3 tools/call.py FindInventory '{"query":"RoadTech","type":"block","limit":5}'
python3 tools/call.py FindInventory '{"query":"LightCube","type":"item","limit":5}'
python3 tools/call.py GetItems '{"limit":10}'
python3 tools/call.py GetRecentItems '{"count":5}'
python3 tools/call.py FindBlockModels '{"query":"TechnicsScreen","limit":5}'
python3 tools/call.py SelectBlockModel '{"blockName":"RoadTechStraight"}'
python3 tools/call.py GetCursor
python3 tools/call.py PlaceBlockViaEditorPlusPlus '{"blockName":"RoadTechStraight","x":128,"y":64,"z":128,"pitch":12,"yaw":18,"roll":7,"repeat":8,"spacingX":30,"spacingY":6.4,"spacingZ":9.75}'
python3 tools/call.py GetRecentBlocks '{"count":8}'
python3 tools/call.py CreateNamedMacroblock '{"name":"stress-a","replace":true}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"stress-a","blockName":"RoadTechStraight","x":430,"y":128,"z":226,"pitch":12,"yaw":18,"roll":7}'
python3 tools/call.py AddBlockToNamedMacroblock '{"name":"stress-a","blockName":"RoadTechStraight","x":462,"y":134.4,"z":235.75,"pitch":12,"yaw":18,"roll":7}'
python3 tools/call.py AddItemToNamedMacroblock '{"name":"stress-a","itemPath":"LightCube4m","x":494,"y":142,"z":245,"yaw":30}'
python3 tools/call.py GetNamedMacroblock '{"name":"stress-a","limit":5}'
python3 tools/call.py PlaceNamedMacroblock '{"name":"stress-a","offsetX":0,"offsetY":0,"offsetZ":0}'
python3 tools/call.py PlaceNamedMacroblock '{"name":"stress-a","offsetX":64,"yaw":25,"pivotX":430,"pivotY":128,"pivotZ":226}'
python3 tools/call.py PlaceItemViaEditorPlusPlus '{"itemPath":"LightCube2m","x":710,"y":190,"z":320,"yaw":20}'
python3 tools/call.py RemoveRecentItems '{"count":1}'
python3 tools/call.py RemoveRecentBlocks '{"count":1}'
python3 tools/call.py RemoveBlocksByIndex '{"index":2307}'
python3 tools/call.py RemoveItemsByIndex '{"index":1,"forceBufferFallback":true}'
```

`PlaceBlock` uses no-destruction placement unless `allowDestruction` is true.
Prefer checking `canPlace` / `placed` and verifying with `GetBlockAt`; raw editor
undo can group adjacent direct API actions. Mutating placement tools include
`mapPre` and `mapPost` metadata with map name, size, block count, baked block
count, item count, and vertex count.

`GetMapInfo` and mutating tool map summaries include `bounds` in editor coords
and meters. Coord bounds are `[0,0,0]` through `size - 1`, with
`maxExclusive=size`. Meter bounds use 32m X/Z units, 8m Y units, and the usual
64m base-height offset; on a 48x40x48 map the Y max-exclusive is 256m.

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

`PlaceBlockViaEditorPlusPlus` places free blocks through E++ macroblock
placement. Rotation inputs are degrees by default (`pitch`, `yaw`, `roll`);
use `pitchRad`, `yawRad`, or `rollRad` for radians. `GetRecentBlocks` includes
freeblock `pos`, `rot`, `rotDeg`, and `isFree` readback for verification.
Placement autofocus is enabled by default; pass `autofocus=false` to skip it or
`autofocusDistance` to change the default distance of 60.

`FindInventory` searches loaded block models, macroblock models, and E++ item
inventory wrapper exports. Use `type` as `block`, `item`, `macroblock`, or
`all`. Item results return inventory paths suitable for item placement tools.
`SetCursorBlock` is an alias for `SelectBlockModel`, which sets the editor's
normal and ghost selected block model through E++ exports.

Named macroblock tools keep E++ `MacroblockSpec` handles in plugin memory.
They support free block specs, flying item specs, and placement-time translation
and rotation around a world-space pivot. Rotation inputs are degrees by default;
use `pitchRad`, `yawRad`, or `rollRad` for radians. These named handles are
in-memory only and are cleared when TM Control MCP reloads.

`PlaceItemViaEditorPlusPlus` places flying items through E++ item placement.
It accepts item inventory paths from `FindInventory`, degree or radian rotation
inputs, `repeat` plus spacing arguments, `variant`, `addUndo`, and the same
autofocus options as block placement.

`RemoveRecentBlocks` deletes the last N blocks. Freeblocks use E++'s
freeblock deletion queue; non-free blocks fall back to E++ `DeleteBlocks`.
`RemoveBlocksByIndex` uses the same deletion paths for explicit map block
indices.

`RemoveRecentItems` and `RemoveItemsByIndex` first try E++ `DeleteItems`.
Direct `AnchoredObjects` buffer removal is available only with
`forceBufferFallback=true`, reports `undoSupported=false`, and should be used
as cleanup tooling rather than normal user-facing undoable deletion.

`TakeScreenshot` triggers Trackmania's built-in viewport screenshot capture.
The write is asynchronous; on the current Wine/Steam install the file appears
under the user game folder as `ScreenShotNN.jpg`.
