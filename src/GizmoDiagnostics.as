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

    vec3 Vec3FromJsonArray(Json::Value@ arr) {
        return vec3(float(arr[0]), float(arr[1]), float(arr[2]));
    }

    Json::Value@ RunRandomFuzz(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("bboxMin") || !input.HasKey("bboxMax") || !input.HasKey("iterations")) {
            return MakeError("missing bboxMin, bboxMax, or iterations");
        }
        vec3 bbMin = Vec3FromJsonArray(input["bboxMin"]);
        vec3 bbMax = Vec3FromJsonArray(input["bboxMax"]);
        uint iterations = uint(int(input["iterations"]));
        float blockRatio = input.HasKey("blockRatio") ? float(input["blockRatio"]) : 0.6;
        if (iterations == 0) return MakeError("iterations must be >= 1");
        if (iterations > 2000) return MakeError("iterations capped at 2000; pick a smaller N");

        Json::Value mapPre = MapSummary(editor);
        string error = "";
        uint totalPlaced = 0;
        try {
            totalPlaced = Editor::Dev_RunRandomFuzz(bbMin, bbMax, iterations, blockRatio);
        } catch {
            error = getExceptionInfo();
        }

        Json::Value output = Json::Object();
        output["bboxMin"] = Vec3ToJson(bbMin);
        output["bboxMax"] = Vec3ToJson(bbMax);
        output["iterations"] = int(Editor::Dev_RandomFuzz_GetIterations());
        output["blockRatio"] = blockRatio;
        output["collection"] = Editor::Dev_RandomFuzz_GetCollection();
        output["attemptedBlock"] = int(Editor::Dev_RandomFuzz_GetAttemptedBlock());
        output["attemptedItem"] = int(Editor::Dev_RandomFuzz_GetAttemptedItem());
        output["placedBlock"] = int(Editor::Dev_RandomFuzz_GetPlacedBlock());
        output["placedItem"] = int(Editor::Dev_RandomFuzz_GetPlacedItem());
        output["placedTotal"] = int(totalPlaced);
        output["skippedNoInventory"] = int(Editor::Dev_RandomFuzz_GetSkippedNoInv());
        output["skippedBadModel"] = int(Editor::Dev_RandomFuzz_GetSkippedBadModel());
        output["skippedVariant"] = int(Editor::Dev_RandomFuzz_GetSkippedVariant());
        output["exceptions"] = int(Editor::Dev_RandomFuzz_GetExceptions());
        string firstEx = Editor::Dev_RandomFuzz_GetFirstException();
        if (firstEx.Length > 0) output["firstException"] = firstEx;
        Json::Value mapDelta = Json::Object();
        mapDelta["blocksBefore"] = int(Editor::Dev_RandomFuzz_GetBlocksBefore());
        mapDelta["blocksAfter"] = int(Editor::Dev_RandomFuzz_GetBlocksAfter());
        mapDelta["itemsBefore"] = int(Editor::Dev_RandomFuzz_GetItemsBefore());
        mapDelta["itemsAfter"] = int(Editor::Dev_RandomFuzz_GetItemsAfter());
        output["mapDelta"] = mapDelta;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        if (error.Length > 0) output["error"] = error;
        return MakeSuccess(output);
    }
}
