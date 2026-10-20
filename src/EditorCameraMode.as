namespace TmMcp {
    string EditorCameraBlockReason(const string &in mode) {
        if (mode == "MapEditor") return "";
        if (mode == "MapEditor_Test") return "Map editor is in test mode; return to edit mode before changing the editor camera.";
        if (mode == "MapEditor_Validate") return "Map editor is in validation mode; return to edit mode before changing the editor camera.";
        if (mode == "MapEditor_Playground") return "Map editor is in playground mode; return to edit mode before changing the editor camera.";
        return "The active map editor camera is unavailable in this mode.";
    }

    string EditorCameraMode(CGameCtnEditorFree@ editor) {
        string mode = DetectGameModeName();
        if (mode == "MapEditor" && GetApp().CurrentPlayground !is null) return "MapEditor_Playground";
        return mode;
    }

    void AddEditorCameraContext(Json::Value &inout output, CGameCtnEditorFree@ editor) {
        string mode = EditorCameraMode(editor);
        output["mode"] = mode;
        output["isTesting"] = mode == "MapEditor_Test";
        output["isValidating"] = mode == "MapEditor_Validate";
        output["isActive"] = EditorCameraBlockReason(mode).Length == 0;
        output["cameraSource"] = "editor orbital camera";
        if (!bool(output["isActive"]))
            output["note"] = "Stored editor camera, not the active rendered view. " + EditorCameraBlockReason(mode);
    }

    Json::Value@ EditorCameraModeError(CGameCtnEditorFree@ editor) {
        string mode = EditorCameraMode(editor);
        string reason = EditorCameraBlockReason(mode);
        if (reason.Length == 0) return null;
        auto result = MakeError(reason, "EDITOR_CAMERA_INACTIVE", false, "MapEditor",
            "Use ControlValidation requestLeavePlayground to return to edit mode, or GetRenderCamera/ControlPlayCamera for the active play camera.");
        result["actualMode"] = mode;
        result["isTesting"] = mode == "MapEditor_Test";
        result["mutated"] = false;
        return result;
    }
}
