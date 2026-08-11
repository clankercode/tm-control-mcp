## Project Notes

Local Openplanet bridge (`tm-control-mcp`) exposing Trackmania editor/menu control over a localhost JSON socket (`127.0.0.1:30006`). Sibling of E++; depends on `Editor` + `MLHook`.

### Build / reload

- Use `./build.sh dev` for every change: runs `openplanet-lsp`, stages to `~/OpenplanetNext/Plugins/tm-control-mcp`, reloads via RemoteBuild.
- If `openplanet-lsp` floods nested-enum / dependency false positives, `TM_PLUGIN_SKIP_LSP=1 ./build.sh dev` is OK when the **in-game Openplanet compile is green**.
- `tools/call.py` returns compact JSON by default and checks for a real `Trackmania.exe` process before socket calls (`--skip-process-check` only for raw socket debug).

### Placement / macroblocks

- Prefer `AddBlocksToNamedMacroblock` and `AddItemsToNamedMacroblock` over one add call per block/item.
- Named macroblock block specs support `variant`, `bgSkin`, and `fgSkin`; skins are applied after `PlaceNamedMacroblock` and verified (`skinsApplied`).
- `FindBlockModels` and block readback include variant counts/indices; use them for cross-theme / Vista-ish blocks.
- Prefer E++ free placement (`PlaceBlockViaEditorPlusPlus`, named macroblocks) over raw grid `PlaceBlock` for freeblock work.
- When adding editor-control tools, prefer source-of-truth docs under `~/scrape/openplanet/next`, especially `Game/CGameCtnEditorFree.md`, `ShootMania/CSmEditorPluginMapType.md`, `Game/CGameEditorPluginCameraAPI.md`, `Game/CGameEditorPluginCursorAPI.md`, and `Game/CGameEditorGenericInventory.md`.

### Landed control surface (high-signal)

- **Editor preflight / control:** `CanPlaceBlock`, `ControlCursor`, `ControlValidation`, `ControlCamera`, `ControlSelection`, `GetEditorSelectionState`. Prefer `action=status` / preflight before mutating.
- **Cursor:** `GetCursor` exists. `ControlCursor` uses relative/cardinal moves, raise/lower, rotate, camera-target follow — **absolute coord set is optional / not required** for current workflows (avoid inventing direct coord writes unless needed).
- **Item delete (LANDED):** `RemoveRecentItems` / `RemoveItemsByIndex` call E++ `Editor::DeleteItems` (macroblock donor + `RemoveMacroblock` with `Initialized`/`Connected` set true). Reports `method=DeleteItems`, `undoSupported=true`. Direct `AnchoredObjects` buffer removal is opt-in only (`forceBufferFallback=true`).
- **Menu automation (LANDED — OnAction path):** `ClickMenuButton`, `TriggerControlOnAction`, `CreateMapViaMenu`, plus discovery (`GetUILayers`, `GetActiveMenuPages`, `FindMenuButtons`, `GetLayerTree`, `ListMenuManialinkControls`, …) and routing (`SetMenuPage`, `ListKnownMenuRoutes`, `BackToMainMenu`). Clicks fire `CControlBase::OnAction` on the nav-zone leaf — same dispatch as a real click. Do **not** call `TriggerPageAction` from Angelscript (native crash).
- **BlueBay / vista create:** when the game is at the main menu and you need a specific environment/mood for E++ work, use `CreateMapViaMenu` (full Page_MapEditorSettings click-chain). `EditNewMap` remains a title-control shortcut for simpler Environment/Decoration/MapType creates.
- **Inventory browse (read-only):** `BrowseInventoryTree`, `FindInventory`, `GetInventorySummary`, `RefreshInventory`. No select/open mutation yet.
- **Map metadata (read-only):** `GetMapEnvironment` (collection, decoration, mood time, map type/style). Mood/type mutation only if a concrete regression needs it.
- **Guides:** `ListGuides` / `GetGuide` for in-plugin operator docs.

### RunManialinkScript (prefer as generalizer)

- Tool: `RunManialinkScript` (`src/ManialinkRunner.as`) — MLHook inject into `menu` / `in-map` / `in-editor` (or `context=current`).
- Params: `script` (required; no outer `<manialink>`), optional `pageUid` (default `McpAdHoc`), `replace` (default true), `persist` (default true), `waitMs` (default 150).
- Fire-and-forget; sandboxed ML pages; no automatic return channel; bad script can trip game recovery.
- **Prefer this over inventing many one-off menu/game-state mutators** when agents need custom ManiaScript (TitleControl, local game objects, limited UI).
- Do not treat research notes that say “ClickMenuButton is poisoned” as current truth — that was `TriggerPageAction`; OnAction path is the landed click path.

### Open product themes (still future / partial)

Keep these as open themes, not “missing scaffold work”:

- Richer inventory: **select / open / set current article** (browse is done).
- Metadata inspection/mutation beyond read-only `GetMapEnvironment` (mood/style only if needed).
- Map/macroblock lifecycle helpers still thin in places (e.g. native macroblock instance semantics vs E++ materialize-without-instances).
- Absolute cursor set (optional).
- Docs lag: keep README / research aligned when tools land (menu OnAction, DeleteItems, RunManialinkScript).

### Agent habits

- Smoke with `python3 tools/call.py status` / `tools` / `GetMode` before mutating.
- After menu navigations, poll `GetActiveMenuPages` / `GetMode` / `GetDialog`.
- Prefer batch named-macroblock APIs for generated content.
- Do not depend on the old disabled `mcp-tm` / `tm-mcptm` library plugins.
