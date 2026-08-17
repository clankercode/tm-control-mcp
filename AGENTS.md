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
- Wait helpers: `--wait-mode Editor|Menu|Race`, `--until-ready editor|menu|any`, `--wait-timeout 30`.

### Placement / macroblocks

- Prefer `AddBlocksToNamedMacroblock` and `AddItemsToNamedMacroblock` over one add call per block/item.
- Named macroblock block specs support `variant`, `bgSkin`, and `fgSkin`; skins are applied after `PlaceNamedMacroblock` and verified (`skinsApplied`).
- Durable named MBs: `SaveNamedMacroblock` / `LoadNamedMacroblock` / `ListSavedNamedMacroblocks` (JSON under Openplanet data `tm-control-mcp/named-mb/`).
- Prefer E++ free placement (`PlaceBlockViaEditorPlusPlus`, named macroblocks) over raw grid `PlaceBlock` for freeblock work.

### Landed control surface (high-signal)

- **Readiness:** `GetReadiness` + `WaitUntil` (mode/dialog/editorReady/pageVisible/map counts/readiness). Prefer before mutate.
- **Editor preflight / control:** `CanPlaceBlock`, `ControlCursor`, `ControlValidation`, `ControlCamera`, `ControlSelection`, `GetEditorSelectionState`, **`ControlEditMode`**.
- **Cursor:** `GetCursor` / `ControlCursor` relative/cardinal — absolute optional.
- **Item delete:** `RemoveRecentItems` / `RemoveItemsByIndex` → E++ `DeleteItems`. Prefer **`SetAgentTag` + `RemoveByTag`** for agent smoke cleanup.
- **Inventory:** browse tools + **`ControlInventory`**. Path-place still preferred for headless placement.
- **Menu automation (OnAction):** `ClickMenuButton`, `CreateMapViaMenu`. Never `TriggerPageAction`.
- **AssertPlacement:** verify deltas / near{x,y,z} / tags after place.
- `ListPlugins`, `ControlPlugin`, `ListPluginSettings`, `SetPluginSetting`, `ListToolPacks`.
- **Tool packs:** other plugins register via `TmMcp::ToolPackBuilder` + `RegisterToolPack`. Names are `packId.FuncName`. Optional `ToolPackBuilder("id")` / `SetPackId` sets the prefix (default = plugin id). See `docs/tool-packs.md`.
- **Guides:** `ListGuides` / `GetGuide`.

### RunManialinkScript

- MLHook inject: `menu` / `in-map` / `in-editor` / `current`.
- Params: `script`, `pageUid`, `replace`, `persist`, `waitMs`, **`collectMs`**, **`resultEvent`**.
- Result channel: script `SendCustomEvent("MLHook_Event_McpAdHoc_Result", [...])`; response `results[]`.

### Open product themes (still future / partial)

- Mood/style mutation only if concrete need (prefer CreateMapViaMenu).
- Native `.Macroblock.Gbx` round-trip beyond JSON durable specs.
- Absolute cursor set (optional).

### Agent habits

- Smoke: `GetReadiness want=editor` or `call.py --until-ready editor GetMode`.
- After menu nav: `WaitUntil condition=pageVisible` / GetMode.
- Tag places: `SetAgentTag` then place; cleanup with `RemoveByTag`.
- Do not depend on old disabled `mcp-tm` / `tm-mcptm` library plugins.
