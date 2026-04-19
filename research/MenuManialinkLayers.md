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

When Router_Push fires for `/create`, only `Page_Create.IsVisible` flips to `true`, the others to `false`.

## ROUTES ARE HIERARCHICAL — USE FULL PATHS

The `/mapeditorsettings` (blank screen) puzzle is solved: **subpages require their full hierarchical path**. What looks like a standalone route on e.g. the "Track editor" button is actually `/create/mapeditorsettings` with `/create` as the parent path. Calling `Router_Push` with the bare leaf name does not resolve because there is no `Page_Mapeditorsettings` layer — only `Page_MapEditorSettings` whose framework parent is `/create`.

Verified on a live TM session (2026-04-20):

| Push route                   | Result                                |
|------------------------------|---------------------------------------|
| `/mapeditorsettings`         | Page_LoadingScreen only (blank)       |
| `/create/mapeditorsettings`  | **Page_MapEditorSettings renders** ✓  |
| `/create/garage`             | **Page_Garage renders** ✓             |
| `/solo/weekly-tracks` (from /home) | Page_LoadingScreen only (may need /solo first) |

**Rule**: if the menu script for a button does `Router_Router::SetParentPath(This, "/a/b", "/a")` + `Router_Router::Push(This, "/a/b")`, then the path you pass to `SetMenuPage` must be `"/a/b"`, not `"/b"`.

## How clicks are routed inside the menu script

Discovered by grepping Page_Create's XML (`GetLayerXml {layerIndex, find}`):

1. Buttons are `<frame class="component-navigation-item">` containing a zone quad `<quad ... scriptevents="1" />`. Hover/click events on the zone dispatch into the framework `ComponentNavigation_ComponentNavigation`.
2. The page script handles `ComponentNavigation_ComponentNavigation::C_EventType_NavigateMouse`, checks the `navgroup` identifier, then on `MouseClick` calls `Select(Event.To, ...)`.
3. `Select(CMlControl, ...)` switches on `_Control.ControlId` — e.g. `"button-map-editor"` → `Router_Router::Push(This, "/create/mapeditorsettings")`.

This means `Select` is an ORDINARY SCRIPT FUNCTION in the page's Manialink, not a SendCustomEvent. To drive it from outside without simulating mouse input, we must either:
- Push the destination route directly via `Router_Push` (works now that we know the full path), OR
- Inject a script fragment that calls `Select` with a synthesized control pointer (unexplored).

For the programmatic-navigation use case, the `Router_Push` path is sufficient.

## Route map discovered from XML (Page_Create, layer index depends on session)

Page_Create (navgroup "navgroup-page-create"):

| ControlId            | Router call                                                   |
|----------------------|---------------------------------------------------------------|
| `button-back`        | `Router_Router::PushParent(This)`                              |
| `button-map-editor`  | parent `/create`, push `/create/mapeditorsettings`             |
| `button-map-review`  | parent `<current>`, push `/create/server-review` (with offline + permission gates) |
| `button-replay-editor` | push `/create/edit-replay` (with permission gate)            |
| `button-garage`      | parent `<current>`, push `/create/garage` (with offline gate)  |

Page_HomePage (partial):

| ControlId            | Router call                                                   |
|----------------------|---------------------------------------------------------------|
| `button-play-and-play` | switches on `GetCurrentPlayTabIndex()` → `/solo`, `/live`, `/local` |
| `button-clubs`       | `/clubs` (offline gate opens popup)                            |
| `button-create`      | `/create`                                                     |
| `button-ubi-connect` | `State.Task_ShowUbisoftConnect = True;` (no Router_Push — overlay task) |
| `button-profile`     | parent `<current>`, push `/profile`                            |
| `button-settings`    | parent `/home`, push `/settings`                               |

Page_Solo (partial; some pushes take extra args):

| ControlId             | Router call                                                  |
|-----------------------|--------------------------------------------------------------|
| `button-back`         | `Router_Router::PushParent`                                   |
| `button-library` (online) | parent `/solo`, push `/solo/library-clubcampaigns`       |
| monthly campaign card | `/solo/monthlycampaigndisplay` with `True` extra             |
| campaign-card         | parent `/solo`, push `/solo/campaigndisplay` with `["Campaign" => ...]` extras |
| weekly-tracks card    | parent `/solo`, push `/solo/weekly-tracks`                    |
| prestige recap        | parent `/solo`, push `/create/prestige-recap`                 |

`Router_Router::Push` accepts a third-argument extras (Dict or Boolean). Our `SetMenuPage` already passes an empty `"{}"` extras payload; for pages like `/solo/campaigndisplay` that *require* extras the empty payload likely won't hydrate the target page correctly.

## To navigate programmatically

1. Top-level routes: `/home`, `/create`, `/solo`, `/live`, `/local`, `/clubs`, `/profile`, `/settings`, `/play-map`, `/press-start` etc.
2. Subpage routes: use the full hierarchical path, e.g. `/create/mapeditorsettings`, `/create/garage`, `/create/edit-replay`, `/create/server-review`, `/create/prestige-recap`, `/solo/weekly-tracks`, `/solo/campaigndisplay`, `/solo/library-clubcampaigns`, `/solo/monthlycampaigndisplay`.
3. Some subpages that get called with a hash-literal extras ({"Campaign" => ...}) or a Bool flag may render in an empty state without those extras. Extras plumbing via MLHook is unexplored; probably needs the 3rd arg shape of `Router_Push` documented.
4. Buttons whose handler does *not* call Router_Push (e.g. `button-ubi-connect`) cannot be triggered via this mechanism. We'd need to synthesize a real mouse click, or invoke their script function directly.

## Introspection tools (tm-control-mcp)

Low-level (drill-in):
- `GetUILayers` — lightweight list: index, type, visibility, attachId, pageUrl, manialinkName, top-level children count. Default reads only the first 1 KB of ManialinkPageUtf8 per layer.
- `GetLayerTree { layerIndex, rootPath?, maxDepth, onlyWithId }` — walk one layer's control tree starting at an optional path. Returns controlId, classes, type, visibility, absPos, size, labelValue, data attributes.
- `ListMenuManialinkControls` — older alias that walks every layer. Kept for compatibility; prefer `GetUILayers` + `GetLayerTree` for scoped queries.
- `FocusMenuControl { controlId }` — Focus() by id. Does NOT click; useful for discovery only.

High-level (one-shot "find me the button"):
- `FindMenuButtons { onlyVisible?, className? }` — flat list of all visible nav buttons across the whole menu. Default class filter is `component-navigation-item`. Each match includes `layerIndex`, `layerName`, `controlId`, `classes`, `absPos`, `size`, raw `label`, and translation-stripped `displayText`.
- `FindControlsByClass { classPattern, substring?=true }` — substring or exact class match across all layers.
- `FindControlsByLabel { substring, caseInsensitive?=true }` — search by localized label text; returns the inner Label controls.

## Nadeo label translation-key format

Labels embed UTF-8 C1 control markers: `U+0091` (`\xC2\x91`) and `U+0092` (`\xC2\x92`). Observed forms (see `_StripTranslationPrefix` in ManialinkIntrospection.as):

| Raw form                                               | Meaning                          | Stripped         |
|--------------------------------------------------------|----------------------------------|------------------|
| `\u0092\|Prefix\|Text`                                 | marker + keyed lookup            | `Text`           |
| `\u0091<fallback>\u0091\u0092\|Prefix\|Text`           | fallback + keyed lookup          | `Text`           |
| `\u0092<plain text>`                                   | marker + direct text (no key)    | `<plain text>`   |
| `\|Prefix\|Text`                                       | rare, no marker                  | `Text`           |
| Plain text (e.g. `Ubisoft Connect`)                    | no translation                   | unchanged        |

## Router_Push event payload shape

The MLHook event queue entry `Queue_Menu_SendCustomEvent("Router_Push", {route, extra, history})` takes three strings:

| Slot | Purpose | Format | Example |
|------|---------|--------|---------|
| 0 | Route path | String | `/create/mapeditorsettings` |
| 1 | Extras / route hydration | JSON string | `{"ForceMode":"Royal"}` |
| 2 | Navigation history controls | JSON string | `{"SaveHistory":true,"ResetPreviousPagesDisplayed":true,"KeepPreviousPagesDisplayed":false,"HidePreviousPage":true,"ShowParentPage":false,"ExcludeOverlays":[]}` |

`SetMenuPage` currently exposes slot 0 (`route`) and slot 1 (`extra`, default `"{}"`) but not slot 2 (hardcoded `"{}"`). Exposing slot 2 would be a small additive improvement.

Observed route-hydration behavior (2026-04-20):

- `/solo/campaigndisplay` without extras → `Page_CampaignDisplay` becomes visible but its content panel stays empty (no campaign selected).
- `/matchmakingmainpage` with `{"ForceMode":"Royal"}` — did NOT render on current build (stayed on Page_LoadingScreen). May be a dead route in newer TM builds, or a different path prefix is now required.

## Tools for this kind of investigation

- `GetLayerXml { layerIndex, find?, context?=120, maxHits?=20, caseInsensitive?, offset?, length?=2048 }` — grep or slice a layer's Manialink XML. Far cheaper than dumping the whole 50-120 KB XML. Use it to chase handler names, control IDs, and Router_Router calls.
- Useful needles when reverse-engineering a page's script:
  - `Router_Router::Push` — list every destination this page can route to
  - `Router_Router::SetParentPath` — see how subpage parents are wired
  - `navgroup-` — find the navigation group identifier for this page
  - `ComponentNavigation_ComponentNavigation::` — framework handlers (navigate mouse / input / select)
  - `Void Select(` or `Select(Event.To` — the ControlId → action switch
  - `SendCustomEvent` — rare but present in some error/popup handlers

## Open questions

- Does passing extras through `Queue_Menu_SendCustomEvent("Router_Push", {path, extra, "{}"})` actually hydrate the target page? For `/solo/campaigndisplay` the menu script expects `["Campaign" => "..."]` extras; test whether a dict-shaped JSON/ManiaScript string in field 2 is parsed by the router.
- Can we call a page's `Select(control, popup)` from outside without going through a mouse-click event? Would unblock buttons like `button-ubi-connect` that set flags rather than pushing routes.
- `Trackmania.Title.Pack.Gbx` extractor / GBX-script-dumper would still be nice for reading the ComponentNavigation framework source (to confirm the exact event shapes) but is no longer a blocker for navigation.
