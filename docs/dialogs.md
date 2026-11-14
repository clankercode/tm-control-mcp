# Dialogs: detection, reporting, and refusing to act behind them

Design note, 2026-11-15. Status: implemented on `fix/dialog-envelope`; LSP
checked and unit tested; not yet checked in the game (see "Live checks").

## What went wrong (2026-11-15, live)

1. `EditNewMap` from a dirty map editor raised "The map has been changed. Do you
   want to save your changes?". After `RespondDialog no`, every later
   `EditNewMap` did nothing for the rest of the game run. Two game crashes
   (garbage or null pointer) followed in that state.
2. With that prompt up, `GetDialog` said `dialogKind: "none"` (with
   `frameIdName: "FrameAskYesNo"`), so a caller checking the kind saw no dialog.
3. After `requestLeavePlayground`, `ControlValidation testFromCoord` returned
   success while the editor sat at `isTesting: true`, no playground, for 30-60 s.
4. `dialogAfter` is sampled one frame after a tool; a dialog that comes up a few
   frames later is missed.

### Causes

- **Case 2.** `CGameDialogs::EDialog` has only `None`, `Message`, `WaitMessage`.
  The AskYesNo prompt and the SaveAs dialog are *frames* on
  `BasicDialogs.Dialogs.CurrentFrame` while the enum stays `None`. `dialogKind`
  came from the enum alone.
- **Case 1** (from `Openplanet-Old.log`, calls #70 to #109). Non-standard
  Stadium vistas swap the chosen decoration into the shared standard fid
  (`Base48x48Screen155Day`, SwapDecoHack). Call #70, made from the dirty editor,
  did that swap and restore while the old editor (itself built from an earlier
  swap) waited behind its save prompt. After "no", the standard fid's nod had
  an empty IdName. Call #75 swapped it anyway (`"" != "NoStadium48x48Day"`),
  then took the "no decoration nod IdName" early return **without restoring the
  swap**, and released the decoration it had just put in the slot. From then on
  the fid held `NoStadium48x48Day`, every call passed that name to `EditNewMap2`,
  and the game did nothing. A released decoration left in a shared fid slot also
  fits the later garbage-pointer crashes; that link is a hypothesis.
  Why the nod was left with an empty IdName is not established; the fix avoids
  the situation instead of depending on that answer.
- **Case 3.** The tool fired `TestMapFromCoord` and returned after one frame.
- **Case 4, and `BackToMainMenu` returning `blockedByDialog: false` with the
  prompt up.** The prompt arrives frames after the request, and "menu reached"
  was judged by the menus module being on the switcher stack, not by the editor
  being gone.

## The game's dialog systems

| Channel | Where | Kinds |
|---|---|---|
| BasicDialogs enum | `app.BasicDialogs.Dialog` | `Message` (needs OK), `WaitMessage` (loading, saving, shadows) |
| BasicDialogs frame | `app.BasicDialogs.Dialogs.CurrentFrame.IdName` | `FrameAskYesNo` (save changes?, overwrite?), `FrameDialogSaveAs`, others. This menu only hosts dialogs, so any frame there is one |
| Menu modals | `app.ActiveMenus[i].CurrentFrame.IdName` starting `FrameDialog` (or `FrameAskYesNo`) | e.g. `FrameDialogEditorChallengeCard`, the map-saved card |
| Editor interface | `editor.EditorInterface.InterfaceRoot` frames | `FrameTempMsg` ("Map saved."), informational |
| Native windows | Win32 dialogs outside the game UI | crash boxes; `tools/crashwatch` only |

## What the bridge reports now

- **`dialogKind`** (`GetDialog`, `dialogAfter`, `GetReadiness.dialog`,
  `WaitUntil` `last`, `GetLightmapComputeState`) is the effective kind:
  `askYesNo`, `saveAs`, `message`, `wait`, `frameDialog`, `menuDialog`, `none`.
  Pure policy in `src/DialogPolicy.as`. The raw enum stays in `dialog`.
  **`blocking`** is true when the dialog needs an answer (every kind except
  `none` and `wait`). `menuFrameIdName` names a menu modal.
- **`data.dialog` on every socket tool response**, next to `data.result`:
  `{"up":false}` when clear; otherwise
  `{"up":true,"kind","blocking","frame","text"?,"hint"}`, where `hint` names the
  call that answers it. `tools/call.py` prints it as one stderr line.
- **Refusals.** `EditNewMap`, `OpenMapInEditor`, `PlayMap`, `BackToMainMenu`,
  `CreateMapViaMenu` and `ControlValidation` starts (`validate`,
  `requestEnterPlayground`, `testFromStart`, `testFromCoord`) return
  `DIALOG_BLOCKING` with `output.started: false` and `output.dialog` while a
  blocking dialog is up. This is checked in `DispatchTool`, so socket, imported
  `CallTool` and async calls all get it.
- **Map switches unwind first.** `EditNewMap`, `OpenMapInEditor` and `PlayMap`
  leave the current map synchronously (`_UnwindToMenu`) before queueing their
  coroutine. A save prompt stops them with `DIALOG_BLOCKING` and nothing queued;
  the prompt stays up for the caller. A clean map unwinds and proceeds as before.
  Nothing ever answers a save prompt by itself.
- **`BackToMainMenu`** checks for a dialog every frame and counts only the real
  main menu (no editor or playground, not loading) as reached.
- **`EditNewMap`** leaves the map before touching decorations, verifies the
  standard fid before trusting or swapping it (else `EDITNEWMAP_FAILED`, "restart
  the game"), never returns with a swap in place, allows one swap at a time
  (`EDITNEWMAP_BUSY`), undoes an in-flight swap in `Shutdown`, and reports its
  coroutine's `output.status` (`requested`, `opened`, or `error: ...`).
- **Test starts** wait up to `waitMs` (default 10 s) for the playground and
  return `PLAYGROUND_NOT_STARTED` otherwise.

## Options weighed

**Where to report.** (a) Per tool, as `dialogAfter` already does for 15
dialog-prone tools: every new tool must remember it, and read-only tools
(`GetMode`, `WaitUntil`) never say a dialog is up. (b) One compact field added
by the dispatcher to every response: one place, no tool can forget, and the
caller learns about a dialog on its next call whatever that call is.
**Chosen: (b)**, keeping (a) unchanged for compatibility. It lives in the
envelope (`data.dialog`) rather than in `result.output`, so no tool output
changes, and the MCP adapter already forwards the whole envelope. Imported
`CallTool` returns only `result`; those callers keep using `GetDialog`.

**Cost.** The compact read is a few BasicDialogs fields plus a loop over
`ActiveMenus` (usually one to three entries): no yield and no control-tree walk.
When clear it adds about 22 bytes (`,"dialog":{"up":false}`). The full snapshot
(`BuildDialogSummary`, editor frames and menu classes) stays opt-in.

**When to sample.** *Before* the call: done only where it changes the decision
(the refusal list); the envelope would otherwise say what the caller already
knew. *After* the call: the envelope, last thing before replying.
*After N frames*: rejected as a fixed rule, because it costs N frames on every
call and still misses a slower dialog. The tools that cause late dialogs now wait
for the outcome instead (menu reached or dialog up; playground started or not),
and any other late dialog shows up in the next response's `data.dialog`.

**Dirty map: refuse or unwind?** There is no "map modified" flag in the game
API (searched `OpenplanetNext.json`), so the only signal is the prompt itself.
Refusing every call made from the editor would break the one-call new map from
a clean editor. **Chosen: unwind, then stop on the prompt** with the call that
answers it. An explicit `discard`/`save` parameter was not added; see open
questions.

## Live checks (not yet run)

Run with the plugin reloaded on this branch, from a quiet game.

1. Editor, place something (dirty), then `EditNewMap {"vista":"nostadium-day"}`:
   error `DIALOG_BLOCKING` ("stopped before acting"), `output.started:false`,
   `output.dialog.dialogKind:"askYesNo"`, `data.dialog.up:true`; the log shows no
   `EditNewMap2` and no `EditNewMap: fid=` line.
2. `GetMode`: `data.dialog` `{"up":true,"kind":"askYesNo","blocking":true,"frame":"FrameAskYesNo",...}`;
   call.py prints a `dialog up:` line on stderr.
3. `EditNewMap` again with the prompt up: `DIALOG_BLOCKING`, message "refused".
   Same for `BackToMainMenu` and `ControlValidation {"action":"testFromStart"}` (editor).
4. `SaveMapFlow {"save":false}`, `WaitUntil {"condition":"mode","equals":"Menu"}`:
   `data.dialog.up:false`.
5. `EditNewMap {"vista":"nostadium-day"}` three times, each followed by
   `WaitUntil mode MapEditor` then `BackToMainMenu`: editor opens every time;
   `output.status` is `requested`; log shows `nod=48x48Screen155Day swapped=true`.
6. Clean editor (just opened), `EditNewMap {}`: opens a new map in one call.
7. Editor, new empty map, `ControlValidation {"action":"testFromCoord","x":..,"y":..,"z":..}`:
   success, `playgroundStarted:true`. `requestLeavePlayground`, wait for `MapEditor`,
   `testFromCoord` again: `PLAYGROUND_NOT_STARTED` after about 10 s.
8. `BackToMainMenu` from a race (`PlayMap`): `reachedMenu:true`. From a dirty editor:
   `blockedByDialog:true`.
9. `GetReadiness {"want":"editor"}` with the map-saved card up (`SaveMapFlow {"name":..,"dismissCard":false}`):
   `dialogKind:"menuDialog"`, not ready (this is a behaviour change).
