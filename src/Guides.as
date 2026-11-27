namespace TmMcp {
    // Self-documentation for tm-control-mcp. Tool descriptions are one-liners;
    // guides below carry the conceptual model, limits, and recipes that would
    // otherwise bloat every tool schema.

    class _Guide {
        string topic;
        string title;
        string body;
        _Guide(const string &in t, const string &in tl, const string &in b) {
            topic = t;
            title = tl;
            body = b;
        }
    }

    _Guide@[] g_Guides;

    void _RegisterGuide(const string &in topic, const string &in title, const string &in body) {
        g_Guides.InsertLast(_Guide(topic, title, body));
    }

    void _InitGuides() {
        if (g_Guides.Length > 0) return;

        _RegisterGuide("item-skins",
            "Applying skins to placed items",
            "Item skin application is post-placement only. The public pmt.SetItemSkin(s) API"
            + " requires CGameCtnEditorScriptAnchoredObject wrappers from pmt.Items, which is"
            + " only populated while a Manialink plugin is active in the editor script context."
            + " Under tm-control-mcp (no Manialink), pmt.Items is empty, so tm-editor-plus-plus"
            + " exposes Editor::SetItemSkinsRaw which writes pack-desc pointers directly to"
            + " CGameCtnAnchoredObject at offsets 0x98 (bg) and 0xA0 (fg), bumps the pack-desc"
            + " loaded flag at +0x98=4, and bumps the item change counter at +0x170.\n"
            + "\n"
            + "Usage through AddItemToNamedMacroblock + PlaceNamedMacroblock:\n"
            + "1. AddItemToNamedMacroblock {name, itemPath, x, y, z, bgSkin, fgSkin}\n"
            + "2. PlaceNamedMacroblock {name}\n"
            + "3. Readback via GetRecentItems — actualSkin.hasSkin should be true.\n"
            + "\n"
            + "Which items accept skins: LightCube2m/4m/8m confirmed. Block skins have their"
            + " own support matrix (see 'block-skins' guide).\n"
            + "\n"
            + "URL resolution: skin URLs resolve through Editor::GetPackDesc which borrows a"
            + " shared temp block. Within one PlaceNamedMacroblock call, tm-control-mcp caches"
            + " pack-descs by URL to avoid hammering the temp block.");

        _RegisterGuide("block-skins",
            "Applying skins to placed blocks",
            "Block skins go through pmt.SetBlockSkins which is not gated on Manialink, so"
            + " tm-control-mcp can call it directly after placement. AddBlockToNamedMacroblock"
            + " + bgSkin/fgSkin + PlaceNamedMacroblock works end-to-end.\n"
            + "\n"
            + "Not every block model accepts skins. Confirmed accepting: TechnicsScreen1x1Straight,"
            + " 2x1Straight, 4x1Straight. Confirmed not reflecting: TechnicsScreen155Straight,"
            + " 155StraightX2, 2x3StraightSmall. Use ApplyNamedMacroblockSkinsDirect's error"
            + " payload to detect unreflected skins (error 'skin was not reflected on block"
            + " after SetBlockSkins').");

        _RegisterGuide("macroblock-placement",
            "How named macroblocks are placed",
            "AddBlock/Item calls append to an in-memory MacroblockSpec keyed by name"
            + " (g_NamedMacroblocks). PlaceNamedMacroblock duplicates the spec, calls"
            + " Editor::PlaceMacroblock through tm-editor-plus-plus, then runs"
            + " ApplyNamedMacroblockSkinsDirect as a post-phase against the new map indices.\n"
            + "\n"
            + "Gotchas:\n"
            + "- MCP in-memory state persists across PlaceNamedMacroblock. AddItem to the same"
            + "  name twice will grow the macroblock; create a fresh name per placement to avoid"
            + "  accumulation.\n"
            + "- The 'blockBaseIndex' passed to skin application is the map's Block count BEFORE"
            + "  placement; itemBaseIndex is the AnchoredObjects count before placement. Map"
            + "  items appended during placement take indices [base..base+added).\n"
            + "- PlaceNamedMacroblock's 'autofocus' defaults on and moves the camera; disable"
            + "  with 'autofocus: false' for headless runs.");

        _RegisterGuide("menu-navigation",
            "Navigating the main menu via MLHook",
            "SetMenuPage {route} pushes the route onto the main-menu Router_Push event queue"
            + " through MLHook. Works only while in the main-menu module (GetMenuPage.inMenus"
            + " must be true). Routes are opaque strings; ListKnownMenuRoutes returns the set"
            + " documented by tm-menu-page-manager.\n"
            + "\n"
            + "Discovering buttons on the current page:\n"
            + "- FindMenuButtons (no args) returns a flat list of visible nav buttons across"
            + "  all layers. Each result has layerIndex, layerName, controlId, absPos/size,"
            + "  raw label, and translation-stripped displayText (e.g. 'Track editor').\n"
            + "- FindControlsByLabel {substring} for fuzzy text search.\n"
            + "- FindControlsByClass {classPattern} for filtering by class (e.g. 'zone').\n"
            + "- Drill-in: GetUILayers + GetLayerTree {layerIndex, rootPath?} to walk a"
            + "  specific layer's control tree.\n"
            + "- Any context (menu, map, editor): ViewManialinkPage {page?, find?} shows a"
            + "  concise tree of what is drawn; ClickManialinkControl {page, id, index?}"
            + "  clicks it; WaitUntil {condition:'manialink', page, id?, text?,"
            + "  state:'shown'|'gone', timeoutMs<=300000} confirms the result.\n"
            + "\n"
            + "Verifying a push landed:\n"
            + "- GetActiveMenuPages returns the visible Page_* layers (e.g."
            + "  Page_MapEditorSettings, Page_Create). Router transitions are async,"
            + "  so poll this after SetMenuPage until the expected Page_* is visible.\n"
            + "- GetMode stays 'Menu' for same-module pushes; it only flips to 'Race'"
            + "  / 'Editor' if the route cascades into a playground.\n"
            + "\n"
            + "SAFETY: some routes auto-launch a playground. Observed"
            + " 2026-04-20: /solo/campaigndisplay silently started the current"
            + " campaign map and transitioned to Race mode. SetMenuPage blocks"
            + " known side-effect routes (/solo/campaigndisplay,"
            + " /solo/monthlycampaigndisplay) by default; pass"
            + " allowPlaygroundLaunch:true to confirm. Check with GetMode"
            + " (returns mapName + selfHosted when a map is loaded) and use"
            + " BackToMainMenu to unwind. Rule of thumb: routes for a SINGLE"
            + " selected thing (campaign, replay, match) may auto-enter;"
            + " list/settings routes (/create, /create/mapeditorsettings) are safe.\n"
            + "\n"
            + "Hierarchical paths (important!):\n"
            + "- Subpages require their FULL path, not just the leaf name. The button labeled"
            + "  'Track editor' on /create calls Router_Router::Push(This,"
            + "  '/create/mapeditorsettings'), so SetMenuPage must use"
            + "  '/create/mapeditorsettings'. Pushing the bare leaf '/mapeditorsettings'"
            + "  renders a blank Page_LoadingScreen because no route by that name exists.\n"
            + "- Call ListKnownMenuRoutes; it returns both 'topLevel' and 'subpages' arrays.\n"
            + "- Verified subpages (2026-04-20): /create/mapeditorsettings, /create/garage,"
            + "  /create/edit-replay, /create/server-review, /create/prestige-recap,"
            + "  /solo/library-clubcampaigns, /solo/weekly-tracks,"
            + "  /solo/monthlycampaigndisplay, /solo/campaigndisplay.\n"
            + "\n"
            + "Reverse-engineering a page's routes:\n"
            + "- GetLayerXml {layerIndex, find:'Router_Router::Push'} enumerates every"
            + "  destination the page's Select() can route to, with exact path strings.\n"
            + "- Clicks on component-navigation-item frames dispatch"
            + "  ComponentNavigation::C_EventType_NavigateMouse to the page script, which"
            + "  switches on _Control.ControlId and calls Router_Router::Push. There is no"
            + "  SendCustomEvent layer — the click handler IS the page's own script function.\n"
            + "\n"
            + "Extras (route hydration payload):\n"
            + "- SetMenuPage {extra: '{\"Key\":\"Value\"}'} passes a JSON string through the"
            + "  MLHook Router_Push event slot. Verified against tm-menu-page-manager usage:"
            + "  e.g. /matchmakingmainpage accepts '{\"ForceMode\":\"Royal\"}'.\n"
            + "- Some subpages (e.g. /solo/campaigndisplay) RENDER correctly without extras"
            + "  (Page_CampaignDisplay becomes visible) but their content panel stays empty"
            + "  because the hydrating args (e.g. {\"Campaign\": \"<name>\"}) are missing.\n"
            + "- tm-menu-page-manager's defaultExtraArgs documents the navigation-history"
            + "  controls: {\"SaveHistory\":true,\"ResetPreviousPagesDisplayed\":true,"
            + "  \"KeepPreviousPagesDisplayed\":false,\"HidePreviousPage\":true,"
            + "  \"ShowParentPage\":false,\"ExcludeOverlays\":[]}. These go in the THIRD"
            + "  MLHook event slot — currently hardcoded to '{}' in SetMenuPage.\n"
            + "\n"
            + "Clicking buttons (LANDED):\n"
            + "- ClickMenuButton {controlId} descends to the nav-zone leaf and calls"
            + "  CControlBase::OnAction — safe from Angelscript. TriggerControlOnAction"
            + "  is the lower-level primitive (optional recursive DFS).\n"
            + "- NEVER use CGameManialinkScriptHandler::TriggerPageAction — native"
            + "  openplanet.dll crash.\n"
            + "- CreateMapViaMenu drives the full Page_MapEditorSettings chain"
            + "  (requires MapEditor QuickStart OFF).\n"
            + "\n"
            + "Ad-hoc ManiaScript:\n"
            + "- RunManialinkScript {script, context?} injects via MLHook into menu /"
            + "  in-map / in-editor (default context=current). Same idea as MLHook's"
            + "  UILayers browser Create button. No outer <manialink> tags. Pages are"
            + "  sandboxed; useful for TitleControl and local game-object access.\n"
            + "\n"
            + "Limitations:\n"
            + "- Buttons whose handler does not call Router_Push still need OnAction"
            + "  (or custom ML), not SetMenuPage alone.\n"
            + "- For creating a new map with a chosen vista, prefer EditNewMap or"
            + "  CreateMapViaMenu over hand-rolled click chains.");

        _RegisterGuide("manialink-runner",
            "RunManialinkScript via MLHook",
            "RunManialinkScript injects ad-hoc ManiaScript the same way MLHook's developer"
            + " UILayers browser creates a layer: UILayerCreate + ManialinkPage assign, via"
            + " InjectManialinkToMenu / InjectManialinkToPlayground / InjectManialinkToEditor.\n"
            + "\n"
            + "Parameters:\n"
            + "- script (required): raw ManiaScript body or inner fragment. Do NOT include"
            + "  outer <manialink> tags — MLHook wraps as name=MLHook_<pageUid>.\n"
            + "- context: current (default) | menu | in-map | in-editor.\n"
            + "- pageUid default McpAdHoc; replace default true; persist default true;"
            + "  waitMs default 150.\n"
            + "- collectMs (optional): when >0, registers a result hook for resultEvent"
            + "  (default McpAdHoc_Result). From script:\n"
            + "    SendCustomEvent(\"MLHook_Event_McpAdHoc_Result\", [\"ping\", \"data\"]);\n"
            + "  Response includes results[] with type/data/dataParts (capped).\n"
            + "\n"
            + "Notes:\n"
            + "- GetManiaScriptDiagnostics reads crash prompts/debugger visibility; DismissManiaScriptDebugger hides the debugger overlay, or with visibility:'LogsFull' shows the full native log (no OS input) for a window capture. Any debugger view is a blocking screen (GetBlockingScreen kind maniascript-debugger). A game mode script that failed to load needs a fresh game process. Openplanet/plugin UI requires a window/compositor capture; see the screenshots guide.\n"
            + "- No collected event returns MANIASCRIPT_RESULT_TIMEOUT (unconfirmed); observed crash returns MANIASCRIPT_CRASH. Without collection, success confirms injection only.\n"
            + "- Manialink pages are sandboxed from each other.\n"
            + "- Bad syntax can trigger the game recovery restart — keep scripts small.\n"
            + "- Prefer this over inventing one-off MCP tools when agents need custom"
            + "  TitleControl / local-state access.");

        _RegisterGuide("map-vistas",
            "Environment / decoration (vista) selection",
            "TM map vistas are Environment + Decoration. GetMapInfo / GetMapEnvironment"
            + " report decorationName; ListMapDecorations lists every fid per env.\n"
            + "\n"
            + "Stadium — 12 vistas via EditNewMap {vista}:\n"
            + "- bases: nostadium (NoStadium48x48*), stadiumold (48x48*), stadium155\n"
            + "  (48x48Screen155*, aliases: screen155, default)\n"
            + "- moods: day, night, sunset, sunrise\n"
            + "- e.g. vista='nostadium-day', 'stadiumold-night', 'stadium155-sunset'.\n"
            + "- decoration param accepts a raw fid basename (e.g. NoStadium48x48Night).\n"
            + "- EditNewMap2 only accepts the standard '48x48Screen155Day' nod name;"
            + "  other Stadium vistas preload + SwapDecoHack into that fid slot.\n"
            + "\n"
            + "Custom environments (RedIsland, BlueBay, GreenCoast, WhiteShore):\n"
            + "- 4 decorations each: Base64x64{Day,Night,Sunrise,Sunset}.\n"
            + "- EditNewMap {environment, vista: mood} preloads the fid and passes the"
            + "  live nod IdName (Day / Night / Day64 / Sunset64 / Sunrise64 — not"
            + "  '64x64Day'). Leaving a dirty map pops AskYesNo; answer via SaveMapFlow.\n"
            + "- Verified live 2026-08-18: RedIsland Day+Night, BlueBay Day+Sunset,"
            + "  GreenCoast Day+Sunrise, WhiteShore Day+Night. All 64x64x64 / 4096 blocks.\n"
            + "\n"
            + "Custom map size: EditNewMap {vista, size:'64x64x64'} mutates the decoration's"
            + " DecoSize before creation (restored when the map closes). Also car=CarSport|"
            + "CarSnow|CarRally|CarDesert.");

        _RegisterGuide("crash-debugging",
            "Where to look when TM crashes",
            "TM writes native crashes to LogCrash_<HASH>.txt under"
            + " $PROTON_PREFIX/drive_c/users/steamuser/Documents/Trackmania/LogCrash/. The"
            + " filename hash comes from the crashing PC address, so repeat crashes at the"
            + " same site OVERWRITE the same file — copy it away immediately.\n"
            + "\n"
            + "Openplanet.log (in ~/OpenplanetNext/Openplanet.log) captures plugin-side events"
            + " but is truncated on TM restart. Copy before relaunching.\n"
            + "\n"
            + "If TM dies without writing LogCrash, wineserver force-killed it. Useful cross-"
            + "references: pgrep -af Trackmania.exe, journalctl for segfaults, dmesg.");

        _RegisterGuide("item-placement-debris",
            "Cleaning up test items / blocks",
            "RemoveRecentItems / RemoveItemsByIndex call Editor::DeleteItems (E++), which"
            + " builds a donor macroblock and RemoveMacroblock after setting"
            + " Initialized=true and Connected=true. That path is undo-safe when addUndo=true"
            + " and works even when pmt.Items / AnchorData are empty (no MLHook needed)."
            + " Prefer forceBufferFallback=false (default).\n"
            + "\n"
            + "Agent-friendly cleanup (preferred for smoke/fuzz):\n"
            + "1. SetAgentTag {tag:'run:smoke-1'} before placing\n"
            + "2. PlaceItemViaEditorPlusPlus / PlaceBlockViaEditorPlusPlus (auto-tags)\n"
            + "3. RemoveByTag {tag:'run:smoke-1'} — re-resolves by pos+idName, DeleteItems/DeleteBlocks\n"
            + "4. ClearTagIndex only drops the sidecar, not the map.\n"
            + "\n"
            + "forceBufferFallback=true is cleanup-only: AnchoredObjects.RemoveRange*"
            + " (undoSupported=false). After forceBufferFallback cleanup, save-reload is cheapest.");

        _RegisterGuide("readiness",
            "GetReadiness + WaitUntil",
            "GetReadiness {want:editor|menu|any|race} returns ready + checks"
            + " (modeOk, dialogClear, editorReadyForRequest, inventoryReady, hasChallenge)"
            + " and blockingReasons. Prefer this before mutating.\n"
            + "\n"
            + "WaitUntil {condition, timeoutMs, pollMs, ...} polls in-plugin.\n"
            + "MeasureFrameTime {frames?, warmupFrames?} yields N frames and returns"
            + " elapsedMs/msPerFrame/minMs/maxMs/fps (capFps=30). Default 10 frames;"
            + " ~333ms is the 30fps cap, ~3000ms is a hitch.\n"
            + "conditions: mode (+equals), dialogClear, editorReady, pageVisible (+page),"
            + " shadowsClear (LM bake done), calculatingShadows (+equals true|false),"
            + " mapItems/mapBlocks (+op eq|gte|lte, count), readiness (+want),"
            + " menuReached (no blocking screen, mode Menu), blockingScreen (+equals kind).\n"
            + "timeoutMs is the idle budget (default 20000). Once a loading screen"
            + " (WaitMessage / LoadProgress) is up, the clock pauses and the wait"
            + " continues until the map finishes — big maps can take many minutes"
            + " (hard cap 30 min). Timeout returns success with timedOut=true/ok=false"
            + " (not a hard tool error).\n"
            + "\n"
            + "GetMode reports MapEditor/MapEditor_Test/MapEditor_Validate/MapEditor_Playground/ItemEditor/…; equals=Editor matches any; equals=MapEditor matches MapEditor_*.\n"
            + "\n"
            + "Force an LM / shadows bake: SetMoodTimeOfDay {timeOfDay01} (change TOD — the"
            + " game refuses a second bake if shadows are already cached for that mood),"
            + " then ComputeShadows {quality?, bustCache?} (default Default / bustCache true;"
            + " does not wait), then WaitUntil {condition:shadowsClear} / GetLightmapComputeState.\n"
            + "call.py: --wait-mode Editor --until-ready editor --wait-timeout 20");

        _RegisterGuide("dialogs",
            "Game dialogs: detecting, answering, not acting behind them",
            "Every socket tool response has data.dialog: {up:false} when clear, else"
            + " {up:true, kind, blocking, frame, text?, hint}. hint names the call that answers it.\n"
            + "kind (also GetDialog.dialogKind): askYesNo (save changes? / overwrite?), saveAs,"
            + " message, wait (loading/saving; not blocking), frameDialog, menuDialog (e.g. the"
            + " map-saved card), none. GetDialog.dialog is the raw BasicDialogs enum, which says"
            + " None for AskYesNo and SaveAs: do not test it alone.\n"
            + "\n"
            + "Refused with DIALOG_BLOCKING while a blocking dialog is up (nothing done):"
            + " EditNewMap, OpenMapInEditor, PlayMap, BackToMainMenu, CreateMapViaMenu,"
            + " ControlValidation validate/requestEnterPlayground/testFromStart/testFromCoord.\n"
            + "EditNewMap / OpenMapInEditor / PlayMap leave the current map first. If that raises"
            + " the unsaved-changes prompt they stop with DIALOG_BLOCKING and output.started=false;"
            + " nothing is queued and the prompt stays up. Nothing answers it for you.\n"
            + "\n"
            + "Unsaved-changes prompt:\n"
            + "- keep the map: SaveMapFlow {name:'MyMap'} (answers yes, names, saves)\n"
            + "- discard it: SaveMapFlow {save:false} (same as RespondDialog {action:no})\n"
            + "The game then finishes returning to the menu; call your tool again.\n"
            + "Other answers: RespondDialog {action:ok} (message), {action:frame-ok} (menu modal),"
            + " WaitUntil {condition:dialogClear} (wait). Full detail: GetDialog.\n"
            + "\n"
            + "Classic menu cards (app.ActiveMenus; GetMenuFrameTree {menuIndex} lists the ids):"
            + " ClickClassicMenuControl {id} clicks one. Server join card (FrameDialogJoin):"
            + " {id:ButtonJoin}, {id:ButtonSpectator} or {id:ButtonCancel}; JoinServer {link} opens"
            + " and confirms one in a single call. frame-ok refuses a frame of several cards with no"
            + " ButtonOk (AMBIGUOUS_FRAME, nothing clicked); frame-ok/cancel report output.frameClosed.\n"
            + "\n"
            + "ControlValidation testFromStart/testFromCoord wait for the playground (waitMs,"
            + " default 10000) and fail with PLAYGROUND_NOT_STARTED if it never starts. Seen in"
            + " the stock game: one tool-driven test start per map load; reload the map to test again.\n"
            + "EditNewMap returns output.status (requested/opened); EDITNEWMAP_FAILED means no map"
            + " was requested. 'standard decoration fid holds ...' means an earlier swap was not"
            + " undone: restart the game.");

        _RegisterGuide("blocking-screens",
            "Full-page blocking screens: GetBlockingScreen + DismissBlockingScreen",
            "Two TM2020 menu screens stall menu-only agents and are invisible to GetDialog"
            + " (ManiaLink pages, not BasicDialogs): the disconnection flow"
            + " (Page_ConnectionError pop-up -> Confirm -> Page_PressStart -> 'Play offline' /"
            + " 'Retry' / 'Quit game') and the PressStart start prompt (waits for input while"
            + " online-services maintenance is planned; auto-connects otherwise).\n"
            + "\n"
            + "GetBlockingScreen reports kind start-screen|connecting|connection-failed|"
            + "connection-error|ubi-connect|welcome-back|maniascript-debugger|none, error/status text, and visible"
            + " buttons with the action each maps to. Detection is page name + control id +"
            + " EFFECTIVE visibility (button .Visible stays true under a hidden parent frame -"
            + " never trust a leaf alone). Labels are set by the page script and are reported,"
            + " not matched.\n"
            + "\n"
            + "maniascript-debugger (any mode): the native ManiaScript debugger covers the"
            + " game after a script failed. DismissBlockingScreen refuses it; preserve the error"
            + " (GetManiaScriptDiagnostics, DismissManiaScriptDebugger {visibility:'LogsFull'} + a"
            + " window capture), then DismissManiaScriptDebugger.\n"
            + "\n"
            + "DismissBlockingScreen {action} clicks the safe button via the game's own"
            + " CControlBase::OnAction dispatch (nav-zone leaf for expendable buttons):"
            + " start (button-start-click), confirm (connection-error pop-up), play-offline,"
            + " retry, later. auto takes the suggested action per kind; never clicks Quit game."
            + " waitMs waits for the screen state to change and reports after + menuReached.\n"
            + "\n"
            + "Lease loop: poll GetBlockingScreen (or GetReadiness want=menu, which now reports"
            + " 'blocking screen: <kind>' as a blocking reason); when needsAction, call"
            + " DismissBlockingScreen {action:auto}; after connection-error it lands on"
            + " PressStart again - dismiss that too (auto handles each state); then"
            + " WaitUntil {condition:menuReached}.\n"
            + "\n"
            + "Reached via normal menu tools too: SetMenuPage '/press-start' or"
            + " '/connection-error' reproduce the pages for testing (the pages Nadeo's own"
            + " disconnect detector pushes).");

        _RegisterGuide("pause-bloom",
            "Pausing the game and changing bloom for live checks",
            "For live checks on a LEASED instance. No timer, watcher or automatic restore: resume and restore explicitly.\n"
            + "GetPauseState {sampleMs?} is read-only and samples online too. Verdict comes from clientGameTime,"
            + " coreSimulationTime and coreGameTime, not from menuShown. An unreadable clock or a loading frame can"
            + " restart its sample in the same context. menuShown, locality and pausable are sampled at the end."
            + " menuShownAtStart and menuShown are booleans or \"unknown\".\n"
            + "ControlPause {action:pause|resume|toggle, holdMs?, timeoutMs?} operates only in local/solo play (ONLINE_NOT_PAUSABLE otherwise)."
            + " Loading, locality or context changes abort it; a blocking dialog stops it before Show. Success for"
            + " pause needs all three clocks unchanged and the menu observed up on every frame of a full holdMs"
            + " window (default 300). A pause request never closes a pre-existing menu. Failed Show verification"
            + " can attempt at most one cleanup Resume for the menu observed open and continuously up, after a"
            + " fresh locality/loading/playground gate. See cleanupSkipped; CLEANUP_FAILED means closure was not"
            + " verified after an attempt. In explicit Resume and failed-Show cleanup, menuShown, menuShownAfter and changed are booleans or \"unknown\"."
            + " Check for an explicit boolean before acting. Call GetPauseState after failure,"
            + " then ControlPause resume if the menu is up. With lateShowPossible, call GetPauseState again after"
            + " apparent closure; a Show can land later and there is no cancel/drain API. A replacement with no"
            + " observed menu edge or a same-address context replacement can be missed. The frame-checked budget"
            + " can overrun on a hitch. Resume uses Resume only, whoever opened the menu.\n"
            + "Freeze check: ControlPause pause, TakeScreenshot twice a few seconds apart with a fixed"
            + " ControlPlayCamera, compare, then ControlPause resume. Require a measured jumpMs entry for every"
            + " clock (clientGameTime, coreSimulationTime, coreGameTime) and check each jump is small. Missing"
            + " entries are unmeasured, not zero; no-op resume has no jumpMs."
            + " Any missing jumpMs entry fails the live check.\n\n"
            + "GetDisplaySetting / SetDisplaySetting {bloom:none|medium|high} / RestoreDisplaySetting {force?, retire?}:"
            + " persistence and deferred Apply timing are unproven (persisted:assumed). Set needs a valid port.override"
            + " marker; IDENTITY_UNKNOWN otherwise. It writes and reads back one record (bloom-restore.txt) before"
            + " a single non-yielding bloom write (wrapper or systemConfig). Same-frame read-back mismatch gives"
            + " APPLY_UNVERIFIED and keeps the record. sideEffects lists only same-frame observed fields, not proof"
            + " against window/device resets. Set refuses to overwrite a record or to write with a busy wrapper or"
            + " disagreeing readable sources.\n"
            + "Always call RestoreDisplaySetting when done. With all sources at target, it writes the prior and"
            + " reads back all sources. With all at prior, it writes nothing. Both keep the record. Other values"
            + " or a known unreadable source are a conflict; force:true overwrites the current value only within"
            + " the same identity and config. A same-value external edit is indistinguishable from the tool's write"
            + " (limitation). Before retiring, GetDisplaySetting must show the same matching pending record"
            + " and the prior on every readable source, with none known unreadable, after an in-instance map reload"
            + " or a same-prefix restart that preserves the upper dir. The default tmc stop wipe destroys the record;"
            + " it is not a confirmation step. A map reload does not prove the setting was saved or that a deferred Apply finished."
            + " If Apply is unresolved, keep the record. Otherwise call RestoreDisplaySetting {retire:true}."
            + " Only retired:true confirms retirement; no record is not confirmation. Retire rechecks identity, config"
            + " and sources, refuses if a display call is busy, never writes bloom and cannot combine with force:true."
            + " Do not retire on immediate read-back alone.\n"
            + "What the record binds to: the prefix's user/app/storage paths, profile, active display/safe config"
            + " and its tmc port marker. tmc overlays keep plugin storage in a private per-instance upper directory"
            + " that tmc stop wipes by default. The primary has no marker, so Set refuses there. Limitation: prefixes"
            + " with identical paths, profile, config and marker collide. This is a prefix-marker check, not a lease check.\n"
            + "Manual recovery (legacy or foreign records): GetDisplaySetting shows legacyRecord/restoreRecord with"
            + " the path and recorded value if readable. Verify the originating instance, keep a copy, set bloom in"
            + " Settings > Graphics if that is the right prior, then delete the file. Never copy records between instances.\n\n"
            + "UNPROVEN live (2026-11-18): Q1 programmatic pause freezes like ESC; Q2 bloom none applies"
            + " without a restart (compare paused screenshots); Q3 Apply timing, persistence and window/device"
            + " effects; Q4 local hosted play pauses. Use a plain map with no MediaTracker bloom clip.");

        _RegisterGuide("agent-cleanup",
            "Provenance tags for safe multi-step cleanup",
            "SetAgentTag sets the default tag applied to PlaceBlock/PlaceItem E++ tools"
            + " (also accept per-call input.tag). ListTagged / RemoveByTag / ClearTagIndex.\n"
            + "Matching uses idName + world position ±eps (default 0.08m), not stale indices.\n"
            + "Tags are in-memory until plugin reload; they do not survive game restart.");

        _RegisterGuide("screenshots",
            "Taking screenshots safely",
            "TakeScreenshot uses the native CHmsViewport capture queue (ScreenShotDoCapture"
            + "Jpg/Webp/Tga/Dds) — the same path as the in-game F12 screenshot, so it is the"
            + " safest capture mechanism. Capture is asynchronous: the call queues the shot,"
            + " then polls Viewport.ScreenShotFullName for a new nonempty file or changed"
            + " size/modification time compared with the pre-capture snapshot"
            + " (waitMs, default 5000; 0/noWait = fire-and-forget). On success output has"
            + " fullName (game-side path like C:/users/.../ScreenShotNN.jpg) + sizeBytes.\n"
            + "\n"
            + "Openplanet ImGui/plugin windows are excluded even with hideOverlay:false. "
            + "For plugin UI on xsm/KDE use a compositor/window capture: activate Trackmania "
            + "with xdotool, then spectacle -b -n -a -o /tmp/trackmania-ui.png. Inspect the "
            + "image for the intended plugin window; see docs/window-screenshots.md.\n\n"
            + "Files land in the USER GAME FOLDER ROOT (Documents/Trackmania), not the"
            + " ScreenShots subfolder, named ScreenShotNN.<ext>. jpg/webp numbering are"
            + " independent counters (ScreenShot52.jpg next to ScreenShot01.webp is normal).\n"
            + "The engine reuses slots 01..99. slotsFull warns when all slots for the"
            + " requested format exist; overwroteExisting identifies a detected rewrite."
            + " Archive captures yourself or choose another format; this tool never deletes them."
            + " If a same-size rewrite shares the filesystem timestamp, freshness cannot be"
            + " confirmed and the tool conservatively times out. Queuing alone is not proof."
            + " Captures may stop completing while the game loses focus; a timeout does not"
            + " prove a crash. Check focus manually or use a window capture.\n"
            + "\n"
            + "Options:\n"
            + "- format: jpg (default) | webp | tga | dds\n"
            + "- hideOverlay:true — sets Viewport.DisableOverlayRender for the capture frame"
            + "  (no HUD/Manialink overlays), then restores it. Useful for clean editor shots.\n"
            + "- forceRes:true + width/height — sets Viewport.ScreenShotForceRes/W/H for the"
            + "  capture (higher-than-window resolution), restored after. Large forced sizes"
            + "  cost VRAM/time; if the wait times out, retry without forceRes.\n"
            + "- focus:{x,y,z} — aims the editor camera at a world position (meters) for the"
            + "  shot, e.g. a placed checkpoint's pos from GetBlockLocation/GetBlocks. Pair"
            + "  with distance (camera-to-target meters, default 80 — smaller = tighter"
            + "  close-up) and optional vAngle/hAngle (degrees, default 40/30). The camera is"
            + "  restored after the capture unless restore:false. Combines the old"
            + "  SetEditorCamera + TakeScreenshot dance into one call for inspecting placed"
            + "  geometry. Editor-only (NOT_IN_EDITOR outside the map editor).\n"
            + "- call.py additionally reports detectedScreenshot.linuxPath by diffing the"
            + "  folder before/after — use that for the host-side path.\n"
            + "\n"
            + "NOT exposed on purpose (known to crash / destabilize the game when driven"
            + " programmatically — do NOT poke them via Dev tools):\n"
            + "- ScreenShot360 / ScreenShot360_Height — 360 panorama captures;\n"
            + "- ScreenShotTileX/Y — tiled supersampled captures (memory-heavy);\n"
            + "- ScreenShotUseAlpha / PixelOutput — alpha/format output switching;\n"
            + "- writing ScreenshotExt / capture settings on CGameDisplaySettingsWrapper"
            + "  mid-session ( DialogGraphicSettings_* ) — config-dialog territory.\n"
            + "\n"
            + "If the game crashes after a capture, check LogCrash_<HASH>.txt (see the"
            + " crash-debugging guide) — repeated crashes overwrite the same file.");

        _RegisterGuide("editor-camera-animation",
            "Animating the map-editor camera",
            "AnimateEditorCamera starts a smooth camera move and returns at once with an id;"
            + " it runs in the background (one at a time) while you keep calling tools."
            + " WaitEditorCamera {id} blocks until it ends (timeoutMs max 300000).\n"
            + "\n"
            + "- Fly-through: {kind:'path', keyframes:[{position:{x,y,z}, lookAt:{x,y,z}}, ...],"
            + " durationMs:8000}. Keys may instead give x,y,z (point looked at) with distance,"
            + " hAngle, vAngle in degrees; omitted fields repeat the previous key. Starts from"
            + " the current view unless fromCurrent:false.\n"
            + "- Turntable: {kind:'orbit', degrees:360, durationMs:12000} around the current"
            + " target, or center:{x,y,z}; endDistance/endVAngle spiral in or out;"
            + " untilStopped:true spins until stopped.\n"
            + "- Follow: {kind:'follow'} tracks the editor cursor while you place blocks;"
            + " follow:'point' with target{x,y,z} follows a point you move with"
            + " {action:'retarget', x,y,z}.\n"
            + "\n"
            + "Interruption is the safety rule: SetEditorCamera, ControlCamera actions,"
            + " SetEditorOrbitalTarget, a focused TakeScreenshot, a new animation, the user"
            + " moving the camera, another plugin moving it, or leaving edit mode ends the"
            + " animation as interrupted. WaitEditorCamera then returns an error"
            + " (CAMERA_ANIM_INTERRUPTED) with reason and interruptedBy, so a script learns its"
            + " shot was cut. A plain TakeScreenshot does not interrupt: screenshot mid-move"
            + " for a frame of the animation. vAngle is limited by the editor to 4.5..85.5"
            + " degrees; steeper keys are clamped with a warning.");
        _RegisterGuide("reflection",
            "Querying Openplanet Reflection type info",
            "GetTypeInfo {className:'CGameCtnChallenge'} is the default call: class"
            + " metadata (name, id/idHex, size, description, userName, fileExtension,"
            + " base, bases[]) plus members[] for this class and every ancestor.\n"
            + "\n"
            + "Each member has name, optional nameDescriptive, id, offset/offsetHex,"
            + " isField, declaredOn. isField=false when offset is 0xFFFF — typically a"
            + " method, not a data field.\n"
            + "\n"
            + "Limits of the live API (Openplanet 1.29 Reflection):\n"
            + "- MwMemberInfo has no member type name. You get offsets, not 'nat3' /"
            + "  'CGameCtnBlock@'. Static dumps (OpenplanetNext.json) have types; live"
            + "  Reflection does not.\n"
            + "- There is no 'list every class' call. Lookup is GetType(name),"
            + "  GetType(id), or TypeOf(nod).\n"
            + "\n"
            + "Other inputs:\n"
            + "- classId: integer or 0x hex (same IDs as idHex in the response).\n"
            + "- from: app | editor | challenge | cursor | pluginMap — TypeOf a live nod.\n"
            + "- member: one name (walks bases unless ownOnly).\n"
            + "- ownOnly:true — only members declared on this class.\n"
            + "- query: case-insensitive substring on name / nameDescriptive.\n"
            + "- limit: cap members[] (memberCount is the untruncated match count).");

        _RegisterGuide("fids",
            "Game files via Openplanet Fids:: (ControlFids)",
            "Trackmania files live on five FID drives, not a raw OS tree. ControlFids"
            + " wraps the documented Openplanet Fids:: API.\n"
            + "\n"
            + "Drives:\n"
            + "- game — title/game data (GameData/, Skins/, Items/ inside packs)\n"
            + "- user — Documents/Trackmania (Maps, Replays, Items, Skins, …)\n"
            + "- fake — virtual title files (file:// Titles/Trackmania/…)\n"
            + "- resource — Openplanet Resources drive\n"
            + "- programData — ProgramData/Trackmania (Cache, …)\n"
            + "\n"
            + "Paths are drive-relative with / or \\\\ (e.g. GameData/Stadium/"
            + "GameCtnDecoration). Empty path is the drive root.\n"
            + "\n"
            + "Actions:\n"
            + "- drives — roots + child counts. No path needed.\n"
            + "- get {drive, path, kind?} — file or folder metadata. kind=auto"
            + "  tries file then folder; empty path is the folder root.\n"
            + "- list {drive, path, query?, limit?, offset?, kind?} — one level"
            + "  of Trees (folders) then Leaves (files). kind=auto/omitted is"
            + "  both (not empty). Default limit 80, max 400. Each entry has"
            + "  drive + path for a follow-up get/preload/extract.\n"
            + "- preload {drive, path} — Fids::Preload. Response nod.className /"
            + "  idName; alreadyLoaded if fid.Nod was set. Does not MwRelease.\n"
            + "- updateTree {drive, path, withFiles?} — rescan disk into the fid"
            + "  tree. Refuses the entire game drive unless force:true (slow).\n"
            + "- extract {drive, path} — Fids::Extract (writes a file). Optional"
            + "  dest=relative name uses CopyToFileRelative (no .. or absolute).\n"
            + "  hookMethod defaults false. Reports extractionPath, apiSucceeded,"
            + "  outputExists, expectedBytes, actualBytes and verified. A meaningful"
            + "  byte-count mismatch or missing output returns EXTRACT_UNVERIFIED;"
            + "  unknown/text sizes warn without claiming completeness. The default"
            + "  path has produced truncated 4096-byte GBX files on Proton. An explicit"
            + "  hookMethod:true retry is a controlled alternate path, not an automatic"
            + "  fallback; verify its bytes too. updateTree:true rescans the parent.\n"
            + "- getFullPath {drive, path} — Fids::GetFullPath. For packed/"
            + "  virtual fids this is the *folder* (e.g. GameData\\\\Stadium\\\\...\\\\),"
            + "  not an extracted file. existsOnDisk describes the virtual FID; use"
            + "  extractionPath/outputExists/verified for the extraction result."
            + "  fullFileName is '<virtual>' inside a .pak.\n"
            + "- fromNod {from_ptr} — GetFidFromNod of a raw nod pointer (hex"
            + "  0x... or integer). Take ptr from preload/get includeNod"
            + "  (nod.ptr) or another tool. from=app|editor|challenge was"
            + "  removed — those nods usually have no useful fid. Unreadable/"
            + "  unaligned pointers return BAD_PTR instead of wrapping.\n"
            + "- packStatus|mountPack|unmountPack {drive:user, path} inspects preloaded user packs; mutations need Menu and confirm:true. Only bridge-owned exact mounts can be unmounted.\n"
            + "- setText {drive:user, path:Scripts/EditorPlugins/Example.Script.txt, find, replace, confirm:true} applies bounded replacements in an idle MapEditor only. Readback confirms assignment, not compilation.\n"
            + "- getText {drive, path, find?} reads CPlugFileTextScript.Text. "
            + "Use find/context/maxHits for bounded search or offset/length for a slice (maximum 65536).\n"
            + "\n"
            + "Recipes:\n"
            + "- New user item not visible: updateTree {drive:user, path:Items}.\n"
            + "- Decoration fid: get/preload {drive:game, path:"
            + "  GameData/Stadium/GameCtnDecoration/<base>.Decoration.Gbx}.\n"
            + "- Fid for a nod you already hold: fromNod {from_ptr: nod.ptr}.\n"
            + "\n"
            + "ListMapDecorations / EditNewMap already use this API for vistas;"
            + " ControlFids is the general browse/preload/extract surface.");

        _RegisterGuide("epp-tools-moved",
            "E++ tools moved to tm-mcp-pack-epp",
            "All Editor++ (E++) tools now live in the tm-mcp-pack-epp tool pack:\n"
            + "- Install/enable the tm-mcp-pack-epp plugin (depends on tm-control-mcp + Editor).\n"
            + "- Call them as tm-mcp-pack-epp.<ToolName> (e.g. tm-mcp-pack-epp.PlaceBlock).\n"
            + "- Old builtin names (PlaceBlockViaEditorPlusPlus, named-macroblock suite, tags,\n"
            + "  inventory control, ControlEditMode, ControlItemEditor, ...) return a\n"
            + "  moved_to_pack error with the pack id in hint.\n");

        _RegisterGuide("plugins",
            "Reloading plugins and finding tool names",
            "Reload a plugin: ControlPlugin {action:reload, id}. There is no ReloadPlugin tool."
            + " That includes RemoteBuild when its own reloads are stuck:"
            + " ControlPlugin {action:reload, id:RemoteBuild}. Reloading tm-control-mcp itself drops"
            + " the socket until it is back (poll the status route).\n"
            + "ControlPlugin {action:load, id} loads Plugins/<id>/ or <id>.op from disk (unloading it"
            + " first if loaded); {action:getLogs, id} tails Openplanet.log for compile errors."
            + " Disabling or unloading tm-control-mcp itself is refused.\n"
            + "\n"
            + "Tool names: the list is a socket route, not a tool: {\"route\":\"catalog\"}"
            + " (python3 tools/call.py catalog; names at data.tools[].name). Pack tools are"
            + " packId.Name (ListToolPacks). Names are case-sensitive; an unknown name answers"
            + " unknown_tool with suggestions, the closest real names.");
    }

    Json::Value@ ListGuides(Json::Value &in input) {
        _InitGuides();
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        for (uint i = 0; i < g_Guides.Length; i++) {
            Json::Value g = Json::Object();
            g["topic"] = g_Guides[i].topic;
            g["title"] = g_Guides[i].title;
            arr.Add(g);
        }
        output["guides"] = arr;
        output["note"] = "Call GetGuide {topic} to fetch the full body.";
        return MakeSuccess(output);
    }

    Json::Value@ GetGuide(Json::Value &in input) {
        _InitGuides();
        if (!input.HasKey("topic")) return MakeError("missing topic; call ListGuides to enumerate");
        string topic = string(input["topic"]);
        for (uint i = 0; i < g_Guides.Length; i++) {
            if (g_Guides[i].topic == topic) {
                Json::Value output = Json::Object();
                output["topic"] = g_Guides[i].topic;
                output["title"] = g_Guides[i].title;
                output["body"] = g_Guides[i].body;
                return MakeSuccess(output);
            }
        }
        return MakeError("unknown topic: " + topic + "; call ListGuides to enumerate");
    }
}
