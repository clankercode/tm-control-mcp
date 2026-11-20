# Changelog

All notable changes to **tm-control-mcp** are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versions follow `info.toml` `[meta] version`.

## [Unreleased]

### Fixed

- 2026-11-19: `BackToMainMenu` returns an error when it does not reach the main menu: `DIALOG_BLOCKING` when leaving raised a dialog (usually the unsaved-changes prompt), `UNWIND_TIMEOUT` (retryable) otherwise, same as the map-switch tools. It used to return success with a `note`, so callers that only checked `success` carried on as if at the menu.
- 2026-11-19: editor-mutating tools are refused with `DIALOG_BLOCKING` while a blocking dialog is up (`PlaceBlock`, `RemoveBlock`, `Clear*`, `Undo`/`Redo`/`UndoRedo`, `CopyPasteSelection`, `SetMoodTimeOfDay`, the E++ place/remove and named-macroblock tools; `ToolMutatesEditor` in `src/DialogPolicy.as`). Live case: a script kept editing behind "save changes?" after its `OpenMapInEditor` was refused. Answering, saving, reads and camera tools stay allowed.

- 2026-11-17: `tools/call.py` host-log fallback for `ControlPlugin` load/reload/getLogs now reads the `Openplanet.log` of the game listening on `--port` (its wineserver's `WINEPREFIX`), not `~/OpenplanetNext`; on multibox hosts (x-boss, where `~/OpenplanetNext` is an NFS mount of xsm's) it returned another game's stale lines. `TM_OPENPLANET_LOG` still wins; reports now include `logPath`.

### Added

- 2026-11-20: `AnimateEditorCamera` + `WaitEditorCamera`: smooth map-editor camera animation in the background, one at a time. `kind:'path'` flies through keyframes (`x,y,z`/`distance`/`hAngle`/`vAngle`, or `position`+`lookAt`; spline through every key by default; `durationMs` split by travel distance, or `ms` per key; easing `inOut` by default). `kind:'orbit'` circles a point (`degrees` over `durationMs` or at `degreesPerSecond`; `endDistance`/`endVAngle` spiral; `untilStopped`). `kind:'follow'` tracks the editor cursor or a point moved with `{action:'retarget'}` (`lagMs` smoothing, optional slow spin). Also `action:'stop'|'status'`. A running animation is interrupted by `SetEditorCamera`, `ControlCamera` actions, `SetEditorOrbitalTarget`, `TakeScreenshot focus`, a new animation, the camera being moved by anything else (mouse, keyboard, another plugin: the last write is compared with the read-back each frame), or leaving edit mode. `WaitEditorCamera {id?, timeoutMs?}` (max 300000) succeeds on completion and returns `CAMERA_ANIM_INTERRUPTED`/`CAMERA_ANIM_STOPPED` with the reason otherwise; a timeout returns `timedOut:true`. Writes apply the same frame with no engine smoothing; hAngle wraps to (-pi, pi] and vAngle is clamped by the editor to 4.5..85.5 degrees, so animations clamp it and warn (verified live, `src/EditorCameraAnim.as`, `src/EditorCameraAnimPolicy.as`). `SetEditorCamera`'s `animate` flag was never implemented; its description now points here.
- 2026-11-20: `MaxFPS {fps?}`: read or set the game's frame limit (`CSystemConfig.Display.MaxFps`; `0` = uncapped, else 10..1000), with the measured `averageFps`. Applies from the next frame for the session; not saved to the game's config file (verified live: 40 -> 30 measured 30.0, 0 measured ~100) (`src/MaxFps.as`).
- 2026-11-20: the MCP adapter (`mcp-cli`) gives wait tools a deadline past their own timeout: `WaitUntil` the plugin's 35-minute budget (a loading screen extends it), `WaitEditorCamera` its `timeoutMs` + 5 s. Every call used to share a fixed 30 s deadline, so a longer wait failed with 'native deadline exceeded'. `tools/call.py` sizes its socket timeout for `WaitEditorCamera` too.
- 2026-11-20: call overlay hide list (DEV): setting "Tool call overlay: hide tools" (`S_TmMcpCallOverlayHide`, comma-separated, default `Present.Events,Present.Heartbeat`). Listed tools get no row but still count: the header reads e.g. `MCP tools: 766 (512 hidden)`, and status `calls.callOverlayHidden` reports the count. Keeps the presentation director's own polling from filling the 8 rows in recorded takes (`src/CallOverlay.as`, `src/CallOverlayPolicy.as`).
- 2026-11-20: `ClickManialinkControl {page, id, index?}`: click ManiaLink UI in any context, addressed as `ViewManialinkPage` prints it (the Nadeo `*-navigation-item-zone` hitbox, else the control, via `CControlBase::OnAction`). Refuses `NOT_DRAWN` when the control, an ancestor or the page is hidden. Ids repeat in list templates, so `index` counts the lines `ViewManialinkPage` prints with that id (verified live: `index:5` toggled exactly row 5's ghost of 8) and the result reports `matches`. Not refused behind dialogs. Verified live: Home → Create → Back in the menu, and a records-list ghost toggle while racing (`src/ManialinkActions.as`).
- 2026-11-20: `WaitUntil {condition:manialink, page, id?, index?, text?, state?}` waits for ManiaLink UI to be drawn (`shown`, every ancestor visible) or `gone`, in any context; `text` matches the control's text; `gone` on a page that never matched warns (`pageEverFound:false`). Its `timeoutMs` (default 20000) caps the whole wait, loading included, at 300000 (5 min).
- 2026-11-20: `ViewManialinkPage {find}` keeps only matching lines plus their ancestors; brief view keeps quad icon buttons (`button-*` ids, e.g. `button-toggle-ghost`); entry values have `$` codes stripped unless `rawText`. Menu-only tools (`GetUILayers`, `GetLayerTree`, `ListMenuManialinkControls`, `FindControlsByLabel`, `FindMenuButtons`, `ClickMenuButton`, `GetActiveMenuPages`) now point at the context-wide ones.
- 2026-11-20: `ListManialinkPages` + `ViewManialinkPage` (read-only): what ManiaLink UI is on screen, across the menu, the playground client and its UI configs, and the map editor plugin app (`GetUILayers`/`GetLayerTree` read only the menu). Pages have a ref (`menu:19`, `playground:5`) and their `<manialink name>`; current context first. The view is a concise indented tree, one control per line (`frame#button-play .component-navigation-item "Play"`): decoration dropped, layout wrappers collapsed, a button's label on the button's line; `full:true` prints everything. "Visible" means the layer and its root frame are shown: menu layers stay `IsVisible` under a map with a hidden root frame (verified live). Loading-screen layers are skipped unless named; passwords redacted; `truncated`/`omittedPages`/`depthLimited` report cuts (`src/ManialinkView.as`, `src/ManialinkViewPolicy.as`).
- 2026-11-20: call observers for in-process plugins (exports `AddCallObserver`, `RemoveCallObserver`, `DrainCallObserver`). A subscriber names tools from a fixed allowlist of read-only tools (`GetMode`, `GetMapInfo`, `GetVehicleState`, ...) and drains bounded `admitted`/`completed` records for socket calls only; direct, imported and nested calls are never recorded. Subscriptions are owner-scoped (claimed plugin id must be loaded and enabled), max 2 per owner and 8 total, dropped when the owner unloads (`src/CallObservers.as`). Used by `tm-mcp-pack-presentations`.
- 2026-11-20: DEV builds show a bottom-left HUD of recent tool calls (name, duration, ok/`ERR:code`), setting "Show tool call overlay"; status reports `callOverlayTotal` (`src/CallOverlay.as`).
- 2026-11-18: `GetPauseState` samples three clocks, including online. `ControlPause {action:pause|resume|toggle}` uses the native menu on solo/local play only. Pause verifies a full menu-up hold with unchanged clocks and never closes a pre-existing menu. Failed Show verification attempts at most one cleanup Resume after a fresh gate in the same context; reports the observed menu state (or unknown) and pending Show risk. Missing `jumpMs` is unmeasured. There is no background cleanup.
- 2026-11-18: `GetDisplaySetting` / `SetDisplaySetting {bloom}` / `RestoreDisplaySetting {force?, retire?}` read and write bloom. Set requires a valid prefix port marker and writes a single restore record before changing bloom. Explicit Restore retains the record; `force:true` overrides a value conflict only within the same identity and config. After confirming the prior stuck on reload or restart, explicit `retire:true` removes the matching record without writing bloom. **Unproven live:** Q1 programmatic pause freezes like ESC, Q2 bloom none applies without a restart, Q3 Apply timing, persistence and window/device effects, Q4 local hosted play pauses. Guide: `pause-bloom`.

- 2026-11-17: `ListTools` tool: every callable tool with its pack and owning Openplanet plugin id (`core` / the bridge's id for built-ins). Each pack also reports `definedAt` `{file, line, function}`, its `RegisterToolPack` call site, in `ListTools` and `ListToolPacks`. The bridge captures it once per registration from the pack's own context stack (a marker plus one log line per frame); packs need no change.

- 2026-11-17: `GetBlockingScreen` + `DismissBlockingScreen`: detect and dismiss the two full-page menu screens that stall menu-only agents and that `GetDialog` cannot see — the disconnection flow (`Page_ConnectionError` pop-up → Confirm → `Page_PressStart` → Play offline / Retry / Quit game) and the PressStart start prompt (waits for input while online-services maintenance is planned). Detection is page name + control id + effective visibility (button `.Visible` stays true under a hidden parent frame; labels are set by the page script and only reported). Dismissal clicks through `CControlBase::OnAction` (nav-zone leaf for expendable buttons), whitelisted per action, never clicks Quit game; `waitMs` waits for the state to change and reports `after` + `menuReached`. `GetReadiness` (`menu`/`any`) now reports these screens as a blocking reason (`checks.menuBlockingScreen`); `WaitUntil` gains `menuReached` and `blockingScreen` (`docs/blocking-screens.md`, `src/BlockingScreens.as`, `src/BlockingScreensPolicy.as`).

- 2026-11-17: mcp-cli: read-only loopback audit endpoint `GET /monitor/snapshot` on every Streamable HTTP listener (`serve --transport http`, `monitor --serve`) — sanitized, bounded monitor events plus stats, a per-listener instance nonce, and an `ETag` so unchanged polls are served from a cached body; `Origin` (exact match) and `Host` guarded like the MCP route. `monitor --attach ADDR` audits such a server (default `127.0.0.1:30007`), probing before the terminal opens, reconnecting with backoff, freezing elapsed timers while disconnected, and resetting the selection when the instance nonce shows a server restart (`mcp-cli/src/audit.rs`).

### Removed

- 2026-11-19 (pause/bloom, before release): `ControlPause` `autoResumeAfterMs` and everything behind it (the ownership watcher, timers, context generations, background Resume retries and the disable/unload menu close); the automatic bloom restore on plugin start, disable and unload; keep-oldest priors with a list of applied values; the `display-restore.next.txt` side-file journal. These were never released. The agent now resumes and restores explicitly. An older `display-restore.json` / `display-restore.txt` record is reported by `GetDisplaySetting` (`legacyRecord`) and blocks `SetDisplaySetting` until removed by hand; it is never applied or migrated.

### Changed

- 2026-11-17: **breaking (mcp-cli):** `monitor` no longer starts an HTTP MCP server by default; it attaches to an existing listener via the audit endpoint above. `monitor --serve` restores the previous bind-and-serve behaviour, and server-only flags (`--listen`, `--native-*`, `--poll-ms`, `--origin`, `--events-jsonl`, `--screenshots-dir`) are rejected in attach mode with a pointer to `--serve` (`mcp-cli/src/main.rs`, `mcp-cli/src/tui.rs`).

- 2026-11-15: `ResolveMwIds`: MwId values to names and names to values, batched. Values are named only after a read-only check that their intern slot is occupied (`GetName()` on an unknown tag-01 id can crash the game); names resolve by a read-only lookup that ports the engine's hash and probe order and is self-tested against the live tables, or with `register:true` through `MwId.SetName`, which adds missing names and reports `registered`/`existed`; DEV builds can read ids at `ptr` (`src/MwIds.as`, `src/MwIdPolicy.as`).
- 2026-11-15: `GetInputBindings` (read-only): input devices (`InputPort.ConnectedDevices`), pads (`Script_Pads`) with live held buttons/axes, each pad's per-action bindings via `InputBindings_UpdateList(All, pad)` (as Settings > Controls), the Device=null list, and per-pad `GetActionBinding(pad, "Vehicle", id)` for GiveUp/Respawn/SecondaryRespawn; puts back the shared binding list it refills (`src/InputBindings.as`, `src/InputBindingsPolicy.as`).
- 2026-11-15: classic (engine `CGameMenuFrame`) menu tools: `ClickClassicMenuControl {id}` clicks a named control or card on `app.ActiveMenus`, and `JoinServer {link}` opens a `#join=` link, confirms the server card and waits for the playground (`src/ClassicMenus.as`). `RespondDialog frame-ok` picks the first `ButtonSelection`, which on the join card is a map row, not Join.
- 2026-11-15: `SaveMapAs` fails with `DIALOG_BLOCKING` (`saved:false`, dialog left up) when the game answers the save with a prompt instead of saving; it used to report success (`src/McpTools.as`).
- 2026-11-15: every socket response has compact `data.dialog`; `dialogKind` no longer says `none` for the save prompt (`askYesNo`, `saveAs`, `menuDialog`, …, plus `blocking`); map switches and test starts refuse behind a dialog (`DIALOG_BLOCKING`) and stop on the save prompt instead of queueing; EditNewMap can no longer leave its decoration swap behind (the "EditNewMap does nothing until restart" bug); `testFrom*` fail with `PLAYGROUND_NOT_STARTED`. See `docs/dialogs.md`.

- Generic editor-script status/reload, offline pending-value recovery, and preloaded user-pack inspection/mounting. Preserved local tooling is ported with public-only interfaces.
- Confirmed, bounded text replacements for user editor scripts and menu pages, with readback verification.
- DEV native-auth availability diagnostics without credential acquisition or values.

- Read-only `GetManiaScriptDiagnostics`, `ControlFids getText`, item animation metadata scanning with `ScanKinematicItems`, and a tool-pack schema settings tab.
- Successful dialog-prone socket actions include a dialog snapshot after one frame. Script result collection reports unconfirmed execution when no event arrives and preserves observed crash diagnostics.
- `ShutdownGame` requires explicit confirmation and presents a cancellable 30-second countdown.

- Pack release metadata via `ToolPackBuilder.SetLatestReleaseUrl`, cached
  background SemVer checks using the actual installed plugin version, and update
  status in `ListToolPacks` and Settings → Updates. Missing metadata warns without
  breaking legacy packs. Checks can be disabled and never install updates.
- [Project website](https://clankercode.github.io/tm-control-mcp/) and
  `latest-version.txt` published together through GitHub Pages CI, with a
  [copy-paste author workflow](docs/pack-updates.md) for pack repositories.
- Native Windows process discovery for `tools/call.py` via `tasklist`, with
  structured failures if process enumeration is unavailable.
- `MeasureFrameTime` — yield N frames and report `elapsedMs` / `msPerFrame` / `minMs` / `maxMs` / `fps`. `frames` default 10 (1..30), `warmupFrames` default 1 (0..5). At the 30fps cap, 10 frames is ~333ms; 10 frames ~3000ms is a hitch.
- `SetMoodTimeOfDay` — write `CGameCtnEditorFree.MoodTimeOfDay01` (0..1); optional `dynamic` sets `MoodIsDynamicTime`. Returns previous+new `timeOfDay01` / `timeOfDayStr`. Needed before a second `ComputeShadows`: the game refuses a rebake when shadows are already cached for that mood.
- `ComputeShadows` — start `editor.PluginMapType.ComputeShadows1` and return immediately (`started`, `quality`, `bustCache`, `lightmapCompute`). `quality` is `CGameEditorPluginMap::EShadowsQuality` name or 0..5 (default Default). `bustCache` (default true) zeros `CHmsLightMapCache.m_Quality` like E++ Recalculate so a bake actually starts. Wait with `WaitUntil condition=shadowsClear`.
- `ControlFids` — Openplanet `Fids::` surface: `drives` / `get` / `list` / `preload` / `updateTree` / `extract` / `getFullPath` / `fromNod`. Five drives (`game|user|fake|resource|programData`), drive-relative paths, list capped at 400. `updateTree` refuses the empty game-drive path unless `force:true`. `extract` writes a file (`Fids::Extract`, or `dest` via `CopyToFileRelative`; `hookMethod` defaults false). `fromNod` takes `from_ptr` (hex/int nod pointer); preload/get report `nod.ptr`. Guide: `GetGuide {topic:fids}`.
- `GetTypeInfo` — live Openplanet `Reflection` dump. Default `{className:"CGameCtnChallenge"}` returns class metadata (name, id, size, base chain) plus **all members** (inherited included, tagged `declaredOn`). Optional `classId` / `from` (TypeOf a live nod), `member`, `ownOnly`, `query`, `limit`. `MwMemberInfo` has no member type name; `isField=false` when offset is `0xFFFF` (typically a method). Guide: `GetGuide {topic:reflection}`.
- `ControlOverlay` — show / hide / toggle **Openplanet's own overlay** (the F3 bar and plugin windows), not the game HUD. `UI::ShowOverlay` / `HideOverlay` / `IsOverlayShown` / `IsRendering`; documented API, no memory offsets. Reports `shown` and `rendering` separately (the global "Hide overlay on hidden game UI" option makes them disagree) plus `changed` / `asRequested`. Hide it before `ControlPlayCamera set_mode`, which is silently dropped while the overlay is over the view, and before any screenshot measuring rendered pixels. `settleFrames` (default 2) yields so the on-screen frame has caught up.
- `ControlPlayCamera`: in-play (Race) camera control — `get` reads camera type/flags/free-cam pose/spectator state (`raw=true` adds resolved offsets), `set_mode` switches free / cam 1-3 / backwards / alt / drivable, `set_position` places and aims the free camera. `x,y,z` + `target` solves the orbital form so the camera lands exactly and looks exactly at the target. `src/PlayCamera.as`; see README "In-play camera" for what does and does not take effect.
- `PlayMap` — load a local map (or URL) into play via `ManiaTitleControlScriptAPI.PlayMap`. Same `path` style as `OpenMapInEditor`. Optional `mode` / `settingsXml`. Unwinds editor/race to the menu first; `waitMs` reports a blocking leave dialog.
- Tool packs can set their public prefix with `ToolPackBuilder("id")` or `SetPackId`. Empty/omitted still uses the Openplanet plugin id. Custom ids: `[A-Za-z][A-Za-z0-9_-]{0,63}`; reserved `core` / `tm-control-mcp` / `TmMcp`. `UnregisterToolPack(plugin.ID)` drops every pack that plugin registered. Fixture pack now registers as `fixture.*`.
- `EditNewMap` and `BackToMainMenu` now warn when leaving a dirty map pops the unsaved-changes dialog (`FrameAskYesNo`). `EditNewMap` waits `waitMs` (default 1500) like `OpenMapInEditor`; `BackToMainMenu` stops early instead of spinning 10s. Answer via `RespondDialog` or `SaveMapFlow`.
- `EditNewMap` for custom environments (RedIsland / BlueBay / GreenCoast / WhiteShore) now passes the preloaded decoration nod IdName (`Day` / `Day64` / `Sunset64` / …, not `64x64Day`) to `EditNewMap2`. Non-Day moods use the chosen nod directly instead of SwapDecoHack.
- Map-load waits: idle budget is **20s** (was 12–15s). Once a loading screen is up (`WaitMessage` / `LoadProgress`), `WaitUntil`, `EditNewMap`, and `CreateMapViaMenu` keep waiting until the map finishes (hard cap 30 min). `call.py` socket timeout follows.

### Changed

- 2026-11-15: `RespondDialog frame-cancel` acts on the topmost modal frame (clicking its `ButtonCancel` when it has one) instead of the first active menu; at the main menu it used to call `Back()` on the menu and leave the server join card up (`src/McpTools.as`).
- 2026-11-15: errors that named a problem now name the next call: `ClickClassicMenuControl` `NOT_VISIBLE` / not-a-button, socket `unknown route` (lists the routes) and `missing tool` (shows the request shape), `reentrant_tool`, `RespondDialog saveas-setname` without the SaveAs dialog (`src/ClassicMenus.as`, `src/Protocol.as`, `src/ToolCalls.as`, `src/McpTools.as`).
- 2026-11-15: docs: README tool table has `GetMenuFrameTree`, `ClickClassicMenuControl`, `JoinServer` and the new frame-ok rule; the `catalog` route is how to list tools; `ControlPlugin {action:"reload", id}` is the reload tool (also for a stuck RemoteBuild). New in-game guide `plugins`; the `dialogs` guide covers classic menu cards (`README.md`, `AGENTS.md`, `src/Guides.as`).
- 2026-11-15: input validation names what is accepted: `unknown parameter 'path' (allowed: …)`, same wording as `call.py --strict` (`src/ToolInputValidation.as`).
- 2026-11-15: `RespondDialog {action:frame-ok}` no longer clicks the first `ButtonSelection` of a frame holding several cards (server join card): with no `ButtonOk` it refuses with `AMBIGUOUS_FRAME`, clicking nothing, and lists the card ids (`output.cards`) for `ClickClassicMenuControl {id}`. frame-ok/cancel report `output.frameClosed` and warn when the frame is still up. `data.dialog.hint` (and `DIALOG_BLOCKING` hints) now use the frame: on `FrameDialogJoin` they name `ClickClassicMenuControl {id:ButtonJoin}` and `JoinServer` (`src/McpTools.as`, `src/DialogPolicy.as`).
- 2026-11-15: unknown tool names get help: the error names the tool asked for (only when it is name-shaped; logs still get a placeholder), `suggestions` lists up to 5 real tools (built-in and pack) by case, shared words (Reload→Control) and edit distance, and the hint says the list is the `catalog` route (`python3 tools/call.py catalog`), not a tool. `call.py` prints the suggestions on stderr (`src/ToolNameSuggest.as`, `src/ToolCalls.as`, `tools/call.py`).
- Request traces record sizes only; raw arguments/responses are never logged. Metadata lines are bounded to 512 characters plus marker.

- `GetMode` and `GetServerInfo` now include `curGameModeStr` from `app.Network.ServerInfo` (`TM_PlayMap_Local`, hotseat, matchmaking, …). Empty when ServerInfo is null (typical outside a map).
- Map-summary reads (`GetMapInfo`, `GetItems`, `GetRecentItems`, `GetBlocks`, `GetRecentBlocks`, `GetWaypoints`, `GetMapEnvironment`) use `app.RootMap` (the same map nod in MapEditor and Race/play). Missing-map errors are `NO_MAP`. Mutators still require the editor (`NOT_IN_EDITOR`); `editor.Challenge` is an editor-presence check, not a different map.
- `GetMode` (and `GetMenuPage` / `GetReadiness` / `WaitUntil` mode) now reports specific editor kinds: `MapEditor`, `ItemEditor`, `MediatrackerEditor`, `MeshEditor`, `SkinEditor`, `ModuleEditor`. In-editor drive states are `MapEditor_Validate`, `MapEditor_Test`, `MapEditor_Playground` (not `Race`). `WaitUntil equals=Editor` matches any editor; `equals=MapEditor` matches `MapEditor` and `MapEditor_*`. Unknown editor classes still return `Editor`.
- `GetToolList()` now caches the built tool array and rebuilds only when a pack is registered, unregistered, or swept. Callers (e.g. tm-agent's chat UI) were paying ~1–2 ms per call to re-parse ~90 schemas every frame.

### Fixed

- 2026-11-17: socket listener no longer closes and re-listens on every loop pass when the bound port differs from the wanted one for the listener's whole life: a `PluginStorage/tm-control-mcp/port.override` (bound 30400 against the default setting 30006 gave about 30 ms churn and reset every client connection), or a fallback port taken because the wanted one was busy. The loop now rebinds only when the wanted host or port changes since bind time (`ShouldRebindListener` in `ServerPolicy.as`, tested in stock AngelScript).

## [0.4.0] — 2026-08-16

### Changed

- **`TakeScreenshot`** now waits for the capture file and reports it: `fullName` (game-side path from `Viewport.ScreenShotFullName`) + `sizeBytes` + `detected`, with `waitMs` (default 5000, `noWait`/`0` for fire-and-forget) and `timedOut` on miss. New options: `hideOverlay` (native `DisableOverlayRender`, restored after), `forceRes`+`width`/`height` (native `ScreenShotForceRes/W/H`, restored after). `format` is now validated (`jpg|webp|tga|dds`). Crash-prone native paths (360°, tiling, alpha/pixel-output) remain unexposed — documented in the new `screenshots` guide.

### Added

- `screenshots` guide (`GetGuide {"topic":"screenshots"}`): native capture pipeline, file locations/numbering, safe options, and the deliberately-unexposed crash-prone viewport settings.

## [0.3.0] — 2026-08-15

### Added

- **Tool packs** (issue #5): `RegisterToolPack` / `UnregisterToolPack` / shared `ToolPackBuilder`. Pack tools are `packId.FuncName`. Builtin `ListToolPacks`. Authoring: [docs/tool-packs.md](docs/tool-packs.md). Fixture: `tools/fixtures/tm-mcp-pack-fixture/`.
- In-process export surface (`TmMcp_Export.as`, issue #1): `import` from `"TmMcp"` for all major tools + `CallTool`/`IsToolName`/`DispatchAsync`/`GetResult`
- **Socket toggle** (`S_TmMcpEnableSocket`): skip TCP listener for pure in-process use
- **Async dispatch** (`DispatchAsync` + `GetResult`, issue #3): non-blocking tool dispatch with poll semantics
- **Race tools** (issue #2): `GetRaceData`, `GetPlayers`, `GetServerInfo` — ported from tm-mcptm
- `MLFeedRaceData` dependency added
- Migration guide: [docs/migration-from-mcptm.md](docs/migration-from-mcptm.md)
- `ControlPlugin` RemoteBuild-parity: `load` by plugin id (`Plugins/<id>/` or `<id>.op`), unload-then-load rebuild, `getLogs` from `Openplanet.log`
- Socket Settings tab + exported `StartSocket` / `StopSocket` / `SetSocketEnabled` / `GetSocketStatus`
- ~~Editor++ (`Editor`) optional~~ → E++ tools moved out entirely in 0.3.0
- Request-payload trace writes to plugin storage (`request-trace.log`), not `Openplanet.log`
- `GetVehicleState` / `ListVehicleVis` / `GetVehicleVis` (VehicleState::) and `GetRenderCamera` / `ProjectWorldToScreen` / `SetEditorOrbitalTarget` (Camera::)
- One-line Openplanet `trace` at each tool start (name + args) and finish (ok/err + ms)

### Changed

- **E++ tools moved to [tm-mcp-pack-epp](https://github.com/clankercode/tm-mcp-pack-epp)** (breaking): freeblock/item placement, named macroblocks, tag provenance, inventory control/edit-mode/item-editor, macroblock inspection, E++ camera focus. `Editor` removed from `optional_dependencies`. Old builtin names return `moved_to_pack`.
- Plugin list/get default to `sourcePathBase` (basename); full path via `includeSourcePath`
- `call.py` screenshot detection adds `linuxPathHomeRelative`
- README documents tested Editor++ 0.8.x and MLHook ≥ 0.5.4
- Socket enable/host/port apply live (no plugin reload). `S_TmMcpEnableSocket` is hidden.

## [0.2.0] — 2026-08-12

First tagged public GitHub release.

### Changed

- **DEV/RE tools gated behind `#if DEV`** — release builds (no `defines = ["DEV"]`) no longer register or dispatch:
  - `RunGizmoApplyBlock`, `RunRandomFuzz`, `RunComputeItemsDiagnostic`
  - `DevSafeRead`, `DevGetPointers`, `DevComputeItemsPointers`, `DumpMacroblockHeader`
  - Folder **dev** staging (`./build.sh dev`) still injects `DEV` and exposes them
- `status` route reports live `Meta::ExecutingPlugin()` name/version/id (no hardcoded version)
- README / SECURITY note that memory tools are dev-build only

### Added

- `tools/smoke_tag_cleanup.py` — live agent recipe: readiness → tag → place → assert → `RemoveByTag`
- Release packaging docs already in `RELEASE.md` (`release-check`, GH notes + `.op` asset)

### Notes

- Script timeout remains **15000 ms**
- Dual Unlicense / CC0 unchanged

## [0.1.0] — 2026-08-12

First public GitHub surface (`clankercode/tm-control-mcp`) before the tagged release.

### Added

- Localhost JSON TCP control socket (`127.0.0.1:30006` by default)
- Large MCP-style tool surface for editor, menu, placement, inventory, camera, dialogs
- **Agent ergonomics (Tier A)**
  - `GetReadiness`, `WaitUntil`
  - Provenance tags: `SetAgentTag`, `ListTagged`, `RemoveByTag`, `ClearTagIndex`
  - `ControlEditMode`, `SelectItemModel`, `SelectMacroblockModel`, `ControlInventory`
  - Durable named macroblocks: `SaveNamedMacroblock`, `LoadNamedMacroblock`, `ListSavedNamedMacroblocks`
  - `AssertPlacement`
  - `RunManialinkScript` result channel (`collectMs` / `resultEvent`)
  - Structured error fields (`code`, `retryable`, `requiredMode`, `hint`)
- **Menu automation** via `CControlBase::OnAction` (not `TriggerPageAction`)
- **Openplanet Meta:: plugin & settings control**
- **Map objectives**: `ControlMapObjectives` (clones / laps)
- Freeblock / item placement via Editor++
- Named in-memory macroblocks with skins + batch add
- DEV / RE diagnostics (later gated in 0.2.0 for non-DEV builds)
- `tools/call.py` client with process check, wait helpers, screenshot detection
- Dual license: Unlicense **or** CC0 1.0
- In-plugin guides (`ListGuides` / `GetGuide`)
- `SECURITY.md`, `RELEASE.md`, CI pytest, `release-check` DEV-off gate
