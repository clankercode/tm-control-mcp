#if DEPENDENCY_VEHICLESTATE
namespace TmMcp {
    string VehicleTypeName(VehicleState::VehicleType ty) {
        if (ty == VehicleState::VehicleType::CharacterPilot) return "CharacterPilot";
        if (ty == VehicleState::VehicleType::CarSport) return "CarSport";
        if (ty == VehicleState::VehicleType::CarSnow) return "CarSnow";
        if (ty == VehicleState::VehicleType::CarRally) return "CarRally";
        if (ty == VehicleState::VehicleType::CarDesert) return "CarDesert";
        return "unknown";
    }

    string TurboLevelName(VehicleState::TurboLevel lv) {
        if (lv == VehicleState::TurboLevel::None) return "None";
        if (lv == VehicleState::TurboLevel::Normal) return "Normal";
        if (lv == VehicleState::TurboLevel::Super) return "Super";
        if (lv == VehicleState::TurboLevel::RouletteNormal) return "RouletteNormal";
        if (lv == VehicleState::TurboLevel::RouletteSuper) return "RouletteSuper";
        if (lv == VehicleState::TurboLevel::RouletteUltra) return "RouletteUltra";
        return "unknown";
    }

    string FallingStateName(VehicleState::FallingState st) {
        if (st == VehicleState::FallingState::FallingAir) return "FallingAir";
        if (st == VehicleState::FallingState::FallingWater) return "FallingWater";
        if (st == VehicleState::FallingState::RestingGround) return "RestingGround";
        if (st == VehicleState::FallingState::RestingWater) return "RestingWater";
        if (st == VehicleState::FallingState::GlidingGround) return "GlidingGround";
        return "unknown";
    }

    Json::Value WheelStateToJson(CSceneVehicleVisState@ vis, int w) {
        Json::Value o = Json::Object();
        o["index"] = w;
        o["dirt"] = VehicleState::GetWheelDirt(vis, w);
        o["falling"] = FallingStateName(VehicleState::GetWheelFalling(vis, w));
        return o;
    }

    Json::Value VisStateToJson(CSceneVehicleVisState@ vis) {
        Json::Value o = Json::Object();
        if (vis is null) {
            o["available"] = false;
            return o;
        }
        o["available"] = true;
        o["position"] = Vec3ToJson(vis.Position);
        o["dir"] = Vec3ToJson(vis.Dir);
        o["left"] = Vec3ToJson(vis.Left);
        o["up"] = Vec3ToJson(vis.Up);
        o["frontSpeed"] = vis.FrontSpeed;
        o["worldVel"] = Vec3ToJson(vis.WorldVel);
        o["rpm"] = VehicleState::GetRPM(vis);
        o["sideSpeed"] = VehicleState::GetSideSpeed(vis);
        o["curGear"] = int(vis.CurGear);
        o["inputSteer"] = vis.InputSteer;
        o["inputGasPedal"] = vis.InputGasPedal;
        o["inputBrakePedal"] = vis.InputBrakePedal;
        o["inputIsBraking"] = vis.InputIsBraking;
        o["wetness01"] = vis.WetnessValue01;
        o["reactorFinalTimer"] = VehicleState::GetReactorFinalTimer(vis);
        o["cruiseDisplaySpeed"] = VehicleState::GetCruiseDisplaySpeed(vis);
        o["lastTurboLevel"] = TurboLevelName(VehicleState::GetLastTurboLevel(vis));
        o["vehicleType"] = VehicleTypeName(VehicleState::GetVehicleType(vis));
        o["fl"] = Json::Object();
        o["fl"]["steerAngle"] = vis.FLSteerAngle;
        o["fl"]["slipCoef"] = vis.FLSlipCoef;
        o["fl"]["wheelRot"] = vis.FLWheelRot;
        o["fl"]["tireWear01"] = vis.FLTireWear01;
        o["fl"]["icing01"] = vis.FLIcing01;
        o["fl"]["brakeNormed"] = vis.FLBreakNormedCoef;
        o["fr"] = Json::Object();
        o["fr"]["steerAngle"] = vis.FRSteerAngle;
        o["fr"]["slipCoef"] = vis.FRSlipCoef;
        o["fr"]["wheelRot"] = vis.FRWheelRot;
        o["fr"]["tireWear01"] = vis.FRTireWear01;
        o["fr"]["icing01"] = vis.FRIcing01;
        o["fr"]["brakeNormed"] = vis.FRBreakNormedCoef;
        o["rl"] = Json::Object();
        o["rl"]["steerAngle"] = vis.RLSteerAngle;
        o["rl"]["slipCoef"] = vis.RLSlipCoef;
        o["rl"]["wheelRot"] = vis.RLWheelRot;
        o["rl"]["tireWear01"] = vis.RLTireWear01;
        o["rl"]["icing01"] = vis.RLIcing01;
        o["rl"]["brakeNormed"] = vis.RLBreakNormedCoef;
        o["rr"] = Json::Object();
        o["rr"]["steerAngle"] = vis.RRSteerAngle;
        o["rr"]["slipCoef"] = vis.RRSlipCoef;
        o["rr"]["wheelRot"] = vis.RRWheelRot;
        o["rr"]["tireWear01"] = vis.RRTireWear01;
        o["rr"]["icing01"] = vis.RRIcing01;
        o["rr"]["brakeNormed"] = vis.RRBreakNormedCoef;
        Json::Value wheels = Json::Array();
        for (int w = 0; w < 4; w++) wheels.Add(WheelStateToJson(vis, w));
        o["wheels"] = wheels;
        return o;
    }

    ISceneVis@ GameSceneVis() {
        auto app = GetApp();
        if (app is null) return null;
        return app.GameScene;
    }

    Json::Value@ GetVehicleState(Json::Value &in input) {
        Json::Value output = Json::Object();
        auto player = VehicleState::GetViewingPlayer();
        if (player is null) {
            output["viewingPlayer"] = Json::Value();
        } else {
            Json::Value p = Json::Object();
            if (player.User !is null) {
                p["name"] = string(player.User.Name);
                p["login"] = string(player.User.Login);
            }
            output["viewingPlayer"] = p;
        }
        auto vis = VehicleState::ViewingPlayerState();
        output["state"] = VisStateToJson(vis);
        output["note"] = "ViewingPlayerState can be valid even when GetViewingPlayer is null.";
        if (vis is null) {
            return MakeError("no viewing vehicle state (need Race/playground or replay)", "no_vehicle", true, "Race", "Use ListVehicleVis if cars exist but none is viewed");
        }
        return MakeSuccess(output);
    }

    Json::Value@ ListVehicleVis(Json::Value &in input) {
        auto scene = GameSceneVis();
        if (scene is null) return MakeError("GameScene not available", "no_scene", true, "Race");
        int limit = input.HasKey("limit") ? Math::Clamp(int(input["limit"]), 1, 128) : 32;
        auto all = VehicleState::GetAllVis(scene);
        Json::Value output = Json::Object();
        Json::Value arr = Json::Array();
        uint n = all.Length;
        output["count"] = int(n);
        for (uint i = 0; i < n && int(arr.Length) < limit; i++) {
            auto vis = all[i];
            Json::Value row = Json::Object();
            if (vis is null) {
                row["null"] = true;
            } else {
                row["entityId"] = int(Dev::GetOffsetUint32(vis, 0));
                row["state"] = VisStateToJson(vis.AsyncState);
            }
            arr.Add(row);
        }
        output["vehicles"] = arr;
        return MakeSuccess(output);
    }

    CSmPlayer@ FindPlaygroundPlayer(Json::Value &in input) {
        auto cp = GetApp().CurrentPlayground;
        if (cp is null) return null;
        string wantName = input.HasKey("name") ? string(input["name"]) : "";
        string wantLogin = input.HasKey("login") ? string(input["login"]) : "";
        if (wantName.Length == 0 && wantLogin.Length == 0) return null;
        for (uint i = 0; i < cp.Players.Length; i++) {
            auto player = cast<CSmPlayer>(cp.Players[i]);
            if (player is null || player.User is null) continue;
            if (wantLogin.Length > 0 && string(player.User.Login) == wantLogin) return player;
            if (wantName.Length > 0 && string(player.User.Name) == wantName) return player;
        }
        return null;
    }

    Json::Value@ GetVehicleVis(Json::Value &in input) {
        auto scene = GameSceneVis();
        if (scene is null) return MakeError("GameScene not available", "no_scene", true, "Race");
        CSceneVehicleVis@ vis = null;
        string source = "singular";
        if (input.HasKey("name") || input.HasKey("login")) {
            source = "fromPlayer";
            auto player = FindPlaygroundPlayer(input);
            if (player is null) {
                return MakeError("player not found in CurrentPlayground", "not_found", true, "Race", "Pass name or login from GetPlayers");
            }
            @vis = VehicleState::GetVis(scene, player);
        } else if (input.HasKey("entityId")) {
            source = "fromId";
            @vis = VehicleState::GetVisFromId(scene, uint(int(input["entityId"])));
        } else {
            @vis = VehicleState::GetSingularVis(scene);
        }
        if (vis is null) {
            return MakeError("vehicle vis not found", "not_found", true, "Race", "Pass name/login, entityId from ListVehicleVis, or use GetVehicleState for the viewed car");
        }
        Json::Value output = Json::Object();
        output["source"] = source;
        output["entityId"] = int(Dev::GetOffsetUint32(vis, 0));
        output["state"] = VisStateToJson(vis.AsyncState);
        return MakeSuccess(output);
    }
}
#else
namespace TmMcp {
    Json::Value@ GetVehicleState(Json::Value &in input) { return MissingPluginError("VehicleState"); }
    Json::Value@ ListVehicleVis(Json::Value &in input) { return MissingPluginError("VehicleState"); }
    Json::Value@ GetVehicleVis(Json::Value &in input) { return MissingPluginError("VehicleState"); }
}
#endif
