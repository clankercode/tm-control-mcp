# ManiaScript failure evidence

A live Trackmania process and successful MLHook injection do not prove the injected
script compiled. A bad Manialink script can stop the editor maptype while the game
and Openplanet stay alive. This is different from a native game crash.

Run `python3 tools/maniascript_diagnostics.py --screenshot --output /tmp/maniascript-failure.json`
to preserve a read-only diagnostic snapshot and an overlay-visible viewport image.
The image path is in `screenshot.data.result.output.detectedScreenshot.linuxPath`.
The native Script debugger must already be visible with its Log area in view for
the screenshot to contain the error. The helper does not restart, dismiss, or
change debugger selection.

`GetManiaScriptDiagnostics` reads the active FrameAskYesNo message and the native
debugger visibility. The native debugger log rows are not exposed by the current
Openplanet API. To read them without OS input, call
`DismissManiaScriptDebugger {"visibility":"LogsFull"}` and take a window capture
(`scripts/capture-instance-window.sh N` on tmc hosts); the compile error, e.g.
`ERROR [153, 135] Function MB_MapIsRunning not found`, is legible there
(2026-11-22). Call it again with `Hidden` afterwards.

Every debugger view but `Hidden` covers the game (a ManiaLink compile error
opens `LogsFull`). `GetBlockingScreen` reports them as `kind:"maniascript-debugger"` and
`GetReadiness` as a blocker in every mode. `DialogEditScript_TempText` is script source, not the error log.
`logAvailable:false` means unavailable, never an empty/clean log. A dismissed
crash prompt can leave the maptype stopped, so `healthConfirmed` stays false.

`RunManialinkScript` refuses injection while a recognized script crash prompt is
open. A prompt observed after injection returns `MANIASCRIPT_CRASH`, retaining
output and diagnostics. Collection with no events returns
`MANIASCRIPT_RESULT_TIMEOUT`: execution is unconfirmed, not proven failed.
Without collection, success acknowledges injection only (`executionConfirmed:false`).
An event confirms only that the result hook received an event, not all script
side effects or future health; concurrent scripts should use distinct resultEvent
values. Error responses retain cleanup/result information in output.

Preserve the native debugger image before recovery. The game's crash prompt
advertises Shift+Scroll Lock for restarting scripts. After recovery, check that
the failed instance is green. A game mode script (`CPlugFileTextScript`) that
failed to load stays loaded for the life of the game process: fixing the file
on disk does not recompile it (observed 2026-11-22). Recovery then needs a fresh
game process. Do not substitute the editor's ButtonReloadScripts,
which reloads editor plugins, for a proven maptype restart. No automatic recovery
is performed by these diagnostics.
