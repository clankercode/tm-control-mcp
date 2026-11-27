# Blocking menu screens: detection and dismissal

Design + evidence note, 2026-11-17. Implemented on `feat/blocking-screens`;
validated live on a tmc-managed instance (multibox clone, Openplanet DEV).

## The problem

Two full-page TM2020 screens stall any menu-only agent until a human clicks
through, and **`GetDialog` cannot see either** — they are ManiaLink pages, not
BasicDialogs frames:

1. **Disconnection flow.** The menu's own disconnect detector
   (`ConnectionError.Script.txt` `Yield()`) pushes `Page_ConnectionError`
   whenever `UserMgr.MainUserWebServicesInfo.ConnectionStatus` drops to
   `NotConnected`. That page shows a "Connection error" `PopUpMultiChoice`
   with a single choice; confirming sends `ConnectionError_RequestRestart`,
   which pushes `/press-start`. `Page_PressStart` then runs its connection
   state machine; on failure it shows an error label plus three
   `ExpendableButton`s: `button-play-offline` ("Play offline"),
   `button-back` (re-labelled "Retry" on PC), `button-quit-game` ("Quit
   game"). "Play offline" connects the user offline and proceeds to the home
   page — the game keeps working offline.
2. **Start screen.** The same `Page_PressStart` in its "Start" state. On PC it
   auto-connects when the online-services status is `None`/`FailedRequest`,
   but **waits for input while a maintenance/disruption status is set**
   (observed live: status card "Maintenance — From 8:00 PM to 9:00 PM on
   11/17/2026" and the page waiting). Input = key press, click on the
   full-screen quad `button-start-click`, or a menu-navigation event.

Source: `Titles/Trackmania/Scripts/Libs/Nadeo/Trackmania/MainMenu/Pages/PressStart.Script.txt`
and `Pages/ConnectionError.Script.txt` (Openplanet `Extract`).

## What the bridge had before

`GetActiveMenuPages` / `GetLayerTree` / `FindControlsByLabel` /
`ClickMenuButton` / `TriggerControlOnAction` / `SetMenuPage` were enough to
inspect and click, but nothing classified these states, `GetReadiness
want=menu` said `ready:true` with the start screen up (observed live — the
operator's actual failure mode), and there is no key injection anywhere in
`src/` (a click on `button-start-click` replaces Enter; verified live).

## Design

Two core tools (menu state, same class as `GetDialog`; no extra dependency,
so not a tool pack):

- **`GetBlockingScreen`** (read-only). Returns `kind`:
  `start-screen` | `connecting` | `connection-failed` |
  `connection-error` | `ubi-connect` | `welcome-back` |
  `maniascript-debugger` | `none`,
  plus `blocking`, `needsAction`, `suggestedAction`, the error/status text,
  and the visible buttons (`id`, `label`, `displayText`, `action`).
  `maniascript-debugger` is not a menu page: it is the native ManiaScript
  debugger (`SystemOverlay.ScriptDebugger`) in any view but `Hidden`. It
  covers the game in any mode after a script fails (seen in Race,
  2026-11-22, `Editor` view, after a mode script failed to load). Window
  captures on 2026-11-27: a menu ManiaLink compile error opens `LogsFull`
  (script viewer + instances + log over the whole screen); `LogsReduced`
  blacks out the top and shows the log below. It wins over the menu kinds;
  `scriptDebugger` always reports the visibility. It has no auto action; `DismissBlockingScreen` refuses with
  `MANIASCRIPT_DEBUGGER` so the error is preserved first (see
  [maniascript-failures.md](maniascript-failures.md)).
- **`DismissBlockingScreen {action, waitMs}`**. `auto` takes the suggested
  action per kind: start-screen → click start, connection-error → Confirm,
  connection-failed/ubi-connect → Play offline, welcome-back → Maybe later.
  Explicit `start|confirm|play-offline|retry|later` must fit the kind
  (`WRONG_KIND`). One click per call — the disconnect flow lands on
  PressStart again and the caller dismisses that too. `waitMs` (default
  15000, max 120000) waits for the kind to change and reports `after` +
  `menuReached`. **Never clicks Quit game** (whitelist in
  `BlockingScreensPolicy.as`, pinned by tests).

Supporting changes: `GetReadiness` (`menu`/`any`) reports a blocking screen
as a blocking reason (`checks.menuBlockingScreen`, soft-`any` override no
longer fires while one is up); `WaitUntil` gains `menuReached` and
`blockingScreen (+equals)`; guide `blocking-screens`.

### Why detection is id + effective visibility (not labels)

- **Labels are runtime-set.** `FindControlsByLabel` found nothing for
  "Play offline" while the buttons were on screen (live, leased instance 4):
  the `ExpendableButton` text label is filled by the page script. Labels are
  reported, never matched.
- **Leaf `.Visible` lies.** Live on instance 3: `button-play-offline` (and
  its whole expendable-button subtree) reports `.Visible == true` while its
  parent `frame-play-offline` is hidden — `SetConnectionProgress` only
  toggles the frames. Effective visibility walks the `Parent` chain.
- Spinner state is the spinner *quad* (`menu-libs-loading-spinner_quad-loading`),
  not its frame: the frame is always visible, the quad only while loading
  (observed live: start screen → quad hidden; connecting → quad visible).

### Classification order

`connection-error` pop-up wins (it renders on any route); then PressStart
pop-ups (`ubi-connect`, `welcome-back`); then `connection-failed`
(`frame-play-offline` visible) before `start-screen` (`button-start-click`
visible) before `connecting` (spinner quad visible). Over-detecting a start
screen is harmless: clicking Start when the page would auto-connect anyway
just starts the connection immediately.

## Evidence (live, 2026-11-17, tmc instance 3, port 30300)

- Maintenance start screen observed organically at boot: `Page_PressStart`
  visible, `button-start-click` V, offline buttons hidden-but-present,
  status card "Maintenance — 8:00 PM to 9:00 PM on 11/17/2026";
  `GetReadiness want=menu` → `ready:true` (the bug).
- `TriggerControlOnAction {controlId:"button-start-click"}` (the pre-existing
  click path) dismissed it: spinner "Retrieving data" → "Starting the engine"
  → `Page_HomePage` in ~6s. No key injection needed.
- The hidden `Page_ConnectionError` layer exists at boot (index 56) with the
  full `PopUpMultiChoice` tree; its confirm control is
  `trackmania-pop-up-multi-choice_button-first-choice` (label "Ok" once the
  script runs; `\x92Play offline` etc. on PressStart buttons).
- Post-change tool transcripts: see `docs/` in the lease repo
  (`~/src/tm-ci-lease/docs/`) — `blocking-screens-lab-2026-11-17.md`.

## Open / follow-ups

- `connection-failed` dismissal ("Play offline") is the one action not
  exercised live: the state needs a genuinely failed connect and the session
  was healthy. Its detection shares the machinery validated above, and the
  button subtree was read live while hidden. An organic disconnect during a
  lease completes the matrix (plan in the lease-repo note).
- Fallbacks when tm-control-mcp is down are out of scope here (lease-side
  concern; see the lease repo notes).
- `ubi-connect` / `welcome-back` kinds share the PressStart machinery but
  were not seen live on PC/Steam (account already linked); their control ids
  come from the same extracted page source.
