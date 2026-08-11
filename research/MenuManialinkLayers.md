# Main-Menu Manialink Layer Reference

> **STATUS — 2026-08-12**
>
> ### Settled
> - **`CControlBase::OnAction()` is the live, Angelscript-safe click primitive.** Not marked `// Maniascript`; callable from Openplanet. Every `CGameManialinkControl` exposes `.Control` → `CControlBase*`.
> - **`TriggerControlOnAction`** (low-level) and **`ClickMenuButton`** (high-level nav-item) are **LIVE** MCP tools. `ClickMenuButton` resolves a nav-item, DFS-finds the `component-navigation-item-zone` leaf, and fires `OnAction` on it. Works for both `CMGame_ExpendableButton` and `Trackmania_Button` templates. Verified commits: `a418089` (OnAction), `bb4c88a` (ClickMenuButton).
> - **`CreateMapViaMenu`** drives the full Page_MapEditorSettings click-chain (SetMenuPage + 6 OnAction clicks) end-to-end into Editor mode. Verified `6834a15`+ (scoped to Page_MapEditorSettings in `fcb58db`). QuickStart (`MapEditorUseQuickstart`) must be **off**.
> - **`TriggerPageAction` is a BANNED historical dead-end.** It native-crashes `openplanet.dll`. Do not call it, wrap it, or re-enable any stub that used it. Keep the crash warning permanently (see below).
> - Hierarchical routes (`/create/mapeditorsettings`, not bare leaf) are required.
> - Side-effect routes (`/solo/campaigndisplay`, …) can leave Menu into Race; `SetMenuPage` blocks known ones by default.
>
> ### Still open
> - `CGameManialinkNavigationScriptHandler::ApplyInput` — clean keyboard-Select primitive, but **no handle** is exposed off Page/ScriptHandler/UILayer. Needs a Ghidra offset pass (or is superseded in practice by OnAction).
> - Router_Push **extras** hydration shape for dict/bool third-arg pages (e.g. `/solo/campaigndisplay` Campaign payload).
> - SetMenuPage history-controls slot (MLHook event arg 2) still hardcoded `"{}"`.
> - Event-queue direct injection into `PendingEvents` (all fields `const` in script) — Ghidra for offsets/lifecycle; not needed for nav clicks now that OnAction works.
>
> ### Agent short path
> - Navigate pages → `SetMenuPage` + poll `GetActiveMenuPages`.
> - Click a nav button → `ClickMenuButton {controlId}` (or `{indexPath, layerName}` when scoping matters).
> - Non-nav / leaf without `component-navigation-item-zone` → `TriggerControlOnAction`.
> - New map via full menu wizard → `CreateMapViaMenu` (QuickStart off).
> - New map via title API shortcut → `EditNewMap` (bypasses menu click-chain).
> - Custom ManiaScript / `TitleControl::EditNewMap`-style terminal calls from injected ML → `RunManialinkScript` / MLHook inject (optional alternative when you need page-local script, not just a control click).

Source: live introspection via `tm-control-mcp GetUILayers` on Trackmania build 3.3.0 / 2026-02-02, running through Proton. 78 layers on top-level `/home`. Click primitives and CreateMapViaMenu verified on live sessions 2026-04-20 (`a418089`…`fcb58db`).

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

`SetMenuPage` also rejects routes that do not start with `/` (bare names silently wedge the menu into `Page_LoadingScreen`).

## How clicks are routed inside the menu script

Discovered by grepping Page_Create's XML (`GetLayerXml {layerIndex, find}`):

1. Buttons are `<frame class="component-navigation-item">` containing a zone quad `<quad ... scriptevents="1" />`. Hover/click events on the zone dispatch into the framework `ComponentNavigation_ComponentNavigation`.
2. The page script handles `ComponentNavigation_ComponentNavigation::C_EventType_NavigateMouse`, checks the `navgroup` identifier, then on `MouseClick` calls `Select(Event.To, ...)`.
3. `Select(CMlControl, ...)` switches on `_Control.ControlId` — e.g. `"button-map-editor"` → `Router_Router::Push(This, "/create/mapeditorsettings")`.

`Select` is an ordinary script function in the page's Manialink, not a SendCustomEvent. From outside we can:

1. **Push the destination route** via `SetMenuPage` / `Router_Push` (when the button only navigates), OR
2. **Fire the real click path** via `CControlBase::OnAction()` on the nav-zone leaf — what `ClickMenuButton` / `TriggerControlOnAction` do (LIVE), OR
3. Inject ManiaScript that calls title-control / page APIs directly (`RunManialinkScript` / MLHook inject) for terminal actions that need custom ML.

### LIVE click path — `CControlBase::OnAction` (2026-04-20 → present)

**This is the settled answer.** Do not re-investigate TriggerPageAction.

| Tool | Role |
|------|------|
| `TriggerControlOnAction` | Low-level: resolve control by `{controlId}` or `{indexPath, layerIndex\|layerName}`, call `.Control.OnAction()`. Optional `recursive=true` DFS-fires descendants. |
| `ClickMenuButton` | High-level nav click: resolve nav-item → DFS for class `component-navigation-item-zone` → `OnAction` on that leaf. Handles expendable-button **and** Trackmania_Button templates. |
| `CreateMapViaMenu` | One-shot wizard: `SetMenuPage /create/mapeditorsettings` + 6 scoped `ClickMenuButton` steps → poll Editor. |

Implementation notes (see `src/ManialinkIntrospection.as`):

- `OnAction` lives on `CControlBase` (Openplanet.h ~13548), **not** marked `// Maniascript`, so Angelscript calls are safe.
- For HomePage-style expendable buttons the true hit target is often the leaf nav-zone under the nav-item frame (historically `Controls[0]/[4]/[0]` for `button-create`); `ClickMenuButton` finds it by class instead of hardcoding indexes.
- **Scope clicks to the right layer** when controlIds collide. `CreateMapViaMenu` resolves `indexPath` on `Page_MapEditorSettings` only — a global DFS for `button-create` can hit `Page_HomePage` first (wrong template).
- After firing, poll `GetActiveMenuPages` / `GetMode` / `GetDialog` — the click is synchronous dispatch, but menu state transitions are still async.

Verified end-to-end:

- `TriggerControlOnAction` on HomePage nav-zone → `Page_Create` (`a418089`).
- `ClickMenuButton {controlId:"button-create"}` / `{controlId:"button-map-editor"}` without hand-computed paths (`bb4c88a`).
- Full `CreateMapViaMenu` race/RedIsland/Day → Editor (`6834a15`, error propagation `938c1ce`, layer scoping `fcb58db`).

### Terminal actions that are NOT Router_Push

Not every "button" on a page pushes a route. Some end-of-flow buttons call the title control API directly instead, bypassing the Router entirely. These cannot be triggered by `SetMenuPage` alone:

- `Page_MapEditorSettings / button-create` → (wizard chain, not a single hop) ultimately `TitleControl::EditNewMap(...)` after type/device/difficulty/enviro/mood selections.
- Historical XML notes (Page_MapEditorSettings): `button-create` / `button-edit` paths call `TitleControl::EditNewMap` / `TitleControl::EditMap` style APIs — same family our `EditNewMap` MCP tool wraps via `app.ManiaTitleControlScriptAPI.*`.

**Ways to reach the editor today:**

| Path | Tool | Notes |
|------|------|-------|
| Full menu wizard (matches human UI) | `CreateMapViaMenu` | Needs QuickStart **off**. Preferred when testing the real click-chain. |
| Title API shortcut | `EditNewMap` | Bypasses Page_MapEditorSettings UI entirely. |
| Injected ManiaScript | `RunManialinkScript` / MLHook inject | Optional: run page-local ML that calls `TitleControl::EditNewMap`-style APIs or other script-only entry points when agents need custom ML rather than a control click. |

### BANNED — `TriggerPageAction` (historical dead-end, permanent)

`CGameManialinkScriptHandler::TriggerPageAction(string ActionString)` (Openplanet.h ~4473):

- **UNSAFE — CRASHES `openplanet.dll` natively.**
- Tested 2026-04-20 against `app.MenuManager.ManialinkScriptHandlerMenus` on `Page_HomePage`, action `"button-create"`. Game froze instantly; no script log; socket dead. User: *"crash in openplanet.dll, very common when clicking ML stuff in the wrong way."*
- Method is annotated `// Maniascript` — only safe inside the ManiaScript runtime, **not** the Openplanet Angelscript host.
- Early experiment briefly exposed a `ClickMenuButton` that called this API; it was disabled as a poisoned-error marker in `c455ee0`. That stub was **replaced** (not re-enabled) by the OnAction-based `ClickMenuButton` in `bb4c88a`.
- **Do not attempt any variant** — different handler field, different page, `try`/`catch`, recursive wrapper, etc. The crash is native below Angelscript. Keep this section as a permanent ban notice.

Page XML side-note (still true): Maniascript inside `Page_MapEditorSettings` switches on action/controlId strings (e.g. `"button-create"`). Semantically the action *is* the controlId; the right dispatch target exists inside MLUI. From Angelscript we reach equivalent behaviour via **OnAction on the control's CControlBase**, not via TriggerPageAction.

### ApplyInput — open Ghidra note (superseded for nav clicks)

`CGameManialinkNavigationScriptHandler::ApplyInput(CGameManialinkFrame*, EMenuNavAction)` (Openplanet.h ~25207) remains the clean *keyboard* Select primitive — `Action=Select` (value 4) on the focused button's frame would fire `CEventMenuNavigationOnAction` with `IsMouse=false`, `Input=Select`, and the page's ComponentNavigation normaliser would call `Select(State, Event.To)`.

**Still open:** `CGameManialinkNavigationScriptHandler` has a public constructor but **no field** on `CGameManialinkPage` / `CGameManialinkScriptHandler` / any `CGameUILayer` exposes a handle to the active instance. Invoking `ApplyInput` would need either (a) a memory-offset route off Page/ScriptHandler (Ghidra), or (b) constructing a handler and wiring it into the event pump (pool-invariant risk).

**In practice OnAction superseded this for agent menu navigation.** Leave ApplyInput as a research footnote unless keyboard-nav parity is specifically required.

Related dead ends (do not reopen without new evidence):

- Plain `CGameManialinkControl::Focus()` (`FocusMenuControl`) changes focus but does **not** fire Select.
- Direct injection into `CGameManialinkScriptHandler::PendingEvents` — fields are `const` in script; needs raw offset writes + lifecycle rules (Ghidra). Not needed for nav clicks now.

## Routes with side-effects (DANGEROUS — may leave Race mode)

Not every route just swaps a `Page_*` layer. Some Router pushes kick off navigation flows that cascade into a playground launch:

| Route | Observed side effect |
|-------|----------------------|
| `/solo/campaigndisplay` | **Auto-loaded the current campaign's active map** (`Spring 2026 - 01`) and transitioned into Race/PlaygroundScript mode. The Page_CampaignDisplay layer became visible briefly before cascading into the race. Observed 2026-04-20 live session. |

Rule of thumb: routes that present a *single* selected thing (a campaign, a replay, a specific match) will likely auto-enter that thing if their content state is already populated. Routes that show a *list* or *settings form* (like `/create/mapeditorsettings`, `/create/garage`) are safe.

`SetMenuPage` blocks known side-effect routes (`/solo/campaigndisplay`, `/solo/monthlycampaigndisplay`) by default; pass `allowPlaygroundLaunch:true` to override.

Use `GetMode` (returns `{mode, mapName?, mapUid?, selfHosted?}`) to detect a cascade. Use `BackToMainMenu` to unwind.

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
| `button-ubi-connect` | `State.Task_ShowUbisoftConnect = True;` (no Router_Push — overlay task; use `ClickMenuButton` / OnAction, not SetMenuPage) |
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

## Page_MapEditorSettings click-chain (CreateMapViaMenu)

Implemented tool — see also `docs/task-c-create-map-via-menu.md`.

Step order after `SetMenuPage /create/mapeditorsettings` (poll page visible ≤1s):

| # | Click `controlId` | Then poll for |
|---|-------------------|---------------|
| 1 | `button-create` | `frame-create-type` visible (fails fast with QuickStart hint if not) |
| 2 | `button-create-<mapType>` | `frame-controller` |
| 3 | `button-<inputDevice>` | `frame-difficulty-<inputDevice>` |
| 4 | `button-difficulty-<inputDevice>-<difficulty>` | `frame-enviro` |
| 5 | `button-enviro-<environment>` | `frame-mood` |
| 6 | `button-mood-<mood>` | `GetMode` / `app.Editor != null` → Editor |

Enums: `mapType` ∈ race|royal|stunt|platform; `environment` ∈ Stadium|RedIsland|GreenCoast|BlueBay|WhiteShore; `mood` ∈ Sunrise|Day|Sunset|Night; `inputDevice` ∈ mouse|gamepad; `difficulty` ∈ simple|advanced.

**Prerequisite:** Map Editor QuickStart must be disabled (`MapEditorUseQuickstart` off). If step 1's `frame-create-type` never appears, that is the usual cause.

## To navigate programmatically

1. Top-level routes: `/home`, `/create`, `/solo`, `/live`, `/local`, `/clubs`, `/profile`, `/settings`, `/play-map`, `/press-start` etc.
2. Subpage routes: use the full hierarchical path, e.g. `/create/mapeditorsettings`, `/create/garage`, `/create/edit-replay`, `/create/server-review`, `/create/prestige-recap`, `/solo/weekly-tracks`, `/solo/campaigndisplay`, `/solo/library-clubcampaigns`, `/solo/monthlycampaigndisplay`.
3. Some subpages that get called with a hash-literal extras (`{"Campaign" => ...}`) or a Bool flag may render in an empty state without those extras. Extras plumbing via MLHook is partially explored; dict hydration for campaign pages remains open.
4. Buttons whose handler does *not* call Router_Push (e.g. `button-ubi-connect`, wizard steps on Page_MapEditorSettings): use **`ClickMenuButton`** / **`TriggerControlOnAction`**, not SetMenuPage.
5. Prefer layer-scoped resolution (`layerName` + `indexPath` from `InspectMenuControl`) when the same `controlId` exists on multiple Page_* layers.

## Introspection tools (tm-control-mcp)

Low-level (drill-in):

- `GetUILayers` — lightweight list: index, type, visibility, attachId, pageUrl, manialinkName, top-level children count. Default reads only the first 1 KB of ManialinkPageUtf8 per layer.
- `GetLayerTree { layerIndex, rootPath?, maxDepth, onlyWithId }` — walk one layer's control tree starting at an optional path. Returns controlId, classes, type, visibility, absPos, size, labelValue, data attributes.
- `ListMenuManialinkControls` — older alias that walks every layer. Kept for compatibility; prefer `GetUILayers` + `GetLayerTree` for scoped queries.
- `InspectMenuControl { controlId, layerName? }` — resolve via GetFirstChild; returns type/classes/visibility plus `path` (child-index) and `idPath`. Use `path` as `indexPath` for scoped clicks.
- `FocusMenuControl { controlId }` — Focus() by id. Does NOT click; useful for discovery only.
- `SetMenuControlVisible { visible, controlId|indexPath… }` — Show()/Hide(); menu may re-render and reset on next tick.

High-level (find / act):

- `FindMenuButtons { onlyVisible?, className? }` — flat list of visible nav buttons. Default class filter `component-navigation-item`. Each match: `layerIndex`, `layerName`, `controlId`, `classes`, `absPos`, `size`, raw `label`, translation-stripped `displayText`.
- `FindControlsByClass { classPattern, substring?=true }` — substring or exact class match across all layers.
- `FindControlsByLabel { substring, caseInsensitive?=true }` — search by localized label text.
- **`ClickMenuButton`** — LIVE high-level nav click via OnAction (see above).
- **`TriggerControlOnAction`** — LIVE low-level OnAction (optional recursive).
- **`CreateMapViaMenu`** — LIVE full map-editor wizard.
- `SetMenuPage` / `GetActiveMenuPages` / `GetMenuPage` / `ListKnownMenuRoutes` / `BackToMainMenu` / `GetMode`.

Optional ML injection:

- `RunManialinkScript` — inject ad-hoc ManiaScript via MLHook into menu / in-map / in-editor context (no outer `<manialink>` tags). Useful for TitleControl-style terminal calls or page-local script that has no Angelscript mirror.

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
  - `TitleControl::` / `EditNewMap` / `EditMap` — terminal title-API calls from page script

## Open questions

- Does passing extras through `Queue_Menu_SendCustomEvent("Router_Push", {path, extra, "{}"})` actually hydrate the target page? For `/solo/campaigndisplay` the menu script expects `["Campaign" => "..."]` extras; test whether a dict-shaped JSON/ManiaScript string in field 1 is parsed by the router.
- Expose SetMenuPage history-controls (MLHook slot 2) instead of hardcoding `"{}"`.
- `ApplyInput` handle discovery via Ghidra — only if keyboard-nav parity is needed; OnAction covers mouse-equivalent clicks.
- `Trackmania.Title.Pack.Gbx` extractor / GBX-script-dumper would still be nice for reading the ComponentNavigation framework source (to confirm exact event shapes) but is no longer a blocker for navigation or clicking.
- Guides.as `menu-navigation` guide still says non-Router buttons need "simulating a real mouse click (unexplored)" and recommends only `EditNewMap` for new maps — **stale vs this research**; code has ClickMenuButton/CreateMapViaMenu. Guide update is out of scope for this doc pass (owned elsewhere).
