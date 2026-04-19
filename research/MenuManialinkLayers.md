# Main-Menu Manialink Layer Reference

Source: live introspection via `tm-control-mcp GetUILayers` on Trackmania build 3.3.0 / 2026-02-02, running through Proton. 78 layers on top-level `/home`.

## Key insight

Each menu "route" that Router_Push accepts corresponds one-to-one to a UI layer whose `<manialink name=...>` attribute matches `Page_<RouteName>`. Layers are allocated up front and toggled visible; `Router_Push` changes which `Page_*` layer is visible.

Examples (layer index varies by game session / mod set):

| Route Pushed           | Layer `manialinkName`             |
|------------------------|-----------------------------------|
| `/home`                | `Page_HomePage`                   |
| `/solo`                | `Page_Solo`                       |
| `/live`                | `Page_Live`                       |
| `/local`               | `Page_Local`                      |
| `/clubs`               | `Page_Clubs`                      |
| `/create`              | `Page_Create`                     |
| `/mapeditorsettings`   | `Page_MapEditorSettings`          |
| `/server-review`       | `Page_ServerReview`               |
| `/local-multi`         | `Page_LocalMultiSettings`         |
| `/play-map`            | `Page_PlayMap`                    |
| `/against-replay`      | `Page_AgainstReplay`              |
| `/edit-replay`         | `Page_EditReplay`                 |
| `/submittedmaps`       | `Page_SubmittedMaps`              |
| `/totdchanneldisplay`  | `Page_TOTDChannelDisplay`         |
| `/empty`               | (no content, all Page_* hidden)   |

Non-page layers (always resident, toggled by other events):

- `Navigation:ResetGlobalSoloGroups`
- `CMGame_MenusPreload`
- `Events_EventRelayer`
- `Page_LoadingScreen` (type `LoadingScreen`)
- `Overlay_ReportSystem`, `Overlay_ControllerInfo`, `Overlay_PlayNavigationTabs`
- `Overlay_ProfileWidget`, `Overlay_PrestigeProgression`
- `Overlay_DisplayVersion`, `Overlay_MenuBackground`
- `Overlay_SpeechToText`, `Overlay_Splashscreen`
- `MLHook_AngelScript_CallBack` (injected by MLHook)

## How visibility moves

When Router_Push fires for `/create`, only `Page_Create.IsVisible` should flip to `true`, the others to `false`. But pushing some routes (e.g. `/mapeditorsettings`) from an external plugin context leaves *everything* hidden — probably because the route handler expects to be called as part of a parent-page navigation flow that MLHook's `Queue_Menu_SendCustomEvent` doesn't fully simulate.

Observed: `SetMenuPage /mapeditorsettings` → `GetUILayers onlyVisible=true` showed only overlays + loading screen + `Page_LoadingScreen`, no `Page_*` content layer visible. Screen goes blank.

## To navigate programmatically

1. `Router_Push` works cleanly for top-level routes: `/home`, `/create`, `/solo`, `/live`, `/local`, `/clubs`, `/play-map` etc.
2. For sub-pages (`/mapeditorsettings`, `/edit-replay`, etc.) the push alone does not render the layer. The full click flow from the parent page is doing more than emitting Router_Push — likely setting layer parent relationships or pushing history stack. This needs more research.
3. Clicking a `component-navigation-item` button on a page: the click handler is bound in the Manialink Script (`MainMenu.Script.txt` referenced by every layer). The script is inside `Trackmania.Title.Pack.Gbx`, which is binary/compressed — `strings` cannot find the click routing directly.

## Introspection tools (tm-control-mcp)

- `GetUILayers` — lightweight list: index, type, visibility, attachId, pageUrl, manialinkName, top-level children count. Default reads only the first 1 KB of ManialinkPageUtf8 per layer.
- `GetLayerTree { layerIndex, rootPath?, maxDepth, onlyWithId }` — walk one layer's control tree starting at an optional path. Returns controlId, classes, type, visibility, absPos, size, labelValue, data attributes.
- `ListMenuManialinkControls` — older alias that walks every layer. Kept for compatibility; prefer `GetUILayers` + `GetLayerTree` for scoped queries.
- `FocusMenuControl { controlId }` — Focus() by id. Does NOT click; useful for discovery only.

## Follow-ups tried, still failing

- Pushing `/create` then `/mapeditorsettings` with long (6s) waits still leaves only Page_LoadingScreen visible. Page_Create is correctly hidden; Page_MapEditorSettings never shows.
- Pushing `/mapeditorsettings` with extras `{"ShowParentPage":true,"KeepPreviousPagesDisplayed":true,"SaveHistory":true}` — same result.
- Therefore the /mapeditorsettings (and probably other sub-page) transition is not handled purely by a Router_Push event listener; something in the parent's click handler does additional state-setup that we're missing.

## Open questions

- How does the framework map a `Router_Push` route name to a `Page_*` layer? Is it by exact suffix match on the `manialinkName`, or by attach/parent context? (Would tell us whether hypothetical new plugin pages can register routes.)
- What event type does a `component-navigation-item` click dispatch to its menu script? Candidate: a SendCustomEvent with type `Component_Navigation_*` and the button's controlId as the payload. Need the menu script source to confirm.
- `Trackmania.Title.Pack.Gbx` extractor / GBX-script-dumper would unblock this. Openplanet may ship one (check `NadeoToolkit` / `GBXFunctions`).
