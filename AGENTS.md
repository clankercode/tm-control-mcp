## Project Notes

Local Openplanet bridge (`tm-control-mcp`) exposing Trackmania editor/menu control over a localhost JSON socket (`127.0.0.1:30006`). Sibling of E++; hard deps `MLHook` + `MLFeedRaceData`; `Editor` is optional.

### Build / reload

- Use `./build.sh dev` for every change: runs `openplanet-lsp`, stages to `~/OpenplanetNext/Plugins/tm-control-mcp`, reloads via RemoteBuild.
- **Before any release tag:** `TM_PLUGIN_SKIP_LSP=1 ./build.sh release-check` (stage **without** DEV defines, reload, confirm green). See `RELEASE.md`.
- If `openplanet-lsp` floods nested-enum / dependency false positives, `TM_PLUGIN_SKIP_LSP=1 ./build.sh dev` is OK when the **in-game Openplanet compile is green**.
- `info.toml` `[script] timeout = 15000` (ms). Long tools need this headroom; raise + rebuild if Openplanet kills the script.
- Server host/port/enable are Openplanet **Settings → TM Control MCP → Server / Socket**. Changes apply live (no reload). `S_TmMcpEnableSocket` is hidden; toggle via the Socket tab, `SetSocketEnabled`, or `SetPluginSetting`.
- **DEV tools:** only with `./build.sh dev` (`#if DEV`). Release builds omit DevSafeRead/fuzz/etc.
- Security: localhost-only, no auth — `SECURITY.md`.
- Live smoke when game up: `python3 tools/smoke_tag_cleanup.py`
- Socket lifecycle (exports + enable/disable): `python3 tools/verify_socket_lifecycle.py`
- `tools/call.py` returns compact JSON by default and checks for a real `Trackmania.exe` process before socket calls (`--skip-process-check` only for raw socket debug).
- Wait helpers: `--wait-mode Editor|MapEditor|Menu|Race`, `--until-ready editor|menu|any`, `--wait-timeout 30`. `--wait-mode Editor` matches any editor kind (`MapEditor`, `ItemEditor`, `MediatrackerEditor`, …).

### Placement / macroblocks

- Prefer `AddBlocksToNamedMacroblock` and `AddItemsToNamedMacroblock` over one add call per block/item.
- Named macroblock block specs support `variant`, `bgSkin`, and `fgSkin`; skins are applied after `PlaceNamedMacroblock` and verified (`skinsApplied`).
- Durable named MBs: `SaveNamedMacroblock` / `LoadNamedMacroblock` / `ListSavedNamedMacroblocks` (JSON under Openplanet data `tm-control-mcp/named-mb/`).
- Prefer E++ free placement (`PlaceBlockViaEditorPlusPlus`, named macroblocks) over raw grid `PlaceBlock` for freeblock work.

### Landed control surface (high-signal)

- **Readiness:** `GetReadiness` + `WaitUntil` (mode/dialog/editorReady/pageVisible/map counts/readiness/shadowsClear). Prefer before mutate. `GetLightmapComputeState` / `WaitUntil condition=shadowsClear` before plugin reloads during an LM bake.
- **Frame time:** `MeasureFrameTime {frames:10}` yields N frames (default 10, warmup 1) and returns `elapsedMs` / `msPerFrame` / `fps`. 30fps cap ⇒ 10 frames ~333ms; 10 frames ~3000ms is a hitch.
- **LM bake:** `SetMoodTimeOfDay {timeOfDay01}` then `ComputeShadows` (`quality` default Default, `bustCache` default true; does not wait). Change TOD between bakes — the game refuses a second bake if shadows are already cached for that mood. Wait with `WaitUntil condition=shadowsClear`.
- **Editor preflight / control:** `CanPlaceBlock`, `ControlCursor`, `ControlValidation`, `ControlCamera`, `ControlSelection`, `GetEditorSelectionState`, **`ControlEditMode`**.
- **In-play camera:** **`ControlPlayCamera`** — `get` / `set_mode` (free, cam1-3, backwards, alt, drivable) /
  `set_position`. Pass `x,y,z` **and** `target{x,y,z}` for an exact camera point + look-at; angles alone do
  not rotate the view. `set_mode` can be silently dropped — check `switched`, not `success`. Editor camera is
  still `SetEditorCamera` / `ControlCamera`.
- **Cursor:** `GetCursor` / `ControlCursor` relative/cardinal — absolute optional.
- **Item delete:** `RemoveRecentItems` / `RemoveItemsByIndex` → E++ `DeleteItems`. Prefer **`SetAgentTag` + `RemoveByTag`** for agent smoke cleanup.
- **Inventory:** browse tools + **`ControlInventory`**. Path-place still preferred for headless placement.
- **Menu automation (OnAction):** `ClickMenuButton`, `CreateMapViaMenu`. Never `TriggerPageAction`.
- **AssertPlacement:** verify deltas / near{x,y,z} / tags after place.
- `ListPlugins`, `ControlPlugin`, `ListPluginSettings`, `SetPluginSetting`, `ListToolPacks`.
- **Type info:** `GetTypeInfo {className}` — class + all members via Openplanet Reflection. `ownOnly` / `member` / `query` / `from=app|editor|challenge|cursor|pluginMap`. No member type names (live API limit).
- **Fids:** `ControlFids` — `drives` / `get` / `list` / `preload` / `updateTree` / `extract` / `getFullPath` / `fromNod`. Drive `game|user|fake|resource|programData`, path drive-relative. `fromNod` takes `from_ptr` (nod pointer from `nod.ptr` or another tool), not `from=app|editor`. `updateTree` on empty game path needs `force`. `extract` writes to disk. Guide: `fids`.
- **Tool packs:** other plugins register via `TmMcp::ToolPackBuilder` + `RegisterToolPack`. Names are `packId.FuncName`. Optional `ToolPackBuilder("id")` / `SetPackId` sets the prefix (default = plugin id). See `docs/tool-packs.md`.
- **Guides:** `ListGuides` / `GetGuide`.

### RunManialinkScript

- MLHook inject: `menu` / `in-map` / `in-editor` / `current`.
- Params: `script`, `pageUid`, `replace`, `persist`, `waitMs`, **`collectMs`**, **`resultEvent`**.
- Result channel: script `SendCustomEvent("MLHook_Event_McpAdHoc_Result", [...])`; response `results[]`.

### Open product themes (still future / partial)

- Broader mood/style mutation beyond `SetMoodTimeOfDay` (prefer CreateMapViaMenu for new maps).
- Native `.Macroblock.Gbx` round-trip beyond JSON durable specs.
- Absolute cursor set (optional).

### Agent habits

- Smoke: `GetReadiness want=editor` or `call.py --until-ready editor GetMode`.
- After menu nav: `WaitUntil condition=pageVisible` / GetMode.
- Tag places: `SetAgentTag` then place; cleanup with `RemoveByTag`.
- Do not depend on old disabled `mcp-tm` / `tm-mcptm` library plugins.
