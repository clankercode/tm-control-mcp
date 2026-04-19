namespace TmMcp {
    class PreflightStats {
        bool hasAny = false;
        vec3 minPos;
        vec3 maxPos;

        void AddPos(const vec3 &in pos) {
            if (!hasAny) {
                minPos = pos;
                maxPos = pos;
                hasAny = true;
                return;
            }
            minPos.x = Math::Min(minPos.x, pos.x);
            minPos.y = Math::Min(minPos.y, pos.y);
            minPos.z = Math::Min(minPos.z, pos.z);
            maxPos.x = Math::Max(maxPos.x, pos.x);
            maxPos.y = Math::Max(maxPos.y, pos.y);
            maxPos.z = Math::Max(maxPos.z, pos.z);
        }
    }

    bool WorldPosInsideMap(const vec3 &in pos, const nat3 &in size) {
        return pos.x >= 0.0 && pos.x <= float(size.x) * 32.0
            && pos.y >= -64.0 && pos.y <= (float(size.y) - 8.0) * 8.0
            && pos.z >= 0.0 && pos.z <= float(size.z) * 32.0;
    }

    Json::Value PreflightIssue(const string &in kind, int index, const string &in message) {
        Json::Value output = Json::Object();
        output["kind"] = kind;
        output["index"] = index;
        output["message"] = message;
        return output;
    }

    uint VariantCount(Editor::BlockSpec@ block) {
        if (block is null || block.BlockInfo is null) return 0;
        return block.isGround
            ? uint(block.BlockInfo.AdditionalVariantsGround.Length) + 1
            : uint(block.BlockInfo.AdditionalVariantsAir.Length) + 1;
    }

    Json::Value PreflightStatsToJson(PreflightStats@ stats) {
        Json::Value output = Json::Object();
        output["hasAny"] = stats.hasAny;
        if (stats.hasAny) {
            output["min"] = Vec3ToJson(stats.minPos);
            output["max"] = Vec3ToJson(stats.maxPos);
        }
        return output;
    }

    Json::Value@ PreflightNamedMacroblockPlacement(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("name")) return MakeError("missing name");

        string name = string(input["name"]);
        auto mb = GetNamedMacroblock(name);
        if (mb is null) return MakeError("named macroblock not found: " + name);

        int limit = input.HasKey("limit") ? int(input["limit"]) : 50;
        if (limit < 1) limit = 1;
        if (limit > 250) limit = 250;

        Editor::MacroblockSpec@ checkMb = mb;
        vec3 offset = OptionalOffsetInput(input);
        vec3 rotation = RotationInput(input);
        vec3 pivot = PivotInput(input);
        if (HasTransformInput(input)) {
            @checkMb = DuplicateAndTransformMacroblock(mb, offset, rotation, pivot);
        }

        Json::Value issues = Json::Array();
        PreflightStats blockStats;
        PreflightStats itemStats;
        uint invalidVariants = 0;
        uint missingModels = 0;
        uint outOfBounds = 0;
        auto size = editor.Challenge.Size;

        for (uint i = 0; i < checkMb.blocks.Length; i++) {
            auto block = checkMb.blocks[i];
            vec3 worldPos = block.pos - MacroblockInternalOffset();
            blockStats.AddPos(worldPos);
            if (!WorldPosInsideMap(worldPos, size)) {
                outOfBounds++;
                if (issues.Length < uint(limit)) issues.Add(PreflightIssue("blockOutOfBounds", int(i), block.name));
            }
            if (block.BlockInfo is null) {
                missingModels++;
                if (issues.Length < uint(limit)) issues.Add(PreflightIssue("blockMissingModel", int(i), block.name));
                continue;
            }
            uint nbVariants = VariantCount(block);
            if (int(block.variant) < 0 || block.variant >= nbVariants) {
                invalidVariants++;
                if (issues.Length < uint(limit)) {
                    issues.Add(PreflightIssue(
                        "blockInvalidVariant",
                        int(i),
                        block.name + " variant=" + block.variant + " validCount=" + nbVariants
                    ));
                }
            }
        }

        for (uint i = 0; i < checkMb.items.Length; i++) {
            auto item = checkMb.items[i];
            vec3 worldPos = item.pos - MacroblockInternalOffset();
            itemStats.AddPos(worldPos);
            if (!WorldPosInsideMap(worldPos, size)) {
                outOfBounds++;
                if (issues.Length < uint(limit)) issues.Add(PreflightIssue("itemOutOfBounds", int(i), item.name));
            }
            if (item.Model is null) {
                missingModels++;
                if (issues.Length < uint(limit)) issues.Add(PreflightIssue("itemMissingModel", int(i), item.name));
            }
        }

        Json::Value output = NamedMacroblockSummary(name, mb);
        output["ok"] = invalidVariants == 0 && missingModels == 0 && outOfBounds == 0;
        output["invalidVariants"] = int(invalidVariants);
        output["missingModels"] = int(missingModels);
        output["outOfBounds"] = int(outOfBounds);
        output["issues"] = issues;
        output["issueLimit"] = limit;
        output["issuesTruncated"] = invalidVariants + missingModels + outOfBounds > uint(issues.Length);
        output["blockExtents"] = PreflightStatsToJson(blockStats);
        output["itemExtents"] = PreflightStatsToJson(itemStats);
        output["offset"] = Vec3ToJson(offset);
        output["rot"] = Vec3ToJson(rotation);
        output["rotDeg"] = Vec3DegToJson(rotation);
        output["pivot"] = Vec3ToJson(pivot);
        output["map"] = MapSummary(editor);
        return MakeSuccess(output);
    }
}
