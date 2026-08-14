#if DEPENDENCY_CAMERA
namespace TmMcp {
    Json::Value Mat4ToJson(const mat4 &in m) {
        Json::Value arr = Json::Array();
        arr.Add(m.xx); arr.Add(m.xy); arr.Add(m.xz); arr.Add(m.xw);
        arr.Add(m.yx); arr.Add(m.yy); arr.Add(m.yz); arr.Add(m.yw);
        arr.Add(m.zx); arr.Add(m.zy); arr.Add(m.zz); arr.Add(m.zw);
        arr.Add(m.tx); arr.Add(m.ty); arr.Add(m.tz); arr.Add(m.tw);
        return arr;
    }

    Json::Value@ GetRenderCamera(Json::Value &in input) {
        bool find = input.HasKey("find") ? bool(input["find"]) : false;
        CHmsCamera@ cached = Camera::GetCurrent();
        CHmsCamera@ cam = cached;
        if (find) {
            try { @cam = Camera::FindCurrent(); } catch { @cam = cached; }
        }
        Json::Value output = Json::Object();
        output["source"] = find ? "FindCurrent" : "GetCurrent";
        output["position"] = Vec3ToJson(Camera::GetCurrentPosition());
        output["positionSource"] = "GetCurrentPosition (last RenderEarly cache)";
        if (cam is null) {
            output["available"] = false;
            return MakeSuccess(output);
        }
        output["available"] = true;
        output["fov"] = cam.Fov;
        output["nearZ"] = cam.NearZ;
        output["farZ"] = cam.FarZ;
        try { output["vel"] = Vec3ToJson(cam.Vel); } catch {}
        try { output["projection"] = Mat4ToJson(Camera::GetProjectionMatrix()); } catch {}
        if (find && cached is null) {
            output["note"] = "FindCurrent supplied fov/clip; position/projection are last EarlyRender cache (may be identity).";
        }
        return MakeSuccess(output);
    }

    Json::Value@ ProjectWorldToScreen(Json::Value &in input) {
        if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("x, y, z required", "bad_request", false);
        }
        vec3 pos = vec3(float(input["x"]), float(input["y"]), float(input["z"]));
        Json::Value output = Json::Object();
        output["world"] = Vec3ToJson(pos);
        output["behind"] = Camera::IsBehind(pos);
        vec3 screen3 = Camera::ToScreen(pos);
        output["toScreen"] = Vec3ToJson(screen3);
        output["toScreenSpace"] = Vec2ToJson(Camera::ToScreenSpace(pos));
        output["note"] = "toScreen.z > 0 means behind the camera (same as behind=true).";
        return MakeSuccess(output);
    }

    Json::Value@ SetEditorOrbitalTarget(Json::Value &in input) {
        if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("x, y, z required", "bad_request", false);
        }
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) {
            return MakeError("SetEditorOrbitalTarget requires the map editor", "NOT_IN_EDITOR", true, "Editor");
        }
        if (editor.OrbitalCameraControl is null) {
            return MakeError("orbital camera not available", "no_orbital", true, "Editor");
        }
        vec3 pos = vec3(float(input["x"]), float(input["y"]), float(input["z"]));
        try {
            Camera::SetEditorOrbitalTarget(pos);
        } catch {
            return MakeError("SetEditorOrbitalTarget failed", "camera_error", true, "Editor");
        }
        Json::Value output = Json::Object();
        output["target"] = Vec3ToJson(pos);
        output["cameraPosition"] = Vec3ToJson(Camera::GetCurrentPosition());
        return MakeSuccess(output);
    }
}
#else
namespace TmMcp {
    Json::Value@ GetRenderCamera(Json::Value &in input) { return MissingPluginError("Camera"); }
    Json::Value@ ProjectWorldToScreen(Json::Value &in input) { return MissingPluginError("Camera"); }
    Json::Value@ SetEditorOrbitalTarget(Json::Value &in input) { return MissingPluginError("Camera"); }
}
#endif
