namespace TmMcp {
    Json::Value@ RunGizmoApplyBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("blockName") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing blockName, x, y, z");
        }

        string blockName = string(input["blockName"]);
        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);
        if (isTerrain) return MakeError("terrain models are not supported by gizmo block diagnostic");

        vec3 pos = PositionInput(input);
        uint variant = input.HasKey("variant") ? uint(input["variant"]) : 0;
        bool autofocus = input.HasKey("autofocus") ? bool(input["autofocus"]) : true;
        float autofocusDistance = InputFloatOr(input, "autofocusDistance", 60.0);

        Json::Value mapPre = MapSummary(editor);
        bool placed = false;
        string error = "";
        try {
            placed = Editor::Dev_RunGizmoApplyBlock(blockInfo, pos, variant);
        } catch {
            error = getExceptionInfo();
        }

        for (uint i = 0; i < 5; i++) yield();

        Json::Value output = Json::Object();
        output["placed"] = placed;
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["variantRequested"] = int(variant);
        output["pos"] = Vec3ToJson(pos);
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        if (error.Length > 0) output["error"] = error;
        if (editor.Challenge.Blocks.Length > 0) {
            uint recentIndex = editor.Challenge.Blocks.Length - 1;
            auto recent = BlockToJson(editor.Challenge.Blocks[recentIndex]);
            recent["index"] = int(recentIndex);
            output["recentBlock"] = recent;
        }
        output["autofocus"] = false;
        if (placed && autofocus) {
            output["autofocus"] = AutofocusCameraOn(pos, autofocusDistance);
            output["autofocusTarget"] = Vec3ToJson(pos);
            output["autofocusDistance"] = autofocusDistance;
        }
        return MakeSuccess(output);
    }
}
