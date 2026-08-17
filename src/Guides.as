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
            + "- Manialink pages are sandboxed from each other.\n"
            + "- Bad syntax can trigger the game recovery restart — keep scripts small.\n"
            + "- Prefer this over inventing one-off MCP tools when agents need custom"
            + "  TitleControl / local-state access.");

        _RegisterGuide("map-vistas",
            "Environment / decoration (vista) selection",
            "TM map vistas are the combination of Environment (always 'Stadium' for TM2020)"
            + " and Decoration. GetMapInfo/GetMapEnvironment report the current map's"
            + " decorationName.\n"
            + "\n"
            + "All 12 vistas (3 bases x 4 moods), loadable via EditNewMap {vista}:\n"
            + "- bases: nostadium (NoStadium48x48*), stadiumold (48x48*), stadium155\n"
            + "  (48x48Screen155*, aliases: screen155, default)\n"
            + "- moods: day, night, sunset, sunrise\n"
            + "- e.g. vista='nostadium-day', 'stadiumold-night', 'stadium155-sunset'.\n"
            + "- decoration param accepts a raw fid basename (e.g. NoStadium48x48Night).\n"
            + "\n"
            + "How it works: EditNewMap2 only accepts the standard '48x48Screen155Day' nod"
            + " directly; other vistas preload the chosen decoration and swap it into the"
            + " standard fid's Nod slot (tm-map-together's SwapDecoHack), restoring after.\n"
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
            + "conditions: mode (+equals), dialogClear, editorReady, pageVisible (+page),"
            + " mapItems/mapBlocks (+op eq|gte|lte, count), readiness (+want).\n"
            + "Timeout returns success with timedOut=true/ok=false (not a hard tool error).\n"
            + "\n"
            + "call.py: --wait-mode Editor --until-ready editor --wait-timeout 30");

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
            + " then polls Viewport.ScreenShotFullName until the file exists with size>0"
            + " (waitMs, default 5000; 0/noWait = fire-and-forget). On success output has"
            + " fullName (game-side path like C:/users/.../ScreenShotNN.jpg) + sizeBytes.\n"
            + "\n"
            + "Files land in the USER GAME FOLDER ROOT (Documents/Trackmania), not the"
            + " ScreenShots subfolder, named ScreenShotNN.<ext>. jpg/webp numbering are"
            + " independent counters (ScreenShot52.jpg next to ScreenShot01.webp is normal).\n"
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

        _RegisterGuide("epp-tools-moved",
            "E++ tools moved to tm-mcp-pack-epp",
            "All Editor++ (E++) tools now live in the tm-mcp-pack-epp tool pack:\n"
            + "- Install/enable the tm-mcp-pack-epp plugin (depends on tm-control-mcp + Editor).\n"
            + "- Call them as tm-mcp-pack-epp.<ToolName> (e.g. tm-mcp-pack-epp.PlaceBlock).\n"
            + "- Old builtin names (PlaceBlockViaEditorPlusPlus, named-macroblock suite, tags,\n"
            + "  inventory control, ControlEditMode, ControlItemEditor, ...) return a\n"
            + "  moved_to_pack error with the pack id in hint.\n");
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
