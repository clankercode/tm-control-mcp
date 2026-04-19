## Project Notes

- Use `./build.sh dev` for every tm-control-mcp change; it runs `openplanet-lsp`, copies to `~/OpenplanetNext/Plugins/tm-control-mcp`, and reloads through RemoteBuild.
- `tools/call.py` returns compact JSON by default and checks for a real `Trackmania.exe` process before socket calls.
- For generated builds, prefer `AddBlocksToNamedMacroblock` and `AddItemsToNamedMacroblock` over one add call per block/item.
- Named macroblock block specs support `variant`, `bgSkin`, and `fgSkin`; skins are applied directly to newly inserted map block indices after `PlaceNamedMacroblock`.
- `FindBlockModels` and block readback include variant counts/indices; use them when testing cross-theme or Vista-ish blocks.
- When adding editor-control tools, prefer source-of-truth docs under `~/scrape/openplanet/next`, especially `Game/CGameCtnEditorFree.md`, `ShootMania/CSmEditorPluginMapType.md`, `Game/CGameEditorPluginCameraAPI.md`, `Game/CGameEditorPluginCursorAPI.md`, and `Game/CGameEditorGenericInventory.md`.
- Landed editor-control tools include `CanPlaceBlock`, `ControlCursor`, `ControlValidation`, `ControlCamera`, and `ControlSelection`; prefer their status/preflight actions before mutating the editor.
- High-value future MCP tools from the docs: richer inventory tree traversal; metadata inspection/mutation; and map/macroblock lifecycle helpers.
