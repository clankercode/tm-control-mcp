# Task C: CreateMapViaMenu tool

> **STATUS: IMPLEMENTED** (2026-04-20 → present)
>
> Live MCP tool `CreateMapViaMenu` in `src/ManialinkIntrospection.as`, registered in
> `src/McpTools.as` (`IsToolName` / `CallTool` / `GetToolList`).
>
> Landing commits: `6834a15` (tool), `938c1ce` (propagate SetMenuPage/ClickMenuButton
> errors), `fcb58db` (scope clicks + frame lookups to `Page_MapEditorSettings`).
>
> Click primitive underneath: **`ClickMenuButton` → `CControlBase::OnAction()`**
> (not `TriggerPageAction` — that path is banned; see `research/MenuManialinkLayers.md`).

Single tool that drives the full Page_MapEditorSettings click-chain and
returns when the editor is live (or errors with the step it got stuck on).

## Prerequisite

**QuickStart must be off** (`MapEditorUseQuickstart` disabled in game settings).
If the create-type frame never appears after `button-create`, the tool bails with a
QuickStart hint. This requirement is unchanged.

## Signature

```json
{
  "mapType":      "race | royal | stunt | platform",
  "environment":  "Stadium | RedIsland | GreenCoast | BlueBay | WhiteShore",
  "mood":         "Sunrise | Day | Sunset | Night",
  "inputDevice":  "mouse | gamepad",
  "difficulty":   "simple | advanced",
  "timeoutMs":    10000
}
```

All fields required. Fail fast on unknown combos (tool-level enum checks + protocol
strict validation with `additionalProperties: false`).

## Behavior (as implemented)

1. Call `SetMenuPage` with `/create/mapeditorsettings`. Upstream failures
   (MLHook missing, not in menu module, dangerous route blocked, …) are
   propagated as `{ok:false, failedAt:"SetMenuPage", lastObserved:<error>}`.
2. Poll until `Page_MapEditorSettings` layer is visible (max 1s, 100ms interval).
3. For each wizard step:
   - Resolve the button's child-index path **on `Page_MapEditorSettings` only**
     (`_FindControlIndexPath` on that layer's MainFrame) so global DFS cannot
     hit `Page_HomePage`'s same-named `button-create` (wrong template).
   - Call `ClickMenuButton { indexPath, layerName: "Page_MapEditorSettings" }`,
     which descends to the `component-navigation-item-zone` leaf and fires
     `CControlBase::OnAction()` — the same dispatch a real click uses.
   - Poll for the next expected frame to become visible on that page
     (max 1.5s, 100ms), or for Editor mode on the final step.
4. Step order / expected frames:

   | Click | Expect next |
   |-------|-------------|
   | `button-create` | `frame-create-type` |
   | `button-create-<mapType>` | `frame-controller` |
   | `button-<inputDevice>` | `frame-difficulty-<inputDevice>` |
   | `button-difficulty-<inputDevice>-<difficulty>` | `frame-enviro` |
   | `button-enviro-<environment>` | `frame-mood` |
   | `button-mood-<mood>` | `app.Editor != null` / mode Editor (up to `timeoutMs`) |

5. Success payload (inside MCP `success` wrapper):  
   `{ ok: true, finalMode: "Editor", elapsedMs, steps: [{name, observed, ms}, ...] }`.
6. Failure payload:  
   `{ ok: false, failedAt, expectedFrame, lastObserved, elapsedMs, steps }`  
   (also returned via `MakeSuccess` so callers always get structured diagnostics;
   protocol-level `MakeError` is reserved for missing/invalid args).

## Implementation notes

- Reuses `ManialinkIntrospection.as` helpers: `_ResolveControlFromInput`,
  `_FindControlIndexPath`, `_FindNavZoneInSubtree`, `ClickMenuButton`,
  `_GetLayerPage`.
- No new Angelscript dependencies — stays in `TmMcp` namespace.
- For one-off nav clicks outside this wizard, agents should call
  `ClickMenuButton` / `TriggerControlOnAction` directly (see research doc).
- Title-API shortcut that skips the menu wizard entirely: `EditNewMap`.
- Optional custom ML path for TitleControl-style terminals:
  `RunManialinkScript` / MLHook inject.

## Success test

```bash
python3 tools/call.py CreateMapViaMenu \
  '{"mapType":"race","environment":"RedIsland","mood":"Day","inputDevice":"mouse","difficulty":"advanced","timeoutMs":10000}'
```

Expect `{ok:true, finalMode:"Editor"}` within ~5–10s (QuickStart off, game in main menu).

Invalid enum: validation error from the strict input gate (no custom rejection code needed).

## Related docs / code

- Research (routes, OnAction, banned TriggerPageAction): `research/MenuManialinkLayers.md`
- Implementation: `src/ManialinkIntrospection.as` → `CreateMapViaMenu`, `ClickMenuButton`
- Registration / schema: `src/McpTools.as`
- Agent guide crossover (may lag this doc): Guides.as `menu-navigation`
