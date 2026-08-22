namespace TmMcp {
    // -----------------------------------------------------------------------
    // Play-mode (in-race / spectate) camera control.
    //
    // Openplanet exposes no typed handle to the playground camera, so this
    // module walks raw offsets. Every offset here is taken from a shipped
    // plugin rather than guessed:
    //
    //   tm-camera-toggle/src/Camera.as          CGameTerminal cam type + flags
    //   tm-freecam-show-cp/src/FreeCam.as       active cam control nod (0x80)
    //   tm-ghosts-plus-plus/src/GameCameraObj.as GameCamera ChosenCamera + alt
    //   tm-editor-plus-plus/codegen/Camera/GameCamera.xtoml  the struct map
    //   tm-dev-plugin/src/Next_CameraResearch.as crash-value notes
    //
    // GameCamera struct  (app + offsetof(CGameCtnApp::GameScene) + 0x10):
    //   +0x24/25/26 uint8  alt flag for cam 1/2/3 (1 = normal, 2 = alt)
    //   +0x80       nod    active CGameControlCamera
    //                      (was 0x68 before the 2023-11-21 game update)
    //   +0x17C      vec3   camera position (engine output)
    //   +0x194      uint   toggle counter for same-camera switches
    //   +0x1A8      uint   ChosenCamera (r/w; same value space as below)
    //
    // CGameTerminal  (app.CurrentPlayground.GameTerminals[0]):
    //   +0x30 uint16 alt-cam flag        (0 = alt on, 1 = off)
    //   +0x34 uint32 current cam type
    //   +0x40 uint32 cam the next user toggle will select
    //   +0x50 nod    "set camera" nod — write the wanted type to its +0x4
    //   +0x60 uint32 free-cam drivable  (0 = drivable, 1 = not)
    // The 0x30/0x50/0x60 trio is anchored on GUIPlayer (+0x10/+0x30/+0x40) so
    // a future field insertion above it moves them together.
    // -----------------------------------------------------------------------

    const uint16 O_GameCam_AltCam1     = 0x24;  // +1 => cam2, +2 => cam3
    const uint16 O_GameCam_ActiveCtrl  = 0x80;
    const uint16 O_GameCam_CameraPos   = 0x17C;
    const uint16 O_GameCam_NbToggles   = 0x194;
    const uint16 O_GameCam_ChosenCam   = 0x1A8;
    const uint16 O_App_GameSceneToCam  = 0x10;
    const uint16 O_SetCamNod_Wanted    = 0x04;

    // Camera type values. Same integer space as CGameItemModel::EnumDefaultCam,
    // which is why 0x12/0x13/0x14 stringify as _1/_2/_3 and 0x15 as Alt1.
    const uint kPlayCamFree      = 0x02;
    const uint kPlayCamDefault   = 0x05;
    const uint kPlayCamFree2     = 0x11;
    const uint kPlayCamCam1      = 0x12;
    const uint kPlayCamCam2      = 0x13;
    const uint kPlayCamCam3      = 0x14;
    const uint kPlayCamBackwards = 0x15;

    uint16 PlayCamOffset(const string &in className, const string &in memberName) {
        auto ty = Reflection::GetType(className);
        if (ty is null) return 0;
        auto mem = ty.GetMember(memberName);
        if (mem is null) return 0;
        return mem.Offset;
    }

    // CGameTerminal.GUIPlayer sits at 0x20; the camera fields follow it.
    uint16 O_GT_Base() { return PlayCamOffset("CGameTerminal", "GUIPlayer"); }
    uint16 O_GT_AltCam()   { uint16 b = O_GT_Base(); return b == 0 ? 0x30 : b + 0x10; }
    uint16 O_GT_SetCamNod() { uint16 b = O_GT_Base(); return b == 0 ? 0x50 : b + 0x30; }
    uint16 O_GT_Drivable() { uint16 b = O_GT_Base(); return b == 0 ? 0x60 : b + 0x40; }
    uint16 O_GT_CurrentCam() { uint16 b = O_GT_Base(); return b == 0 ? 0x34 : b + 0x14; }
    uint16 O_GT_NextToggleCam() { uint16 b = O_GT_Base(); return b == 0 ? 0x40 : b + 0x20; }

    string PlayCamName(uint value) {
        if (value == kPlayCamFree) return "free";
        if (value == kPlayCamDefault) return "default";
        if (value == kPlayCamFree2) return "free2";
        if (value == kPlayCamCam1) return "cam1";
        if (value == kPlayCamCam2) return "cam2";
        if (value == kPlayCamCam3) return "cam3";
        if (value == kPlayCamBackwards) return "backwards";
        if (value == 0) return "none";
        return "unknown";
    }

    // Returns 0 for an unrecognised name.
    uint PlayCamValueFromName(const string &in name) {
        if (name == "free" || name == "cam7" || name == "freecam") return kPlayCamFree;
        if (name == "free2") return kPlayCamFree2;
        if (name == "cam1") return kPlayCamCam1;
        if (name == "cam2") return kPlayCamCam2;
        if (name == "cam3") return kPlayCamCam3;
        if (name == "backwards" || name == "bw") return kPlayCamBackwards;
        if (name == "default") return kPlayCamDefault;
        return 0;
    }

    // 0x8/0x9 and >=0x1e crash the game outright (tm-dev-plugin research);
    // the intro/mediatracker values in between are useless and disorienting.
    bool PlayCamValueIsAllowed(uint value) {
        return value == kPlayCamFree
            || value == kPlayCamDefault
            || value == kPlayCamFree2
            || value == kPlayCamCam1
            || value == kPlayCamCam2
            || value == kPlayCamCam3
            || value == kPlayCamBackwards;
    }

    // The spectator controller is the other authority on the play camera. When
    // it wants free cam it re-asserts free cam every tick, which silently
    // swallows a cam-type write - the observed "stuck in free cam" failure.
    CGamePlaygroundClientScriptAPI@ GetPlaygroundClientApi() {
        auto app = GetApp();
        if (app is null || app.Network is null) return null;
        auto net = cast<CGameCtnNetwork>(app.Network);
        if (net is null) return null;
        return net.PlaygroundClientScriptAPI;
    }

    CGamePlaygroundUIConfig@ GetPlaygroundUIAll() {
        auto app = GetApp();
        if (app is null || app.PlaygroundScript is null) return null;
        auto mgr = app.PlaygroundScript.UIManager;
        if (mgr is null) return null;
        return mgr.UIAll;
    }

    // Returns -1 for an unrecognised name.
    int SpectatorCamFromName(const string &in name) {
        if (name == "replay") return 0;
        if (name == "follow") return 1;
        if (name == "free") return 2;
        return -1;
    }

    string SpectatorCamName(int v) {
        if (v == 0) return "replay";
        if (v == 1) return "follow";
        if (v == 2) return "free";
        return "unknown";
    }

    void SetSpectatorWantedCam(CGameTerminal@ gt, int wanted, Json::Value @steps) {
        auto api = GetPlaygroundClientApi();
        if (api !is null) {
            if (wanted == 0) api.SetWantedSpectatorCameraType(CGamePlaygroundClientScriptAPI::ESpectatorCameraType::Replay);
            else if (wanted == 1) api.SetWantedSpectatorCameraType(CGamePlaygroundClientScriptAPI::ESpectatorCameraType::Follow);
            else api.SetWantedSpectatorCameraType(CGamePlaygroundClientScriptAPI::ESpectatorCameraType::Free);
            steps.Add("playgroundApi.SetWantedSpectatorCameraType=" + SpectatorCamName(wanted));
        }
        if (gt !is null) {
            if (wanted == 0) gt.SpectatorWantedCameraType = ESpectatorCameraType::_SpectatorCam_Replay;
            else if (wanted == 1) gt.SpectatorWantedCameraType = ESpectatorCameraType::_SpectatorCam_Follow;
            else gt.SpectatorWantedCameraType = ESpectatorCameraType::_SpectatorCam_Free;
            steps.Add("terminal.SpectatorWantedCameraType=" + SpectatorCamName(wanted));
        }
    }

    string UISequenceName(int v) {
        if (v == 0) return "None";
        if (v == 1) return "Playing";
        if (v == 2) return "Intro";
        if (v == 3) return "Outro";
        if (v == 4) return "Podium";
        if (v == 5) return "CustomMTClip";
        if (v == 6) return "EndRound";
        if (v == 7) return "PlayersPresentation";
        if (v == 8) return "UIInteraction";
        if (v == 9) return "RollingBackgroundIntro";
        if (v == 10) return "CustomMTClip_WithUIInteraction";
        if (v == 11) return "Finish";
        return "unknown";
    }

    Json::Value PlayCamSpectatorToJson(CGameTerminal@ gt) {
        Json::Value o = Json::Object();
        if (gt !is null) {
            o["terminalWantedCameraType"] = SpectatorCamName(int(gt.SpectatorWantedCameraType));
            o["uiSequence"] = UISequenceName(int(gt.UISequence_Current));
        }
        auto api = GetPlaygroundClientApi();
        o["apiAvailable"] = api !is null;
        if (api !is null) {
            o["isSpectator"] = api.IsSpectator;
            o["isSpectatorClient"] = api.IsSpectatorClient;
        }
        auto uiAll = GetPlaygroundUIAll();
        o["uiAllAvailable"] = uiAll !is null;
        if (uiAll !is null) {
            // 4-bit field: 15 is the all-bits-set "not forced" sentinel that
            // ManiaScript writes as -1, so it is not a forced camera at all.
            int force = int(uiAll.SpectatorForceCameraType);
            o["forceCameraType"] = force;
            o["forced"] = force != 15;
            o["playerDisableFreeCam"] = uiAll.PlayerDisableFreeCam;
            o["forceSpectator"] = uiAll.ForceSpectator;
            o["uiAllUISequence"] = UISequenceName(int(uiAll.UISequence));
        }
        return o;
    }

    CGameTerminal@ GetPlayGameTerminal() {
        auto app = GetApp();
        if (app is null || app.CurrentPlayground is null) return null;
        if (app.CurrentPlayground.GameTerminals.Length == 0) return null;
        return app.CurrentPlayground.GameTerminals[0];
    }

    // The engine-side game camera struct. Null in the menu and while loading.
    CMwNod@ GetGameCameraNod() {
        auto app = GetApp();
        if (app is null || app.GameScene is null) return null;
        uint16 sceneOff = PlayCamOffset("CGameCtnApp", "GameScene");
        if (sceneOff == 0) return null;
        uint64 ptr = Dev::GetOffsetUint64(app, sceneOff + O_App_GameSceneToCam);
        if (!PlayCamPointerLooksSane(ptr)) return null;
        return Dev::GetOffsetNod(app, sceneOff + O_App_GameSceneToCam);
    }

    // Cheap guard before turning a raw qword into a nod handle: a real heap
    // pointer is 8-byte aligned, above the first page, below the canonical
    // user-space ceiling, and its vtable slot is readable.
    bool PlayCamPointerLooksSane(uint64 ptr) {
        if (ptr < 0x10000 || ptr > 0x00007FFFFFFFFFFF) return false;
        if ((ptr & 0x7) != 0) return false;
        try {
            uint64 vtable = Dev::SafeReadUInt64(ptr);
            return vtable >= 0x10000 && vtable <= 0x00007FFFFFFFFFFF;
        } catch {
            return false;
        }
    }

    // The currently active camera control, whatever kind it is.
    CGameControlCamera@ GetActiveCamControl() {
        auto gc = GetGameCameraNod();
        if (gc is null) return null;
        uint64 ptr = Dev::GetOffsetUint64(gc, O_GameCam_ActiveCtrl);
        if (!PlayCamPointerLooksSane(ptr)) return null;
        return cast<CGameControlCamera>(Dev::GetOffsetNod(gc, O_GameCam_ActiveCtrl));
    }

    // Non-null only while the free camera is actually the active camera.
    CGameControlCameraFree@ GetPlayFreeCamControl() {
        return cast<CGameControlCameraFree>(GetActiveCamControl());
    }

    string PlayCamNodClass(CMwNod@ nod) {
        if (nod is null) return "";
        try {
            auto ty = Reflection::TypeOf(nod);
            if (ty is null) return "";
            return ty.Name;
        } catch {
            return "";
        }
    }

    Json::Value PlayCamTypeToJson(uint value) {
        Json::Value o = Json::Object();
        o["value"] = int(value);
        o["hex"] = Text::Format("0x%02x", int(value));
        o["name"] = PlayCamName(value);
        return o;
    }

    Json::Value PlayCamFreeToJson(CGameControlCameraFree@ free) {
        Json::Value o = Json::Object();
        if (free is null) {
            o["available"] = false;
            o["reason"] = "the free camera is not the active camera (set_mode mode=free first)";
            return o;
        }
        o["available"] = true;
        o["position"] = Vec3ToJson(free.m_FreeVal_Loc_Translation);
        o["pitchDeg"] = Math::ToDeg(free.m_Pitch);
        o["yawDeg"] = Math::ToDeg(free.m_Yaw);
        o["rollDeg"] = Math::ToDeg(free.m_Roll);
        o["pitchRad"] = free.m_Pitch;
        o["yawRad"] = free.m_Yaw;
        o["rollRad"] = free.m_Roll;
        o["radius"] = free.m_Radius;
        o["targetPos"] = Vec3ToJson(free.m_TargetPos);
        o["targetEnabled"] = free.m_TargetIsEnabled;
        o["fov"] = free.m_Fov;
        o["nearZ"] = free.m_NearZ;
        o["farZ"] = free.m_FarZ;
        // CGameControlCamera::Pos is the engine's own output slot; reading it
        // tells a caller whether a write to `position` has been applied yet.
        uint16 posOff = PlayCamOffset("CGameControlCamera", "Pos");
        if (posOff != 0) o["enginePos"] = Vec3ToJson(Dev::GetOffsetVec3(free, posOff));
        return o;
    }

    Json::Value PlayCamStateToJson() {
        Json::Value o = Json::Object();
        o["mode"] = DetectGameModeName();

        auto gt = GetPlayGameTerminal();
        o["hasGameTerminal"] = gt !is null;
        if (gt !is null) {
            uint current = Dev::GetOffsetUint32(gt, O_GT_CurrentCam());
            o["camType"] = PlayCamTypeToJson(current);
            o["nextToggleCamType"] = PlayCamTypeToJson(Dev::GetOffsetUint32(gt, O_GT_NextToggleCam()));
            o["altCam"] = Dev::GetOffsetUint16(gt, O_GT_AltCam()) == 0x0;
            o["drivableFreeCam"] = Dev::GetOffsetUint32(gt, O_GT_Drivable()) == 0x0;
            o["spectator"] = PlayCamSpectatorToJson(gt);
        }

        auto gc = GetGameCameraNod();
        o["hasGameCamera"] = gc !is null;
        if (gc !is null) {
            Json::Value g = Json::Object();
            g["chosenCamera"] = PlayCamTypeToJson(Dev::GetOffsetUint32(gc, O_GameCam_ChosenCam));
            g["cameraPos"] = Vec3ToJson(Dev::GetOffsetVec3(gc, O_GameCam_CameraPos));
            g["nbTogglesSameCamera"] = int(Dev::GetOffsetUint32(gc, O_GameCam_NbToggles));
            Json::Value alt = Json::Object();
            alt["cam1"] = int(Dev::GetOffsetUint8(gc, O_GameCam_AltCam1));
            alt["cam2"] = int(Dev::GetOffsetUint8(gc, O_GameCam_AltCam1 + 1));
            alt["cam3"] = int(Dev::GetOffsetUint8(gc, O_GameCam_AltCam1 + 2));
            alt["note"] = "1 = normal, 2 = alt";
            g["altPerCam"] = alt;
            o["gameCamera"] = g;
        }

        auto ctrl = GetActiveCamControl();
        Json::Value a = Json::Object();
        a["available"] = ctrl !is null;
        if (ctrl !is null) {
            a["class"] = PlayCamNodClass(ctrl);
            uint16 posOff = PlayCamOffset("CGameControlCamera", "Pos");
            if (posOff != 0) a["pos"] = Vec3ToJson(Dev::GetOffsetVec3(ctrl, posOff));
        }
        o["activeControl"] = a;
        o["free"] = PlayCamFreeToJson(GetPlayFreeCamControl());

#if DEPENDENCY_CAMERA
        Json::Value r = Json::Object();
        r["position"] = Vec3ToJson(Camera::GetCurrentPosition());
        auto hms = Camera::GetCurrent();
        if (hms !is null) {
            r["fov"] = hms.Fov;
            r["nearZ"] = hms.NearZ;
            r["farZ"] = hms.FarZ;
        }
        o["render"] = r;
#endif
        return o;
    }

    // Every offset this module depends on, resolved against the running build.
    // When a game update moves something, this is the block that shows it.
    Json::Value PlayCamOffsetsToJson() {
        Json::Value o = Json::Object();
        o["CGameCtnApp.GameScene"] = int(PlayCamOffset("CGameCtnApp", "GameScene"));
        o["CGameTerminal.GUIPlayer"] = int(O_GT_Base());
        o["CGameControlCamera.Pos"] = int(PlayCamOffset("CGameControlCamera", "Pos"));
        o["CGameControlCameraFree.m_FreeVal_Loc_Translation"] =
            int(PlayCamOffset("CGameControlCameraFree", "m_FreeVal_Loc_Translation"));
        o["CGameControlCameraFree.m_TargetIsEnabled"] =
            int(PlayCamOffset("CGameControlCameraFree", "m_TargetIsEnabled"));
        Json::Value d = Json::Object();
        d["gameTerminal.altCam"] = int(O_GT_AltCam());
        d["gameTerminal.currentCam"] = int(O_GT_CurrentCam());
        d["gameTerminal.nextToggleCam"] = int(O_GT_NextToggleCam());
        d["gameTerminal.setCamNod"] = int(O_GT_SetCamNod());
        d["gameTerminal.drivableFreeCam"] = int(O_GT_Drivable());
        d["gameCamera.activeCtrl"] = int(O_GameCam_ActiveCtrl);
        d["gameCamera.cameraPos"] = int(O_GameCam_CameraPos);
        d["gameCamera.chosenCamera"] = int(O_GameCam_ChosenCam);
        o["derived"] = d;
        return o;
    }

    Json::Value@ PlayCameraGet(Json::Value &in input) {
        Json::Value output = PlayCamStateToJson();
        if (input.HasKey("raw") && bool(input["raw"])) {
            output["offsets"] = PlayCamOffsetsToJson();
        }
        if (!bool(output["hasGameTerminal"])) {
            return MakeError(
                "no playground camera: needs a map being played (Race) or an editor test run",
                "NO_PLAYGROUND", true, "Race",
                "app.CurrentPlayground is null or has no GameTerminals."
            );
        }
        return MakeSuccess(output);
    }

    // Writes both alt-cam representations and reports what it did. The
    // terminal keeps one global flag; the GameCamera struct keeps a byte per
    // camera, and the switch reads the per-camera byte, so both are needed.
    Json::Value PlayCamSetAltFlags(CGameTerminal@ gt, CMwNod@ gc, bool alt, uint camType) {
        Json::Value steps = Json::Array();
        Dev::SetOffset(gt, O_GT_AltCam(), alt ? uint16(0x0) : uint16(0x1));
        steps.Add(alt ? "terminal.altCam=on" : "terminal.altCam=off");
        if (gc !is null && camType >= kPlayCamCam1 && camType <= kPlayCamCam3) {
            uint16 off = O_GameCam_AltCam1 + uint16(camType - kPlayCamCam1);
            uint8 prev = Dev::GetOffsetUint8(gc, off);
            if (prev == 1 || prev == 2) {
                Dev::SetOffset(gc, off, alt ? uint8(0x2) : uint8(0x1));
                steps.Add("gameCamera.alt" + PlayCamName(camType) + (alt ? "=2" : "=1"));
            } else {
                steps.Add("gameCamera.alt" + PlayCamName(camType) + "=skipped(unexpected " + prev + ")");
            }
        }
        return steps;
    }

    void PlayCamAppendSteps(Json::Value @steps, Json::Value &in extra) {
        for (uint i = 0; i < extra.Length; i++) steps.Add(extra[i]);
    }

    Json::Value@ PlayCameraSetMode(Json::Value &in input) {
        auto gt = GetPlayGameTerminal();
        if (gt is null) {
            return MakeError(
                "no playground camera: needs a map being played (Race) or an editor test run",
                "NO_PLAYGROUND", true, "Race",
                "app.CurrentPlayground is null or has no GameTerminals."
            );
        }

        bool haveMode = input.HasKey("mode");
        uint camType = 0;
        if (haveMode) {
            string modeName = string(input["mode"]);
            camType = PlayCamValueFromName(modeName);
            if (camType == 0 || !PlayCamValueIsAllowed(camType)) {
                return MakeError(
                    "mode must be one of: free, free2, cam1, cam2, cam3, backwards, default",
                    "bad_request", false
                );
            }
        }

        auto gc = GetGameCameraNod();
        string mechanism = input.HasKey("mechanism") ? string(input["mechanism"]) : "terminal";
        if (mechanism != "terminal" && mechanism != "gamecam" && mechanism != "both") {
            return MakeError("mechanism must be terminal, gamecam, or both", "bad_request", false);
        }

        Json::Value before = PlayCamStateToJson();
        Json::Value steps = Json::Array();

        if (input.HasKey("alt")) {
            uint effective = haveMode ? camType : Dev::GetOffsetUint32(gt, O_GT_CurrentCam());
            PlayCamAppendSteps(steps, PlayCamSetAltFlags(gt, gc, bool(input["alt"]), effective));
        }

        // An explicit spectator camera wins; otherwise a car cam needs the
        // spectator controller told to stop wanting free cam, or it will just
        // re-assert it on the next tick and the switch will look like a no-op.
        if (input.HasKey("spectatorCamera")) {
            int wanted = SpectatorCamFromName(string(input["spectatorCamera"]));
            if (wanted < 0) {
                return MakeError("spectatorCamera must be replay, follow or free", "bad_request", false);
            }
            SetSpectatorWantedCam(gt, wanted, steps);
        } else if (haveMode) {
            if (camType == kPlayCamFree || camType == kPlayCamFree2) {
                SetSpectatorWantedCam(gt, 2, steps);
            } else {
                SetSpectatorWantedCam(gt, 1, steps);
            }
        }
        if (input.HasKey("forceCameraType")) {
            auto uiAll = GetPlaygroundUIAll();
            if (uiAll is null) {
                return MakeError(
                    "UIAll not available (needs a locally hosted playground script)",
                    "no_ui_config", true, "Race",
                    "forceCameraType goes through app.PlaygroundScript.UIManager.UIAll, which only exists when the mode script runs locally (solo/local play)."
                );
            }
            uiAll.SpectatorForceCameraType = uint(int(input["forceCameraType"]));
            steps.Add("uiAll.SpectatorForceCameraType=" + int(input["forceCameraType"]));
        }

        if (haveMode) {
            if (mechanism == "terminal" || mechanism == "both") {
                auto setCamNod = Dev::GetOffsetNod(gt, O_GT_SetCamNod());
                if (setCamNod is null) {
                    return MakeError("camera setter nod not available", "no_cam_setter", true, "Race");
                }
                Dev::SetOffset(setCamNod, O_SetCamNod_Wanted, camType);
                steps.Add("terminal.setCamNod=" + PlayCamName(camType));
            }
            if (mechanism == "gamecam" || mechanism == "both") {
                if (gc is null) {
                    return MakeError("game camera struct not available", "no_game_camera", true, "Race");
                }
                uint prev = Dev::GetOffsetUint32(gc, O_GameCam_ChosenCam);
                if (prev == 0 || prev >= 0x2E) {
                    return MakeError(
                        "game camera ChosenCamera looks wrong (" + Text::Format("0x%08x", int(prev)) + "); refusing to write",
                        "offset_sanity", false, "",
                        "The 0x1A8 offset may have moved in this game build; use mechanism=terminal."
                    );
                }
                Dev::SetOffset(gc, O_GameCam_ChosenCam, camType);
                steps.Add("gameCamera.chosenCamera=" + PlayCamName(camType));
            }
        }

        // Applied after the switch on purpose: switching camera clears this flag,
        // so writing it first (as the alt flag must be) would be undone.
        if (input.HasKey("drivable")) {
            bool drivable = bool(input["drivable"]);
            Dev::SetOffset(gt, O_GT_Drivable(), drivable ? uint(0x0) : uint(0x1));
            steps.Add(drivable ? "terminal.drivableFreeCam=on" : "terminal.drivableFreeCam=off");
        }

        PlayCamSettle(input);

        Json::Value output = Json::Object();
        output["action"] = "set_mode";
        output["mechanism"] = mechanism;
        output["requested"] = haveMode ? PlayCamTypeToJson(camType) : Json::Value();
        output["steps"] = steps;
        output["before"] = before;
        Json::Value after = PlayCamStateToJson();
        output["after"] = after;
        if (haveMode) {
            uint got = uint(int(after["camType"]["value"]));
            bool switched = got == camType;
            output["switched"] = switched;
            if (!switched) {
                // The engine consumes the request on a playground tick. Outside
                // the Playing sequence, or with a menu over the view, it never
                // reads it and the write is silently dropped.
                string seq = "unknown";
                if (after.HasKey("spectator") && after["spectator"].HasKey("uiSequence")) {
                    seq = string(after["spectator"]["uiSequence"]);
                }
                output["warning"] = "camera stayed on " + PlayCamName(got) + " (wanted "
                    + PlayCamName(camType) + "). The engine only consumes the request on a live"
                    + " playground tick; uiSequence=" + seq + ". Retry with the game focused, no"
                    + " menu over the view, and the round in the Playing sequence.";
            }
        }
        return MakeSuccess(output);
    }

    void PlayCamSettle(Json::Value &in input) {
        int frames = input.HasKey("settleFrames") ? int(input["settleFrames"]) : 2;
        if (frames < 0) frames = 0;
        if (frames > 30) frames = 30;
        for (int i = 0; i < frames; i++) yield();
    }

    bool PlayCamHasVec3(Json::Value &in obj) {
        if (obj is null || obj.GetType() != Json::Type::Object) return false;
        return obj.HasKey("x") && obj.HasKey("y") && obj.HasKey("z");
    }

    vec3 PlayCamReadVec3(Json::Value &in obj) {
        return vec3(float(obj["x"]), float(obj["y"]), float(obj["z"]));
    }

    Json::Value@ PlayCameraSetPosition(Json::Value &in input) {
        auto gt = GetPlayGameTerminal();
        if (gt is null) {
            return MakeError(
                "no playground camera: needs a map being played (Race) or an editor test run",
                "NO_PLAYGROUND", true, "Race",
                "app.CurrentPlayground is null or has no GameTerminals."
            );
        }

        bool havePos = input.HasKey("x") || input.HasKey("y") || input.HasKey("z");
        if (havePos && !(input.HasKey("x") && input.HasKey("y") && input.HasKey("z"))) {
            return MakeError("x, y and z must be given together", "bad_request", false);
        }
        bool radians = input.HasKey("radians") ? bool(input["radians"]) : false;
        bool haveTarget = input.HasKey("target") && PlayCamHasVec3(input["target"]);
        if (input.HasKey("target") && !haveTarget) {
            return MakeError("target must be an object with x, y and z", "bad_request", false);
        }

        Json::Value before = PlayCamStateToJson();
        Json::Value steps = Json::Array();

        bool ensureFreeCam = input.HasKey("ensureFreeCam") ? bool(input["ensureFreeCam"]) : true;
        auto free = GetPlayFreeCamControl();
        if (free is null && ensureFreeCam) {
            auto setCamNod = Dev::GetOffsetNod(gt, O_GT_SetCamNod());
            if (setCamNod is null) {
                return MakeError("camera setter nod not available", "no_cam_setter", true, "Race");
            }
            Dev::SetOffset(setCamNod, O_SetCamNod_Wanted, kPlayCamFree);
            steps.Add("terminal.setCamNod=free (ensureFreeCam)");
            for (int i = 0; i < 4 && free is null; i++) {
                yield();
                @free = GetPlayFreeCamControl();
            }
        }
        if (free is null) {
            return MakeError(
                "free camera is not active",
                "NOT_FREE_CAM", true, "Race",
                "Call action=set_mode mode=free first, or leave ensureFreeCam=true (default)."
            );
        }

        // Two ways to drive this camera, and they are mutually exclusive:
        //
        //  * free:    m_FreeVal_Loc_Translation is the camera position and the
        //             engine keeps whatever orientation it last built. Writing
        //             m_Pitch/m_Yaw/m_Roll here is inert - the free camera only
        //             rebuilds its matrix while the player moves the mouse.
        //  * orbital: with m_TargetIsEnabled the camera is placed on a sphere
        //             around m_TargetPos and always looks at it, exactly as the
        //             editor orbital camera does (see CameraMaths.md):
        //                 pos = target - radius * (cos v * sin h, -sin v, cos v * cos h)
        //             where h = m_Yaw and v = m_Pitch. Verified against
        //             ProjectWorldToScreen: the target lands on screen centre.
        //
        // So a caller asking for a position *and* a look-at target gets the
        // orbital form with the angles and radius solved backwards from the two
        // points, which puts the camera exactly where it asked and aims it.
        bool lookAt = havePos && haveTarget;
        if (lookAt) {
            if (input.HasKey("radius") || input.HasKey("pitch") || input.HasKey("yaw")) {
                return MakeError(
                    "radius, pitch and yaw are derived when x,y,z and target are both given",
                    "bad_request", false, "",
                    "Give x,y,z + target for a look-at, or target + radius/pitch/yaw for a raw orbit."
                );
            }
            vec3 pos = vec3(float(input["x"]), float(input["y"]), float(input["z"]));
            vec3 tgt = PlayCamReadVec3(input["target"]);
            vec3 delta = tgt - pos;
            float radius = delta.Length();
            if (radius < 0.001) {
                return MakeError("target must not coincide with the camera position", "bad_request", false);
            }
            vec2 hv = LookDirToOrbitalAngles(delta);
            free.m_TargetPos = tgt;
            free.m_Radius = radius;
            free.m_Yaw = hv.x;
            free.m_Pitch = hv.y;
            free.m_Roll = 0.0;
            free.m_TargetIsEnabled = true;
            // Keep the free-position field coherent with where the camera lands.
            free.m_FreeVal_Loc_Translation = pos;
            steps.Add("lookAt: radius=" + Text::Format("%.3f", radius)
                + " yawDeg=" + Text::Format("%.3f", Math::ToDeg(hv.x))
                + " pitchDeg=" + Text::Format("%.3f", Math::ToDeg(hv.y)));
        } else if (havePos) {
            vec3 pos = vec3(float(input["x"]), float(input["y"]), float(input["z"]));
            // A live target pins the camera to its orbit and would swallow the
            // position write, so release it unless the caller asked for one.
            if (free.m_TargetIsEnabled) {
                free.m_TargetIsEnabled = false;
                steps.Add("free.m_TargetIsEnabled=false (auto: a live target would override the position)");
            }
            free.m_FreeVal_Loc_Translation = pos;
            steps.Add("free.m_FreeVal_Loc_Translation");
        }
        if (!lookAt && input.HasKey("pitch")) {
            float v = float(input["pitch"]);
            free.m_Pitch = radians ? v : Math::ToRad(v);
            steps.Add("free.m_Pitch");
        }
        if (!lookAt && input.HasKey("yaw")) {
            float v = float(input["yaw"]);
            free.m_Yaw = radians ? v : Math::ToRad(v);
            steps.Add("free.m_Yaw");
        }
        if (!lookAt && input.HasKey("roll")) {
            float v = float(input["roll"]);
            free.m_Roll = radians ? v : Math::ToRad(v);
            steps.Add("free.m_Roll");
        }
        if (!lookAt && haveTarget) {
            free.m_TargetPos = PlayCamReadVec3(input["target"]);
            free.m_TargetIsEnabled = true;
            steps.Add("free.m_TargetPos + m_TargetIsEnabled=true");
        }
        if (input.HasKey("clearTarget") && bool(input["clearTarget"])) {
            free.m_TargetIsEnabled = false;
            steps.Add("free.m_TargetIsEnabled=false");
        }
        if (!lookAt && input.HasKey("radius")) {
            free.m_Radius = float(input["radius"]);
            steps.Add("free.m_Radius");
        }
        if (input.HasKey("fov")) {
            free.m_Fov = float(input["fov"]);
            steps.Add("free.m_Fov");
        }

        PlayCamSettle(input);

        Json::Value output = Json::Object();
        output["action"] = "set_position";
        output["steps"] = steps;
        output["before"] = before;
        output["after"] = PlayCamStateToJson();
        return MakeSuccess(output);
    }

    Json::Value@ ControlPlayCamera(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "get";
        if (action == "get" || action == "status") return PlayCameraGet(input);
        if (action == "set_mode") return PlayCameraSetMode(input);
        if (action == "set_position") return PlayCameraSetPosition(input);
        return MakeError("action must be one of: get, set_mode, set_position", "bad_request", false);
    }
}
