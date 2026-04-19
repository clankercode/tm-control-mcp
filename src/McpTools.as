namespace Editor {
    import vec3 GetBlockLocation(CGameCtnBlock@ block, bool forceFree = false) from "Editor";
    import vec3 GetBlockRotation(CGameCtnBlock@ block) from "Editor";
    import bool IsBlockFree(CGameCtnBlock@ block) from "Editor";
    // GetNodPointer is provided by Editor's Exports/Functions.as, no need to re-import.
}

namespace TmMcp {
    array<string> g_NamedMacroblockNames;
    array<Editor::MacroblockSpec@> g_NamedMacroblocks;
    array<NamedMacroblockSkin@[]@> g_NamedMacroblockSkins;

    CGameCtnEditorFree@ GetEditor() {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.Editor is null) return null;
        return cast<CGameCtnEditorFree>(app.Editor);
    }

    Json::Value@ MakeSuccess(Json::Value &in output) {
        Json::Value result = Json::Object();
        result["success"] = true;
        result["output"] = output;
        return result;
    }

    Json::Value@ MakeError(const string &in err) {
        Json::Value result = Json::Object();
        result["success"] = false;
        result["error"] = err;
        return result;
    }

    Json::Value CoordToJson(const nat3 &in coord) {
        Json::Value arr = Json::Array();
        arr.Add(coord.x);
        arr.Add(coord.y);
        arr.Add(coord.z);
        return arr;
    }

    Json::Value Int3ToJson(const int3 &in coord) {
        Json::Value arr = Json::Array();
        arr.Add(coord.x);
        arr.Add(coord.y);
        arr.Add(coord.z);
        return arr;
    }

    Json::Value Vec3ToJson(const vec3 &in pos) {
        Json::Value arr = Json::Array();
        arr.Add(pos.x);
        arr.Add(pos.y);
        arr.Add(pos.z);
        return arr;
    }

    Json::Value MapBoundsToJson(const nat3 &in size) {
        Json::Value output = Json::Object();
        Json::Value coord = Json::Object();
        coord["min"] = CoordToJson(nat3(0, 0, 0));
        coord["maxInclusive"] = CoordToJson(size - nat3(1, 1, 1));
        coord["maxExclusive"] = CoordToJson(size);
        output["coord"] = coord;

        Json::Value meters = Json::Object();
        meters["min"] = Vec3ToJson(vec3(0, -64, 0));
        meters["maxInclusiveCoordOrigin"] = Vec3ToJson(vec3(
            float(size.x - 1) * 32.0,
            (float(size.y - 1) - 8.0) * 8.0,
            float(size.z - 1) * 32.0
        ));
        meters["maxExclusive"] = Vec3ToJson(vec3(
            float(size.x) * 32.0,
            (float(size.y) - 8.0) * 8.0,
            float(size.z) * 32.0
        ));
        meters["blockUnitSize"] = Vec3ToJson(vec3(32, 8, 32));
        meters["baseHeightOffset"] = 64.0;
        output["meters"] = meters;
        return output;
    }

    Json::Value Vec3DegToJson(const vec3 &in anglesRad) {
        return Vec3ToJson(vec3(
            Math::ToDeg(anglesRad.x),
            Math::ToDeg(anglesRad.y),
            Math::ToDeg(anglesRad.z)
        ));
    }

    Json::Value Vec2ToJson(const vec2 &in value) {
        Json::Value arr = Json::Array();
        arr.Add(value.x);
        arr.Add(value.y);
        return arr;
    }

    Json::Value Vec2DegToJson(const vec2 &in anglesRad) {
        return Vec2ToJson(vec2(Math::ToDeg(anglesRad.x), Math::ToDeg(anglesRad.y)));
    }

    Json::Value MapSummary(CGameCtnEditorFree@ editor) {
        Json::Value output = Json::Object();
        if (editor is null || editor.Challenge is null) return output;
        auto map = editor.Challenge;
        output["name"] = map.MapName;
        output["size"] = CoordToJson(map.Size);
        output["bounds"] = MapBoundsToJson(map.Size);
        output["nbBlocks"] = int(map.Blocks.Length);
        output["nbBakedBlocks"] = int(map.BakedBlocks.Length);
        output["nbItems"] = int(map.AnchoredObjects.Length);
        if (editor.PluginMapType !is null) {
            output["nbScriptItems"] = int(editor.PluginMapType.Items.Length);
        }
        output["vertexCount"] = int(map.VertexCount);
        if (map.MapInfo !is null) {
            output["fileName"] = map.MapInfo.FileName;
        }
        auto fid = GetFidFromNod(map);
        if (fid !is null) {
            output["fullFileName"] = fid.FullFileName;
        }
        return output;
    }

    string PackDescPath(CSystemPackDesc@ packDesc) {
        if (packDesc is null) return "";
        return packDesc.Url.Length > 0 ? packDesc.Url : string(packDesc.Name);
    }

    float InputFloatOr(Json::Value &in input, const string &in key, float defaultValue) {
        return input.HasKey(key) ? float(input[key]) : defaultValue;
    }

    float AngleInputRad(Json::Value &in input, const string &in degKey, const string &in radKey, float defaultDeg) {
        if (input.HasKey(radKey)) return float(input[radKey]);
        return Math::ToRad(InputFloatOr(input, degKey, defaultDeg));
    }

    vec3 RotationInput(Json::Value &in input) {
        return vec3(
            AngleInputRad(input, "pitch", "pitchRad", 0.0),
            AngleInputRad(input, "yaw", "yawRad", 0.0),
            AngleInputRad(input, "roll", "rollRad", 0.0)
        );
    }

    vec3 PositionInput(Json::Value &in input) {
        return vec3(float(input["x"]), float(input["y"]), float(input["z"]));
    }

    vec3 OptionalOffsetInput(Json::Value &in input) {
        return vec3(
            input.HasKey("offsetX") ? float(input["offsetX"]) : 0.0,
            input.HasKey("offsetY") ? float(input["offsetY"]) : 0.0,
            input.HasKey("offsetZ") ? float(input["offsetZ"]) : 0.0
        );
    }

    vec3 PivotInput(Json::Value &in input) {
        return vec3(
            input.HasKey("pivotX") ? float(input["pivotX"]) : 0.0,
            input.HasKey("pivotY") ? float(input["pivotY"]) : 0.0,
            input.HasKey("pivotZ") ? float(input["pivotZ"]) : 0.0
        );
    }

    bool HasTransformInput(Json::Value &in input) {
        return input.HasKey("offsetX") || input.HasKey("offsetY") || input.HasKey("offsetZ")
            || input.HasKey("pitch") || input.HasKey("yaw") || input.HasKey("roll")
            || input.HasKey("pitchRad") || input.HasKey("yawRad") || input.HasKey("rollRad");
    }

    // Convert a world-space look direction into orbital (hAngle, vAngle) radians.
    // Matches the game's convention verified by tests/test_camera_math.py:
    //   look_dir(h, v) = (cos(v) * sin(h), -sin(v), cos(v) * cos(h))
    // Editor::DirToLookUv omits asin and scales by /PI*2, so it is wrong at steep
    // pitches; use proper atan2 / asin here instead.
    vec2 LookDirToOrbitalAngles(vec3 dir) {
        if (dir.LengthSquared() < 1.0e-12) return vec2(0, 0);
        vec3 n = dir.Normalized();
        float h = Math::Atan2(n.x, n.z);
        float v = -Math::Asin(Math::Clamp(n.y, -1.0, 1.0));
        return vec2(h, v);
    }

    bool FocusCameraOn(vec3 pos, float distance) {
        auto editor = GetEditor();
        auto orbital = editor is null ? null : editor.OrbitalCameraControl;
        vec3 camPos = orbital is null ? pos + vec3(0, 0, -1) : orbital.Pos;
        vec3 dir = pos - camPos;
        if (dir.LengthSquared() < 1.0e-6) dir = vec3(0, 0, 1);
        return Editor::SetCamAnimationGoTo(LookDirToOrbitalAngles(dir), pos, distance);
    }

    // High-angle autofocus: look down at `pos` from above, keeping the horizontal yaw
    // pointing from the target back toward the current camera so the transition animates
    // naturally from the user's viewpoint.
    bool AutofocusCameraOn(vec3 pos, float distance) {
        auto editor = GetEditor();
        auto orbital = editor is null ? null : editor.OrbitalCameraControl;
        if (orbital is null) return FocusCameraOn(pos, distance);
        vec3 horiz = (orbital.Pos - pos) * vec3(1, 0, 1);
        if (horiz.LengthSquared() < 1.0e-6) horiz = vec3(0, 0, -1);
        horiz = horiz.Normalized();
        float pitchDown = Math::ToRad(65.0);
        vec3 lookDir = horiz * -Math::Cos(pitchDown) + vec3(0, -Math::Sin(pitchDown), 0);
        return Editor::SetCamAnimationGoTo(LookDirToOrbitalAngles(lookDir), pos, distance);
    }

    Json::Value BasicDialogSummary() {
        auto app = cast<CTrackMania>(GetApp());
        Json::Value output = Json::Object();
        if (app is null || app.BasicDialogs is null) {
            output["available"] = false;
            return output;
        }

        auto bd = app.BasicDialogs;
        auto frame = bd.Dialogs is null ? null : bd.Dialogs.CurrentFrame;
        output["available"] = true;
        output["dialog"] = int(bd.Dialog);
        output["hasFrame"] = frame !is null;
        if (frame !is null) {
            output["frameIdName"] = frame.IdName;
        }
        output["messageText"] = string(bd.Message_LabelText);
        output["messageButtonText"] = string(bd.Message_ButtonText);
        output["waitText"] = string(bd.WaitMessage_LabelText);
        output["waitButtonText"] = string(bd.WaitMessage_ButtonText);
        output["waitProgress"] = bd.WaitMessage_Progress;
        output["waitShowAbortButton"] = bd.WaitMessage_ShowAbortButton;
        return output;
    }

    string ScreenshotExtForFormat(const string &in format) {
        string lower = format.ToLower();
        if (lower == "webp") return ".webp";
        if (lower == "tga") return ".tga";
        if (lower == "dds") return ".dds";
        return ".jpg";
    }

    string SafeMapFileStem(const string &in name) {
        string ret = name.Trim();
        if (ret.Length == 0) ret = "tm-control-mcp-" + Time::Stamp;
        string bad = "\\/:*?\"<>|";
        for (uint i = 0; i < uint(bad.Length); i++) {
            ret = ret.Replace(bad.SubStr(i, 1), "_");
        }
        if (ret.ToLower().EndsWith(".map.gbx")) ret = ret.SubStr(0, ret.Length - 8);
        if (ret.ToLower().EndsWith(".gbx")) ret = ret.SubStr(0, ret.Length - 4);
        if (ret.Length == 0) ret = "tm-control-mcp-" + Time::Stamp;
        return ret;
    }

    string NormalizeMapSaveFileName(Json::Value &in input) {
        if (input.HasKey("fileName")) {
            string fileName = string(input["fileName"]).Trim().Replace("\\", "/");
            while (fileName.StartsWith("/")) fileName = fileName.SubStr(1);
            if (!fileName.ToLower().EndsWith(".map.gbx")) fileName += ".Map.Gbx";
            return fileName;
        }
        string folder = input.HasKey("folder") ? string(input["folder"]).Trim().Replace("\\", "/") : "MCP";
        while (folder.StartsWith("/")) folder = folder.SubStr(1);
        while (folder.EndsWith("/")) folder = folder.SubStr(0, folder.Length - 1);
        if (folder.Length == 0) folder = "MCP";
        string stem = SafeMapFileStem(input.HasKey("name") ? string(input["name"]) : "");
        return folder + "/" + stem + ".Map.Gbx";
    }

    Json::Value CameraToJson(CGameCtnEditorFree@ editor) {
        Json::Value output = Json::Object();
        auto pmt = editor.PluginMapType;
        auto orbital = editor.OrbitalCameraControl;
        output["target"] = Vec3ToJson(pmt.CameraTargetPosition);
        output["distance"] = pmt.CameraToTargetDistance;
        output["hAngle"] = pmt.CameraHAngle;
        output["vAngle"] = pmt.CameraVAngle;
        output["angles"] = Vec2ToJson(vec2(pmt.CameraHAngle, pmt.CameraVAngle));
        output["anglesDeg"] = Vec2DegToJson(vec2(pmt.CameraHAngle, pmt.CameraVAngle));
        if (orbital !is null) {
            output["position"] = Vec3ToJson(orbital.Pos);
            output["orbitalTarget"] = Vec3ToJson(orbital.m_TargetedPosition);
            output["orbitalDistance"] = orbital.m_CameraToTargetDistance;
        }
        return output;
    }

    int Nat3Distance(const nat3 &in a, const nat3 &in b) {
        int dx = int(a.x) - int(b.x);
        int dy = int(a.y) - int(b.y);
        int dz = int(a.z) - int(b.z);
        return Math::Abs(dx) + Math::Abs(dy) + Math::Abs(dz);
    }

    CGameEditorPluginMap::ECardinalDirections DirFromString(const string &in dir) {
        if (dir == "East") return CGameEditorPluginMap::ECardinalDirections::East;
        if (dir == "South") return CGameEditorPluginMap::ECardinalDirections::South;
        if (dir == "West") return CGameEditorPluginMap::ECardinalDirections::West;
        return CGameEditorPluginMap::ECardinalDirections::North;
    }

    CGameEditorPluginMap::ECardinalDirections8 Dir8FromString(const string &in dir) {
        if (dir == "East") return CGameEditorPluginMap::ECardinalDirections8::East;
        if (dir == "South") return CGameEditorPluginMap::ECardinalDirections8::South;
        if (dir == "West") return CGameEditorPluginMap::ECardinalDirections8::West;
        if (dir == "NorthEast") return CGameEditorPluginMap::ECardinalDirections8::NorthEast;
        if (dir == "SouthEast") return CGameEditorPluginMap::ECardinalDirections8::SouthEast;
        if (dir == "SouthWest") return CGameEditorPluginMap::ECardinalDirections8::SouthWest;
        if (dir == "NorthWest") return CGameEditorPluginMap::ECardinalDirections8::NorthWest;
        return CGameEditorPluginMap::ECardinalDirections8::North;
    }

    CGameEditorPluginMap::ERelativeDirections RelativeDirFromString(const string &in dir) {
        if (dir == "RightForward") return CGameEditorPluginMap::ERelativeDirections::RightForward;
        if (dir == "Right") return CGameEditorPluginMap::ERelativeDirections::Right;
        if (dir == "RightBackward") return CGameEditorPluginMap::ERelativeDirections::RightBackward;
        if (dir == "Backward") return CGameEditorPluginMap::ERelativeDirections::Backward;
        if (dir == "LeftBackward") return CGameEditorPluginMap::ERelativeDirections::LeftBackward;
        if (dir == "Left") return CGameEditorPluginMap::ERelativeDirections::Left;
        if (dir == "LeftForward") return CGameEditorPluginMap::ERelativeDirections::LeftForward;
        return CGameEditorPluginMap::ERelativeDirections::Forward;
    }

    Json::Value CursorApiToJson(CGameEditorPluginMap@ pmt) {
        Json::Value output = Json::Object();
        if (pmt is null || pmt.Cursor is null) {
            output["available"] = false;
            return output;
        }
        auto cursor = pmt.Cursor;
        output["available"] = true;
        output["coord"] = CoordToJson(cursor.Coord);
        output["dir"] = int(cursor.Dir);
        output["canUse"] = cursor.CanUse();
        output["locked"] = cursor.GetLock();
        output["canPlace"] = cursor.CanPlace();
        output["brightness"] = cursor.Brightness;
        output["hideDirectionalArrow"] = cursor.HideDirectionalArrow;
        output["customRGB"] = cursor.IsCustomRGBActivated();
        if (cursor.BlockModel !is null) {
            output["blockName"] = cursor.BlockModel.Name;
            output["blockIdName"] = cursor.BlockModel.IdName;
        }
        if (cursor.TerrainBlockModel !is null) {
            output["terrainBlockName"] = cursor.TerrainBlockModel.Name;
            output["terrainBlockIdName"] = cursor.TerrainBlockModel.IdName;
        }
        if (cursor.MacroblockModel !is null) {
            output["macroblockName"] = cursor.MacroblockModel.Name;
            output["macroblockIdName"] = cursor.MacroblockModel.IdName;
        }
        return output;
    }

    Json::Value ValidationToJson(CGameEditorPluginMapMapType@ pmt) {
        Json::Value output = Json::Object();
        if (pmt is null) {
            output["available"] = false;
            return output;
        }
        output["available"] = true;
        output["validationStatus"] = int(pmt.ValidationStatus);
        output["validabilityRequirementsMessage"] = string(pmt.ValidabilityRequirementsMessage);
        output["validationEndRequested"] = pmt.ValidationEndRequested;
        output["validationEndNoConfirm"] = pmt.ValidationEndNoConfirm;
        output["isSwitchedToPlayground"] = pmt.IsSwitchedToPlayground;
        output["isTesting"] = pmt.IsTesting;
        output["isValidating"] = pmt.IsValidating;
        return output;
    }

    Json::Value CameraApiToJson(CGameEditorPluginMap@ pmt) {
        Json::Value output = Json::Object();
        if (pmt is null || pmt.Camera is null) {
            output["available"] = false;
            return output;
        }
        output["available"] = true;
        output["canUse"] = pmt.Camera.CanUse();
        output["locked"] = pmt.Camera.GetLock();
        return output;
    }

    Json::Value SelectionToJson(CGameEditorPluginMapMapType@ pmt, uint limit = 20) {
        Json::Value output = Json::Object();
        if (pmt is null) {
            output["available"] = false;
            return output;
        }
        output["available"] = true;
        output["placeMode"] = int(pmt.PlaceMode);
        output["editMode"] = int(pmt.EditMode);
        output["selectedCoordsCount"] = int(pmt.CopyPaste_GetSelectedCoordsCount());
        output["customSelectionCount"] = int(pmt.CustomSelectionCoords.Length);
        output["customSelectionRGB"] = Vec3ToJson(pmt.CustomSelectionRGB);

        Json::Value coords = Json::Array();
        uint nb = Math::Min(limit, pmt.CustomSelectionCoords.Length);
        for (uint i = 0; i < nb; i++) {
            coords.Add(CoordToJson(pmt.CustomSelectionCoords[i]));
        }
        output["customSelectionSample"] = coords;
        output["customSelectionSampleLimit"] = int(limit);
        return output;
    }

    CGameEditorPluginCameraAPI::EZoomLevel ZoomLevelFromString(const string &in level) {
        if (level == "Close") return CGameEditorPluginCameraAPI::EZoomLevel::Close;
        if (level == "Far") return CGameEditorPluginCameraAPI::EZoomLevel::Far;
        return CGameEditorPluginCameraAPI::EZoomLevel::Medium;
    }

    CGameEditorPluginCameraAPI::ECameraVStep CameraVStepFromString(const string &in step) {
        if (step == "Low") return CGameEditorPluginCameraAPI::ECameraVStep::Low;
        if (step == "MediumLow") return CGameEditorPluginCameraAPI::ECameraVStep::MediumLow;
        if (step == "MediumHigh") return CGameEditorPluginCameraAPI::ECameraVStep::MediumHigh;
        if (step == "High") return CGameEditorPluginCameraAPI::ECameraVStep::High;
        return CGameEditorPluginCameraAPI::ECameraVStep::Medium;
    }

    Json::Value BlockToJson(CGameCtnBlock@ block) {
        if (block is null) return Json::Value();
        Json::Value obj = Json::Object();
        obj["coord"] = CoordToJson(block.Coord);
        obj["dir"] = int(block.BlockDir);
        if (block.BlockInfo is null) {
            obj["name"] = "";
            obj["idName"] = "";
        } else {
            obj["name"] = block.BlockInfo.Name;
            obj["idName"] = block.BlockInfo.IdName;
        }
        bool isFree = Editor::IsBlockFree(block);
        obj["isFree"] = isFree;
        obj["variant"] = int(block.BlockInfoVariantIndex);
        obj["mobilIndex"] = int(block.MobilIndex);
        obj["mobilVariant"] = int(block.MobilVariantIndex);
        obj["isGround"] = block.IsGround;
        obj["isGhost"] = block.IsGhostBlock();
        obj["pos"] = Vec3ToJson(Editor::GetBlockLocation(block));
        auto rot = Editor::GetBlockRotation(block);
        obj["rot"] = Vec3ToJson(rot);
        obj["rotDeg"] = Vec3DegToJson(rot);
        obj["skin"] = BlockSkinToJson(block);
        return obj;
    }

    Json::Value ItemToJson(CGameCtnAnchoredObject@ item) {
        if (item is null) return Json::Value();
        Json::Value obj = Json::Object();
        obj["coord"] = CoordToJson(item.BlockUnitCoord);
        obj["pos"] = Vec3ToJson(item.AbsolutePositionInMap);
        auto rot = vec3(item.Pitch, item.Yaw, item.Roll);
        obj["rot"] = Vec3ToJson(rot);
        obj["rotDeg"] = Vec3DegToJson(rot);
        obj["isFlying"] = item.IsFlying;
        obj["scale"] = item.Scale;
        obj["variant"] = int(item.IVariant);
        if (item.ItemModel is null) {
            obj["name"] = "";
            obj["idName"] = "";
            obj["waypointType"] = -1;
        } else {
            obj["name"] = item.ItemModel.Name;
            obj["idName"] = item.ItemModel.IdName;
            obj["waypointType"] = int(item.ItemModel.WaypointType);
        }
        obj["skin"] = ItemSkinToJson(item);
        return obj;
    }

    bool ModelNameMatches(CGameCtnBlockInfo@ blockInfo, const string &in lowerName) {
        if (blockInfo is null) return false;
        if (string(blockInfo.Name).ToLower() == lowerName) return true;
        if (string(blockInfo.IdName).ToLower() == lowerName) return true;
        return false;
    }

    bool ModelMatchesQuery(CGameCtnBlockInfo@ blockInfo, const string &in lowerQuery) {
        if (blockInfo is null) return false;
        if (lowerQuery.Length == 0) return true;
        if (string(blockInfo.Name).ToLower().Contains(lowerQuery)) return true;
        if (string(blockInfo.IdName).ToLower().Contains(lowerQuery)) return true;
        return false;
    }

    Json::Value ModelToJson(CGameCtnBlockInfo@ blockInfo, bool isTerrain) {
        Json::Value obj = Json::Object();
        obj["name"] = blockInfo.Name;
        obj["idName"] = blockInfo.IdName;
        obj["isTerrain"] = isTerrain;
        obj["groundVariants"] = int(blockInfo.AdditionalVariantsGround.Length) + 1;
        obj["airVariants"] = int(blockInfo.AdditionalVariantsAir.Length) + 1;
        obj["variantBaseGroundSize"] = CoordToJson(blockInfo.VariantBaseGround.Size);
        obj["variantBaseAirSize"] = CoordToJson(blockInfo.VariantBaseAir.Size);
        return obj;
    }

    Json::Value MacroblockModelToJson(CGameCtnMacroBlockInfo@ macroblockInfo) {
        Json::Value obj = Json::Object();
        obj["type"] = "macroblock";
        obj["name"] = macroblockInfo.Name;
        obj["idName"] = macroblockInfo.IdName;
        return obj;
    }

    Json::Value ItemModelToJson(CGameItemModel@ itemModel, const string &in path = "") {
        Json::Value obj = Json::Object();
        obj["type"] = "item";
        if (itemModel is null) {
            obj["name"] = "";
            obj["idName"] = "";
            obj["path"] = path;
            obj["waypointType"] = -1;
        } else {
            obj["name"] = itemModel.Name;
            obj["idName"] = itemModel.IdName;
            obj["path"] = path.Length > 0 ? path : itemModel.IdName;
            obj["waypointType"] = int(itemModel.WaypointType);
        }
        return obj;
    }

    int FindNamedMacroblockIndex(const string &in name) {
        for (uint i = 0; i < g_NamedMacroblockNames.Length; i++) {
            if (g_NamedMacroblockNames[i] == name) return int(i);
        }
        return -1;
    }

    Editor::MacroblockSpec@ GetNamedMacroblock(const string &in name) {
        int index = FindNamedMacroblockIndex(name);
        if (index < 0) return null;
        return g_NamedMacroblocks[index];
    }

    Json::Value NamedMacroblockSummary(const string &in name, Editor::MacroblockSpec@ mb) {
        Json::Value output = Json::Object();
        auto skins = GetNamedMacroblockSkins(name);
        output["name"] = name;
        output["exists"] = mb !is null;
        output["nbBlocks"] = mb is null ? 0 : int(mb.blocks.Length);
        output["nbItems"] = mb is null ? 0 : int(mb.items.Length);
        output["nbRawSkins"] = mb is null ? 0 : int(mb.skins.Length);
        output["nbPostSkins"] = skins is null ? 0 : int(skins.Length);
        output["nbSkins"] = int(output["nbRawSkins"]) + int(output["nbPostSkins"]);
        return output;
    }

    vec3 MacroblockInternalOffset() {
        return vec3(0, 56, 0);
    }

    Json::Value BlockSpecToJson(Editor::BlockSpec@ block) {
        Json::Value obj = Json::Object();
        if (block is null) return obj;
        obj["name"] = block.name;
        obj["coord"] = CoordToJson(block.coord);
        obj["dir"] = int(block.dir);
        obj["dir2"] = int(block.dir2);
        obj["pos"] = Vec3ToJson(block.pos - MacroblockInternalOffset());
        obj["internalPos"] = Vec3ToJson(block.pos);
        obj["rot"] = Vec3ToJson(block.pyr);
        obj["rotDeg"] = Vec3DegToJson(block.pyr);
        obj["variant"] = int(block.variant);
        obj["flags"] = int(block.flags);
        obj["isFree"] = block.isFree;
        obj["isGround"] = block.isGround;
        obj["isGhost"] = block.isGhost;
        return obj;
    }

    Json::Value ItemSpecToJson(Editor::ItemSpec@ item) {
        Json::Value obj = Json::Object();
        if (item is null) return obj;
        obj["name"] = item.name;
        obj["coord"] = CoordToJson(item.coord);
        obj["pos"] = Vec3ToJson(item.pos - MacroblockInternalOffset());
        obj["internalPos"] = Vec3ToJson(item.pos);
        obj["rot"] = Vec3ToJson(item.pyr);
        obj["rotDeg"] = Vec3DegToJson(item.pyr);
        obj["variant"] = int(item.variantIx);
        obj["isFlying"] = item.isFlying != 0;
        return obj;
    }

    void ApplyTransformToSpec(Editor::BlockSpec@ block, const mat4 &in transform) {
        auto blockMat = mat4::Translate(block.pos) * Editor::EulerToMat(block.pyr);
        auto transformed = transform * blockMat;
        block.pos = (transformed * vec3()).xyz;
        block.pyr = Editor::PitchYawRollFromRotationMatrix(mat4::Translate(block.pos * -1.0) * transformed);
    }

    void ApplyTransformToSpec(Editor::ItemSpec@ item, const mat4 &in transform) {
        auto itemMat = mat4::Translate(item.pos) * Editor::EulerToMat(item.pyr);
        auto transformed = transform * itemMat;
        item.pos = (transformed * vec3()).xyz;
        item.pyr = Editor::PitchYawRollFromRotationMatrix(mat4::Translate(item.pos * -1.0) * transformed);
    }

    Editor::MacroblockSpec@ DuplicateAndTransformMacroblock(Editor::MacroblockSpec@ mb, vec3 offset, vec3 rotation, vec3 pivot) {
        auto copy = mb.Duplicate();
        auto internalPivot = pivot + MacroblockInternalOffset();
        auto transform = mat4::Translate(internalPivot + offset)
            * Editor::EulerToMat(rotation)
            * mat4::Translate(internalPivot * -1.0);
        for (uint i = 0; i < copy.blocks.Length; i++) {
            ApplyTransformToSpec(copy.blocks[i], transform);
        }
        for (uint i = 0; i < copy.items.Length; i++) {
            ApplyTransformToSpec(copy.items[i], transform);
        }
        return copy;
    }

    bool TextMatchesQuery(const string &in text, const string &in lowerQuery) {
        return lowerQuery.Length == 0 || text.ToLower().Contains(lowerQuery);
    }

    bool InventoryTypeEnabled(const string &in requested, const string &in ty) {
        if (requested.Length == 0 || requested == "all") return true;
        if (requested == ty) return true;
        if (requested == "blocks" && ty == "block") return true;
        if (requested == "items" && ty == "item") return true;
        if (requested == "macroblocks" && ty == "macroblock") return true;
        return false;
    }

    Json::Value InventorySummary(CGameEditorPluginMap@ pmt) {
        Json::Value output = Json::Object();
        if (pmt is null) return output;
        output["source"] = "pluginMap";
        output["nbBlocks"] = int(pmt.BlockModels.Length);
        output["nbTerrainBlocks"] = int(pmt.TerrainBlockModels.Length);
        output["nbItems"] = int(Editor::GetInventoryNbItems());
        output["nbMacroblocks"] = int(pmt.MacroblockModels.Length);
        output["isScanningBlocks"] = false;
        output["isScanningItems"] = Editor::IsInventoryScanningItems();
        output["isScanningMacroblocks"] = false;
        output["loadingStatus"] = "loaded from CGameEditorPluginMap";
        output["loadingStatusShort"] = "ready";
        output["note"] = "Blocks/macroblocks come from CGameEditorPluginMap; items come from E++ inventory wrapper exports.";
        return output;
    }

    CGameCtnBlockInfo@ ResolveBlockModel(CGameEditorPluginMap@ pluginMap, const string &in blockName, bool &out isTerrain) {
        isTerrain = false;
        CGameCtnBlockInfo@ blockInfo = pluginMap.GetBlockModelFromName(blockName);
        if (blockInfo !is null) return blockInfo;

        string lowerName = blockName.ToLower();
        for (uint i = 0; i < pluginMap.BlockModels.Length; i++) {
            @blockInfo = pluginMap.BlockModels[i];
            if (ModelNameMatches(blockInfo, lowerName)) return blockInfo;
        }

        isTerrain = true;
        @blockInfo = pluginMap.GetTerrainBlockModelFromName(blockName);
        if (blockInfo !is null) return blockInfo;

        for (uint i = 0; i < pluginMap.TerrainBlockModels.Length; i++) {
            @blockInfo = pluginMap.TerrainBlockModels[i];
            if (ModelNameMatches(blockInfo, lowerName)) return blockInfo;
        }

        isTerrain = false;
        return null;
    }

    CGameItemModel@ ResolveItemModel(const string &in itemPath) {
        return Editor::GetInventoryItemModelByPath(itemPath);
    }

    bool IsToolName(const string &in name) {
        return name == "GetMode"
            || name == "OpenMapInEditor"
            || name == "GetMapInfo"
            || name == "GetMapEnvironment"
            || name == "SaveMapAs"
            || name == "GetDialog"
            || name == "RespondDialog"
            || name == "ControlValidation"
            || name == "ControlSelection"
            || name == "GetCursor"
            || name == "GetEditorSelectionState"
            || name == "ControlCursor"
            || name == "GetEditorCamera"
            || name == "SetEditorCamera"
            || name == "ControlCamera"
            || name == "FocusCamera"
            || name == "TakeScreenshot"
            || name == "GetBlocks"
            || name == "GetRecentBlocks"
            || name == "GetBlockAt"
            || name == "GetItems"
            || name == "GetRecentItems"
            || name == "GetInventorySummary"
            || name == "FindInventory"
            || name == "RefreshInventory"
            || name == "BrowseInventoryTree"
            || name == "InspectMacroblockModel"
            || name == "ListMacroblockInstances"
            || name == "FindBlockModels"
            || name == "RunGizmoApplyBlock"
            || name == "RunComputeItemsDiagnostic"
            || name == "DevSafeRead"
            || name == "DevGetPointers"
            || name == "DevComputeItemsPointers"
            || name == "CreateNamedMacroblock"
            || name == "GetNamedMacroblock"
            || name == "ListNamedMacroblocks"
            || name == "ClearNamedMacroblock"
            || name == "AddBlockToNamedMacroblock"
            || name == "AddBlocksToNamedMacroblock"
            || name == "AddItemToNamedMacroblock"
            || name == "AddItemsToNamedMacroblock"
            || name == "PlaceNamedMacroblock"
            || name == "PreflightNamedMacroblockPlacement"
            || name == "CanPlaceBlock"
            || name == "PlaceBlock"
            || name == "PlaceBlockViaEditorPlusPlus"
            || name == "PlaceItemViaEditorPlusPlus"
            || name == "RemoveBlock"
            || name == "ClearBlocks"
            || name == "ClearItems"
            || name == "ClearMapContent"
            || name == "RemoveRecentBlocks"
            || name == "RemoveRecentItems"
            || name == "RemoveBlocksByIndex"
            || name == "RemoveItemsByIndex"
            || name == "SelectBlockModel"
            || name == "SetCursorBlock"
            || name == "Undo"
            || name == "Redo"
            || name == "SetMenuPage"
            || name == "GetMenuPage"
            || name == "ListKnownMenuRoutes"
            || name == "ListGuides"
            || name == "GetGuide"
            || name == "EditNewMap"
            || name == "ListMenuManialinkControls";
    }

    Json::Value@ CallTool(const string &in name, Json::Value &in input) {
        if (name == "GetMode") return GetMode(input);
        if (name == "OpenMapInEditor") return OpenMapInEditor(input);
        if (name == "GetMapInfo") return GetMapInfo(input);
        if (name == "GetMapEnvironment") return GetMapEnvironment(input);
        if (name == "SaveMapAs") return SaveMapAs(input);
        if (name == "GetDialog") return GetDialog(input);
        if (name == "RespondDialog") return RespondDialog(input);
        if (name == "ControlValidation") return ControlValidation(input);
        if (name == "ControlSelection") return ControlSelection(input);
        if (name == "GetCursor") return GetCursor(input);
        if (name == "GetEditorSelectionState") return GetEditorSelectionState(input);
        if (name == "ControlCursor") return ControlCursor(input);
        if (name == "GetEditorCamera") return GetEditorCamera(input);
        if (name == "SetEditorCamera") return SetEditorCamera(input);
        if (name == "ControlCamera") return ControlCamera(input);
        if (name == "FocusCamera") return FocusCamera(input);
        if (name == "TakeScreenshot") return TakeScreenshot(input);
        if (name == "GetBlocks") return GetBlocks(input);
        if (name == "GetRecentBlocks") return GetRecentBlocks(input);
        if (name == "GetBlockAt") return GetBlockAt(input);
        if (name == "GetItems") return GetItems(input);
        if (name == "GetRecentItems") return GetRecentItems(input);
        if (name == "GetInventorySummary") return GetInventorySummary(input);
        if (name == "FindInventory") return FindInventory(input);
        if (name == "RefreshInventory") return RefreshInventory(input);
        if (name == "BrowseInventoryTree") return BrowseInventoryTree(input);
        if (name == "InspectMacroblockModel") return InspectMacroblockModel(input);
        if (name == "ListMacroblockInstances") return ListMacroblockInstances(input);
        if (name == "FindBlockModels") return FindBlockModels(input);
        if (name == "RunGizmoApplyBlock") return RunGizmoApplyBlock(input);
        if (name == "RunComputeItemsDiagnostic") return RunComputeItemsDiagnostic(input);
        if (name == "DevSafeRead") return RunDevSafeRead(input);
        if (name == "DevGetPointers") return RunDevGetPointers(input);
        if (name == "DevComputeItemsPointers") return RunDevComputeItemsPointers(input);
        if (name == "CreateNamedMacroblock") return CreateNamedMacroblock(input);
        if (name == "GetNamedMacroblock") return GetNamedMacroblockTool(input);
        if (name == "ListNamedMacroblocks") return ListNamedMacroblocks(input);
        if (name == "ClearNamedMacroblock") return ClearNamedMacroblock(input);
        if (name == "AddBlockToNamedMacroblock") return AddBlockToNamedMacroblock(input);
        if (name == "AddBlocksToNamedMacroblock") return AddBlocksToNamedMacroblock(input);
        if (name == "AddItemToNamedMacroblock") return AddItemToNamedMacroblock(input);
        if (name == "AddItemsToNamedMacroblock") return AddItemsToNamedMacroblock(input);
        if (name == "PlaceNamedMacroblock") return PlaceNamedMacroblock(input);
        if (name == "PreflightNamedMacroblockPlacement") return PreflightNamedMacroblockPlacement(input);
        if (name == "CanPlaceBlock") return CanPlaceBlock(input);
        if (name == "PlaceBlock") return PlaceBlock(input);
        if (name == "PlaceBlockViaEditorPlusPlus") return PlaceBlockViaEditorPlusPlus(input);
        if (name == "PlaceItemViaEditorPlusPlus") return PlaceItemViaEditorPlusPlus(input);
        if (name == "RemoveBlock") return RemoveBlock(input);
        if (name == "ClearBlocks") return ClearBlocks(input);
        if (name == "ClearItems") return ClearItems(input);
        if (name == "ClearMapContent") return ClearMapContent(input);
        if (name == "RemoveRecentBlocks") return RemoveRecentBlocks(input);
        if (name == "RemoveRecentItems") return RemoveRecentItems(input);
        if (name == "RemoveBlocksByIndex") return RemoveBlocksByIndex(input);
        if (name == "RemoveItemsByIndex") return RemoveItemsByIndex(input);
        if (name == "SelectBlockModel") return SelectBlockModel(input);
        if (name == "SetCursorBlock") return SetCursorBlock(input);
        if (name == "Undo") return Undo(input);
        if (name == "Redo") return Redo(input);
        if (name == "SetMenuPage") return SetMenuPage(input);
        if (name == "GetMenuPage") return GetMenuPage(input);
        if (name == "ListKnownMenuRoutes") return ListKnownMenuRoutes(input);
        if (name == "ListGuides") return ListGuides(input);
        if (name == "GetGuide") return GetGuide(input);
        if (name == "EditNewMap") return EditNewMapTool(input);
        if (name == "ListMenuManialinkControls") return ListMenuManialinkControls(input);
        return null;
    }

    Json::Value@ GetToolList() {
        Json::Value tools = Json::Array();
        tools.Add(MakeTool("GetMode", "Get current game mode.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("OpenMapInEditor", "Open a local map file in the editor.", '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}'));
        tools.Add(MakeTool("GetMapInfo", "Get current editor map name and counts.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("GetMapEnvironment", "Read map collection, decoration, map type/style, mood, and collection-unit metadata.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("SaveMapAs", "Save the current editor map to a named file under the user Maps folder. Use fileName for an explicit path relative to Maps, or name/folder for Maps/folder/name.Map.Gbx.", '{"type":"object","properties":{"name":{"type":"string"},"folder":{"type":"string"},"fileName":{"type":"string"},"overwrite":{"type":"boolean"}}}'));
        tools.Add(MakeTool("GetDialog", "Inspect Trackmania's current BasicDialogs state and active dialog frame.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("RespondDialog", "Respond to Trackmania BasicDialogs. action: yes, no, cancel, ok, validate, hide.", '{"type":"object","properties":{"action":{"type":"string"}},"required":["action"]}'));
        tools.Add(MakeTool("ControlValidation", "Inspect or trigger map validation/test/playground controls. Actions: status, validate, requestEnterPlayground, requestLeavePlayground, testFromStart, testFromCoord.", '{"type":"object","properties":{"action":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"}}}'));
        tools.Add(MakeTool("ControlSelection", "Inspect or control editor copy-paste/custom selection. Actions: status, showCustom, hideCustom, resetSelection, selectAll, addSelection, copy, cut, remove, symmetrize.", '{"type":"object","properties":{"action":{"type":"string"},"x1":{"type":"integer"},"y1":{"type":"integer"},"z1":{"type":"integer"},"x2":{"type":"integer"},"y2":{"type":"integer"},"z2":{"type":"integer"},"limit":{"type":"integer"}}}'));
        tools.Add(MakeTool("GetCursor", "Get editor cursor coordinate and selected block.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("GetEditorSelectionState", "Read current editor selection/picker/cursor state for gizmo diagnostics.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("ControlCursor", "Use the editor cursor API: status, raise, lower, rotate, move, moveToCameraTarget, followCamera, disableMouseDetection, releaseLock, resetRGB, setRGB.", '{"type":"object","properties":{"action":{"type":"string"},"direction":{"type":"string"},"directionKind":{"type":"string"},"count":{"type":"integer"},"clockwise":{"type":"boolean"},"follow":{"type":"boolean"},"disable":{"type":"boolean"},"r":{"type":"number"},"g":{"type":"number"},"b":{"type":"number"}}}'));
        tools.Add(MakeTool("GetEditorCamera", "Get editor camera target, angles, distance, and current orbital position.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("SetEditorCamera", "Set editor camera target, angles, and target distance. Angles default to degrees; use hAngleRad/vAngleRad for radians.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"hAngle":{"type":"number"},"vAngle":{"type":"number"},"hAngleRad":{"type":"number"},"vAngleRad":{"type":"number"},"distance":{"type":"number"},"animate":{"type":"boolean"}}}'));
        tools.Add(MakeTool("ControlCamera", "Use the editor camera API: status, centerOnCursor, moveToMapCenter, watchWholeMap, watchStart, watchClosestFinishLine, watchClosestCheckpoint, zoom, zoomIn, zoomOut, look, followCursor, ignoreCollisions, releaseLock, setVStep.", '{"type":"object","properties":{"action":{"type":"string"},"smooth":{"type":"boolean"},"loop":{"type":"boolean"},"clockwise":{"type":"boolean"},"halfSteps":{"type":"boolean"},"level":{"type":"string"},"direction":{"type":"string"},"directionKind":{"type":"string"},"follow":{"type":"boolean"},"ignore":{"type":"boolean"},"step":{"type":"string"}}}'));
        tools.Add(MakeTool("FocusCamera", "Focus the editor camera on a world position using E++ camera animation.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"distance":{"type":"number"}},"required":["x","y","z"]}'));
        tools.Add(MakeTool("TakeScreenshot", "Trigger a built-in viewport screenshot and return the game ScreenShots folder to inspect.", '{"type":"object","properties":{"format":{"type":"string"}}}'));
        tools.Add(MakeTool("GetBlocks", "Get blocks by optional grid/world radius, model query, and freeblock filter.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"radius":{"type":"number"},"world":{"type":"boolean"},"query":{"type":"string"},"isFree":{"type":"boolean"},"limit":{"type":"integer"}}}'));
        tools.Add(MakeTool("GetRecentBlocks", "Get the last N blocks in map block order, useful for freeblock placement readback.", '{"type":"object","properties":{"count":{"type":"integer"}}}'));
        tools.Add(MakeTool("GetBlockAt", "Get block info at exact grid coordinate.", '{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"}},"required":["x","y","z"]}'));
        tools.Add(MakeTool("GetItems", "Get anchored items near a world position, or all items up to limit if no position is provided.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"radius":{"type":"number"},"limit":{"type":"integer"}}}'));
        tools.Add(MakeTool("GetRecentItems", "Get the last N anchored items in map item order.", '{"type":"object","properties":{"count":{"type":"integer"}}}'));
        tools.Add(MakeTool("GetInventorySummary", "Get E++ inventory cache counts and scan status.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("FindInventory", "Search E++ inventory cache blocks, items, and macroblocks.", '{"type":"object","properties":{"query":{"type":"string"},"type":{"type":"string"},"limit":{"type":"integer"}}}'));
        tools.Add(MakeTool("RefreshInventory", "Trigger E++ InventoryCache rescan (use after user adds items mid-session; cache is scanned once on editor load).", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("BrowseInventoryTree", "Read-only browse of the editor inventory root/directories. Supports root, rootIndex, path, depth, limit, query.", '{"type":"object","properties":{"root":{"type":"string"},"rootIndex":{"type":"integer"},"path":{"type":"string"},"depth":{"type":"integer"},"limit":{"type":"integer"},"query":{"type":"string"},"includeArticles":{"type":"boolean"}}}'));
        tools.Add(MakeTool("InspectMacroblockModel", "Inspect a loaded macroblock model by name, file path, or index via E++ MacroblockSpec conversion.", '{"type":"object","properties":{"name":{"type":"string"},"path":{"type":"string"},"index":{"type":"integer"},"limit":{"type":"integer"},"includeItems":{"type":"boolean"}}}'));
        tools.Add(MakeTool("ListMacroblockInstances", "List placed map macroblock instances with coord, order, user data, size, unit coords, and model metadata.", '{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"},"recent":{"type":"boolean"},"unitCoordLimit":{"type":"integer"}}}'));
        tools.Add(MakeTool("FindBlockModels", "Search loaded editor block models.", '{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"},"includeTerrain":{"type":"boolean"},"terrainOnly":{"type":"boolean"}}}'));
        tools.Add(MakeTool("RunGizmoApplyBlock", "DEV diagnostic: apply a free block through E++'s actual gizmo apply path, with mapPre/mapPost and recent block readback.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"variant":{"type":"integer"},"autofocus":{"type":"boolean"},"autofocusDistance":{"type":"number"}},"required":["blockName","x","y","z"]}'));
        tools.Add(MakeTool("RunComputeItemsDiagnostic", "DEV diagnostic: create a CGameEditorMapMacroBlockInstance at the given grid coord for a macroblock file, call ComputeItemsForMacroblockInstance, and report wrapper pointers + live AnchoredObject matches. Optional testSkin={itemIndex,bgSkin,fgSkin} tries SetItemSkin(s) on the wrapper and reports pre/post skin persistence.", '{"type":"object","properties":{"mbPath":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"force":{"type":"boolean"},"testSkin":{"type":"object","properties":{"itemIndex":{"type":"integer"},"bgSkin":{"type":"string"},"fgSkin":{"type":"string"}}}},"required":["mbPath","x","y","z"]}'));
        tools.Add(MakeTool("DevSafeRead", "Read memory at an arbitrary address using Dev::SafeRead*. ptr accepts hex string \"0x...\" or integer. Optional offset/offsets (array of ints) are summed. kind: u8|u16|u32|u64|i8|i16|i32|i64|f32|vec2|vec3|vec4|cstr|bytes. For cstr/bytes, len caps bytes read (default 256/64, bytes max 4096). Reports probe result, value, and readError on faults.", '{"type":"object","properties":{"ptr":{"type":["string","integer"]},"offset":{"type":"integer"},"offsets":{"type":"array","items":{"type":"integer"}},"kind":{"type":"string"},"len":{"type":"integer"}},"required":["ptr"]}'));
        tools.Add(MakeTool("DevGetPointers", "Return raw pointers for the current editor, PluginMapType, Challenge, Cursor, and App, with per-nod vtable/refcount peeks. Optional listAnchoredObjects, listBlocks, and listPmtItems include map items/blocks/pmt.Items pointers (capped by *Limit params, default 20). listPmtItems exposes healthy CGameCtnEditorScriptAnchoredObject wrappers for memory comparison against compute-path wrappers.", '{"type":"object","properties":{"listAnchoredObjects":{"type":"boolean"},"anchoredObjectsLimit":{"type":"integer"},"listBlocks":{"type":"boolean"},"blocksLimit":{"type":"integer"},"listPmtItems":{"type":"boolean"},"pmtItemsLimit":{"type":"integer"}}}'));
        tools.Add(MakeTool("DevComputeItemsPointers", "Like RunComputeItemsDiagnostic but NEVER accesses wrapper fields (Position/ItemModel). Returns raw pointers + vtable/refcount peeks for each MacroblockInstanceItemsResults entry so you can inspect layout via DevSafeRead without crashing.", '{"type":"object","properties":{"mbPath":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"force":{"type":"boolean"}},"required":["mbPath","x","y","z"]}'));
        tools.Add(MakeTool("CreateNamedMacroblock", "Create or replace an in-memory named macroblock.", '{"type":"object","properties":{"name":{"type":"string"},"replace":{"type":"boolean"}},"required":["name"]}'));
        tools.Add(MakeTool("GetNamedMacroblock", "Inspect an in-memory named macroblock and return stored block/item specs.", '{"type":"object","properties":{"name":{"type":"string"},"limit":{"type":"integer"},"includeItems":{"type":"boolean"}},"required":["name"]}'));
        tools.Add(MakeTool("ListNamedMacroblocks", "List in-memory named macroblocks.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("ClearNamedMacroblock", "Clear one in-memory named macroblock, or all with all=true.", '{"type":"object","properties":{"name":{"type":"string"},"all":{"type":"boolean"}}}'));
        tools.Add(MakeTool("AddBlockToNamedMacroblock", "Add a free block spec to an in-memory named macroblock. Rotation defaults to degrees; optional bgSkin/fgSkin are applied after placement.", '{"type":"object","properties":{"name":{"type":"string"},"blockName":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"variant":{"type":"integer"},"bgSkin":{"type":"string"},"fgSkin":{"type":"string"},"skin":{"type":"string"},"create":{"type":"boolean"}},"required":["name","blockName","x","y","z"]}'));
        tools.Add(MakeTool("AddBlocksToNamedMacroblock", "Add many free block specs to an in-memory named macroblock in one MCP request.", '{"type":"object","properties":{"name":{"type":"string"},"blocks":{"type":"array","items":{"type":"object"}},"create":{"type":"boolean"},"continueOnError":{"type":"boolean"}},"required":["name","blocks"]}'));
        tools.Add(MakeTool("AddItemToNamedMacroblock", "Add a flying item spec to an in-memory named macroblock by inventory item path. Rotation defaults to degrees; optional bgSkin/fgSkin are applied after placement.", '{"type":"object","properties":{"name":{"type":"string"},"itemPath":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"variant":{"type":"integer"},"bgSkin":{"type":"string"},"fgSkin":{"type":"string"},"skin":{"type":"string"},"create":{"type":"boolean"}},"required":["name","itemPath","x","y","z"]}'));
        tools.Add(MakeTool("AddItemsToNamedMacroblock", "Add many flying item specs to an in-memory named macroblock in one MCP request.", '{"type":"object","properties":{"name":{"type":"string"},"items":{"type":"array","items":{"type":"object"}},"create":{"type":"boolean"},"continueOnError":{"type":"boolean"}},"required":["name","items"]}'));
        tools.Add(MakeTool("PlaceNamedMacroblock", "Place an in-memory named macroblock through Editor++ macroblock placement with optional position offset, rotation around pivot, and mapPre/mapPost metadata.", '{"type":"object","properties":{"name":{"type":"string"},"offsetX":{"type":"number"},"offsetY":{"type":"number"},"offsetZ":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"pivotX":{"type":"number"},"pivotY":{"type":"number"},"pivotZ":{"type":"number"},"addUndo":{"type":"boolean"},"autofocus":{"type":"boolean"},"autofocusDistance":{"type":"number"}},"required":["name"]}'));
        tools.Add(MakeTool("PreflightNamedMacroblockPlacement", "Non-mutating checks for a named macroblock placement: transformed extents, map bounds, missing models, and invalid variants.", '{"type":"object","properties":{"name":{"type":"string"},"offsetX":{"type":"number"},"offsetY":{"type":"number"},"offsetZ":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"pivotX":{"type":"number"},"pivotY":{"type":"number"},"pivotZ":{"type":"number"},"limit":{"type":"integer"}},"required":["name"]}'));
        tools.Add(MakeTool("CanPlaceBlock", "Check whether a normal grid/terrain block can be placed without mutating the map.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"allowDestruction":{"type":"boolean"}},"required":["blockName","x","y","z"]}'));
        tools.Add(MakeTool("PlaceBlock", "Place a block in the editor and return mapPre/mapPost metadata.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"allowDestruction":{"type":"boolean"}},"required":["blockName","x","y","z"]}'));
        tools.Add(MakeTool("PlaceBlockViaEditorPlusPlus", "Place one or more free blocks through Editor++ macroblock placement and return mapPre/mapPost metadata. Rotation defaults to degrees; use pitchRad/yawRad/rollRad for radians.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"repeat":{"type":"integer"},"spacingX":{"type":"number"},"spacingY":{"type":"number"},"spacingZ":{"type":"number"},"addUndo":{"type":"boolean"},"autofocus":{"type":"boolean"},"autofocusDistance":{"type":"number"}},"required":["blockName","x","y","z"]}'));
        tools.Add(MakeTool("PlaceItemViaEditorPlusPlus", "Place one or more flying items through Editor++ item placement and return mapPre/mapPost metadata. Rotation defaults to degrees.", '{"type":"object","properties":{"itemPath":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"pitch":{"type":"number"},"yaw":{"type":"number"},"roll":{"type":"number"},"pitchRad":{"type":"number"},"yawRad":{"type":"number"},"rollRad":{"type":"number"},"repeat":{"type":"integer"},"spacingX":{"type":"number"},"spacingY":{"type":"number"},"spacingZ":{"type":"number"},"variant":{"type":"integer"},"addUndo":{"type":"boolean"},"autofocus":{"type":"boolean"},"autofocusDistance":{"type":"number"}},"required":["itemPath","x","y","z"]}'));
        tools.Add(MakeTool("RemoveBlock", "Remove a block at grid coordinates.", '{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"}},"required":["x","y","z"]}'));
        tools.Add(MakeTool("ClearBlocks", "Remove all map blocks through the editor PluginMapType RemoveAllBlocks method.", '{"type":"object","properties":{"autosave":{"type":"boolean"}}}'));
        tools.Add(MakeTool("ClearItems", "Remove all map items/objects through the editor PluginMapType RemoveAllObjects method.", '{"type":"object","properties":{"autosave":{"type":"boolean"}}}'));
        tools.Add(MakeTool("ClearMapContent", "Remove all map blocks and items through editor PluginMapType remove-all methods.", '{"type":"object","properties":{"autosave":{"type":"boolean"},"includeTerrain":{"type":"boolean"}}}'));
        tools.Add(MakeTool("RemoveRecentBlocks", "Delete the last N map blocks through Editor++ deletion and return mapPre/mapPost metadata.", '{"type":"object","properties":{"count":{"type":"integer"},"addUndo":{"type":"boolean"}}}'));
        tools.Add(MakeTool("RemoveRecentItems", "Delete the last N map items through Editor++ deletion and return mapPre/mapPost metadata. Direct buffer fallback is opt-in.", '{"type":"object","properties":{"count":{"type":"integer"},"addUndo":{"type":"boolean"},"forceBufferFallback":{"type":"boolean"}}}'));
        tools.Add(MakeTool("RemoveBlocksByIndex", "Delete explicit map block indices through Editor++ deletion and return mapPre/mapPost metadata.", '{"type":"object","properties":{"index":{"type":"integer"},"indices":{"type":"array","items":{"type":"integer"}},"addUndo":{"type":"boolean"}}}'));
        tools.Add(MakeTool("RemoveItemsByIndex", "Delete explicit map item indices and return mapPre/mapPost metadata. Direct buffer fallback is opt-in and reports undoSupported=false.", '{"type":"object","properties":{"index":{"type":"integer"},"indices":{"type":"array","items":{"type":"integer"}},"addUndo":{"type":"boolean"},"forceBufferFallback":{"type":"boolean"}}}'));
        tools.Add(MakeTool("SelectBlockModel", "Set the editor selected block model by name using E++ selection helpers.", '{"type":"object","properties":{"blockName":{"type":"string"},"selection":{"type":"string"}},"required":["blockName"]}'));
        tools.Add(MakeTool("SetCursorBlock", "Alias for SelectBlockModel.", '{"type":"object","properties":{"blockName":{"type":"string"},"selection":{"type":"string"}},"required":["blockName"]}'));
        tools.Add(MakeTool("Undo", "Undo the last editor action.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("Redo", "Redo the last undone editor action.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("SetMenuPage", "Navigate the main-menu router to a route via MLHook. Useful for programmatically opening /create, /mapeditorsettings, /solo, etc. Only works while in the main-menu module; use GetMenuPage to check.", '{"type":"object","properties":{"route":{"type":"string"},"extra":{"type":"string"}},"required":["route"]}'));
        tools.Add(MakeTool("GetMenuPage", "Report current top-level game mode (Menu/Editor/Race) and whether the main-menu module is active. Does not attempt to read the specific menu route.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("ListKnownMenuRoutes", "Return a hardcoded catalogue of main-menu Router_Push routes known to work (sourced from tm-menu-page-manager).", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("ListGuides", "List available self-documentation guides. Each has a short title; call GetGuide {topic} to fetch the full body.", '{"type":"object","properties":{}}'));
        tools.Add(MakeTool("GetGuide", "Fetch the full body of a named guide. Use ListGuides to see topics.", '{"type":"object","properties":{"topic":{"type":"string"}},"required":["topic"]}'));
        tools.Add(MakeTool("EditNewMap", "Create a new map in the editor with a specific Environment + Decoration (vista). Defaults: Stadium / 48x48Day / TrackMania TM_Race. See the map-vistas guide for decoration strings. Call returns immediately; poll GetMode until mode becomes Editor.", '{"type":"object","properties":{"environment":{"type":"string"},"decoration":{"type":"string"},"mapType":{"type":"string"}}}'));
        tools.Add(MakeTool("ListMenuManialinkControls", "Walk the main-menu UI layer tree and return controls with their ControlId, classes, visibility, and path. Used to discover button IDs before firing Manialink events. maxDepth default 8; onlyWithId default true (skip anonymous frames); includeHidden default false.", '{"type":"object","properties":{"maxDepth":{"type":"integer"},"onlyWithId":{"type":"boolean"},"includeHidden":{"type":"boolean"},"maxResults":{"type":"integer"}}}'));
        return tools;
    }

    Json::Value MakeTool(const string &in name, const string &in description, const string &in inputSchemaJson) {
        Json::Value tool = Json::Object();
        tool["name"] = name;
        tool["description"] = description;
        tool["input_schema"] = Json::Parse(inputSchemaJson);
        return tool;
    }

    Json::Value@ GetMode(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        Json::Value output = Json::Object();
        if (app is null) {
            output["mode"] = "Unknown";
        } else if (app.Editor !is null) {
            output["mode"] = "Editor";
        } else if (app.CurrentPlayground !is null) {
            output["mode"] = "Race";
        } else {
            output["mode"] = "Menu";
        }
        return MakeSuccess(output);
    }

    Json::Value@ SetMenuPage(Json::Value &in input) {
#if DEPENDENCY_MLHOOK
        if (!input.HasKey("route")) return MakeError("missing route");
        string route = string(input["route"]);
        string extra = input.HasKey("extra") ? string(input["extra"]) : "{}";
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return MakeError("app not available");
        if (app.Switcher.ModuleStack.Length == 0 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) {
            return MakeError("not in menu; current module is not CTrackManiaMenus");
        }
        MLHook::Queue_Menu_SendCustomEvent("Router_Push", { route, extra, "{}" });
        Json::Value output = Json::Object();
        output["route"] = route;
        output["extra"] = extra;
        output["note"] = "Router_Push queued via MLHook; menu transition is async";
        return MakeSuccess(output);
#else
        return MakeError("MLHook dependency not compiled in");
#endif
    }

    void _EditNewMapCoroutine(string environment, string decoration, string mapType) {
        if (!Permissions::OpenAdvancedMapEditor()) {
            warn("TM Control MCP EditNewMap: missing advanced map editor permission");
            return;
        }
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null || app.ManiaTitleControlScriptAPI is null) {
            warn("TM Control MCP EditNewMap: title control API not available");
            return;
        }
        app.BackToMainMenu();
        while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
        while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
        yield();
        app.ManiaTitleControlScriptAPI.EditNewMap2(environment, decoration, "", "", mapType, false, "", "");
    }

    Json::Value@ EditNewMapTool(Json::Value &in input) {
        string environment = input.HasKey("environment") ? string(input["environment"]) : "Stadium";
        string decoration = input.HasKey("decoration") ? string(input["decoration"]) : "48x48Day";
        string mapType = input.HasKey("mapType") ? string(input["mapType"]) : "TrackMania\\TM_Race";
        startnew(function(ref@ ctx) {
            auto args = cast<array<string>>(ctx);
            _EditNewMapCoroutine(args[0], args[1], args[2]);
        }, array<string> = { environment, decoration, mapType });
        Json::Value output = Json::Object();
        output["environment"] = environment;
        output["decoration"] = decoration;
        output["mapType"] = mapType;
        output["note"] = "EditNewMap2 called asynchronously; poll GetMode until it returns Editor.";
        return MakeSuccess(output);
    }

    Json::Value@ ListKnownMenuRoutes(Json::Value &in input) {
        // Hardcoded set from tm-menu-page-manager (src/Main.as). These are confirmed
        // route strings accepted by the main-menu Router_Push event. There is no
        // public API to enumerate the router's actual route table; use this as a
        // practical starting catalogue.
        Json::Value output = Json::Object();
        Json::Value routes = Json::Array();
        string[] known = {
            "/home", "/live", "/solo", "/local", "/arcade",
            "/server-review", "/play-map", "/local-multi", "/against-replay",
            "/totdchanneldisplay", "/matchmakingmainpage",
            "/clubs", "/create", "/mapeditorsettings", "/garage",
            "/edit-replay", "/submittedmaps", "/empty"
        };
        for (uint i = 0; i < known.Length; i++) routes.Add(known[i]);
        output["routes"] = routes;
        output["note"] = "Not dynamic. Sourced from tm-menu-page-manager; some routes may reject push or require specific 'extra' payloads.";
        return MakeSuccess(output);
    }

    Json::Value@ GetMenuPage(Json::Value &in input) {
        auto app = cast<CGameManiaPlanet>(GetApp());
        Json::Value output = Json::Object();
        if (app is null) {
            output["available"] = false;
            output["reason"] = "app not available";
            return MakeSuccess(output);
        }
        output["moduleStackLen"] = int(app.Switcher.ModuleStack.Length);
        auto menus = app.Switcher.ModuleStack.Length > 0
            ? cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0])
            : null;
        output["inMenus"] = menus !is null;
        if (app.Editor !is null) output["mode"] = "Editor";
        else if (app.CurrentPlayground !is null) output["mode"] = "Race";
        else output["mode"] = "Menu";
        return MakeSuccess(output);
    }

    void OpenMapInEditorCoroutine(const string &in path) {
        if (!Permissions::OpenAdvancedMapEditor()) {
            warn("TM Control MCP OpenMapInEditor: missing advanced map editor permission");
            return;
        }

        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null || app.ManiaTitleControlScriptAPI is null) {
            warn("TM Control MCP OpenMapInEditor: title control API not available");
            return;
        }

        app.BackToMainMenu();
        while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
        while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
        yield();
        app.ManiaTitleControlScriptAPI.EditMap(path, "", "");
    }

    Json::Value@ OpenMapInEditor(Json::Value &in input) {
        if (!input.HasKey("path")) return MakeError("missing path");
        string path = string(input["path"]);
        if (path.Length == 0) return MakeError("path is empty");
        if (!Permissions::OpenAdvancedMapEditor()) return MakeError("advanced map editor permission unavailable");

        startnew(CoroutineFuncUserdataString(OpenMapInEditorCoroutine), path);

        Json::Value output = Json::Object();
        output["queued"] = true;
        output["path"] = path;
        return MakeSuccess(output);
    }

    Json::Value@ GetMapInfo(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        return MakeSuccess(MapSummary(editor));
    }

    Json::Value@ SaveMapAs(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) {
            return MakeError("editor not available");
        }

        string fileName = NormalizeMapSaveFileName(input);
        bool overwrite = input.HasKey("overwrite") ? bool(input["overwrite"]) : false;
        string gamePathHint = IO::FromUserGameFolder("Maps/" + fileName);

        Json::Value mapPre = MapSummary(editor);
        try {
            editor.PluginMapType.SaveMap(wstring(fileName));
        } catch {
            return MakeError("SaveMap failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["saved"] = true;
        output["fileName"] = fileName;
        output["mapsFileName"] = fileName;
        output["gamePathHint"] = gamePathHint;
        output["pathCheckReliable"] = false;
        output["note"] = "SaveMap returned without exception. Under Proton/Wine, IO::FromUserGameFolder may return a Wine path that Openplanet IO cannot reliably stat.";
        output["overwrite"] = overwrite;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ GetDialog(Json::Value &in input) {
        return MakeSuccess(BasicDialogSummary());
    }

    Json::Value@ RespondDialog(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.BasicDialogs is null) return MakeError("basic dialogs unavailable");
        if (!input.HasKey("action")) return MakeError("missing action");

        string action = string(input["action"]).ToLower();
        auto before = BasicDialogSummary();
        try {
            if (action == "yes") {
                app.BasicDialogs.AskYesNo_Yes();
            } else if (action == "no") {
                app.BasicDialogs.AskYesNo_No();
            } else if (action == "cancel") {
                app.BasicDialogs.AskYesNo_Cancel();
            } else if (action == "ok" || action == "message-ok") {
                app.BasicDialogs.Message_Ok();
            } else if (action == "wait-ok") {
                app.BasicDialogs.WaitMessage_Ok();
            } else if (action == "validate" || action == "saveas-validate") {
                app.BasicDialogs.DialogSaveAs_OnValidate();
            } else if (action == "saveas-cancel") {
                app.BasicDialogs.DialogSaveAs_OnCancel();
            } else if (action == "hide") {
                app.BasicDialogs.HideDialogs();
            } else {
                return MakeError("action must be one of: yes, no, cancel, ok, wait-ok, validate, saveas-cancel, hide");
            }
        } catch {
            return MakeError("dialog action failed: " + getExceptionInfo());
        }

        yield();
        Json::Value output = Json::Object();
        output["responded"] = true;
        output["action"] = action;
        output["before"] = before;
        output["after"] = BasicDialogSummary();
        return MakeSuccess(output);
    }

    Json::Value@ ControlValidation(Json::Value &in input) {
        auto editor = GetEditor();
        auto pmt = editor is null ? null : cast<CGameEditorPluginMapMapType>(editor.PluginMapType);
        if (pmt is null) return MakeError("editor map type plugin not available");

        string action = input.HasKey("action") ? string(input["action"]) : "status";
        Json::Value before = ValidationToJson(pmt);
        Json::Value actions = Json::Array();
        try {
            if (action == "status") {
                actions.Add("status");
            } else if (action == "validate") {
                pmt.Validate();
                actions.Add("validate");
            } else if (action == "requestEnterPlayground") {
                pmt.RequestEnterPlayground();
                actions.Add("requestEnterPlayground");
            } else if (action == "requestLeavePlayground") {
                pmt.RequestLeavePlayground();
                actions.Add("requestLeavePlayground");
            } else if (action == "testFromStart") {
                pmt.TestMapFromStart();
                actions.Add("testFromStart");
            } else if (action == "testFromCoord") {
                if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
                    return MakeError("testFromCoord requires x, y, z");
                }
                auto coord = int3(int(input["x"]), int(input["y"]), int(input["z"]));
                string dirName = input.HasKey("dir") ? string(input["dir"]) : "North";
                pmt.TestMapFromCoord(coord, DirFromString(dirName));
                actions.Add("testFromCoord:" + dirName);
            } else {
                return MakeError("action must be one of: status, validate, requestEnterPlayground, requestLeavePlayground, testFromStart, testFromCoord");
            }
        } catch {
            return MakeError("validation action failed: " + getExceptionInfo());
        }

        yield();
        Json::Value output = Json::Object();
        output["action"] = action;
        output["actions"] = actions;
        output["before"] = before;
        output["after"] = ValidationToJson(pmt);
        return MakeSuccess(output);
    }

    Json::Value@ ControlSelection(Json::Value &in input) {
        auto editor = GetEditor();
        auto pmt = editor is null ? null : cast<CGameEditorPluginMapMapType>(editor.PluginMapType);
        if (pmt is null) return MakeError("editor map type plugin not available");

        string action = input.HasKey("action") ? string(input["action"]) : "status";
        uint limit = input.HasKey("limit") ? uint(Math::Max(0, int(input["limit"]))) : 20;
        if (limit > 200) limit = 200;

        Json::Value before = SelectionToJson(pmt, limit);
        Json::Value actions = Json::Array();
        try {
            if (action == "status") {
                actions.Add("status");
            } else if (action == "showCustom") {
                pmt.ShowCustomSelection();
                actions.Add("showCustom");
            } else if (action == "hideCustom") {
                pmt.HideCustomSelection();
                actions.Add("hideCustom");
            } else if (action == "resetSelection") {
                pmt.CopyPaste_ResetSelection();
                actions.Add("resetSelection");
            } else if (action == "selectAll") {
                pmt.CopyPaste_SelectAll();
                actions.Add("selectAll");
            } else if (action == "addSelection") {
                if (!input.HasKey("x1") || !input.HasKey("y1") || !input.HasKey("z1")
                    || !input.HasKey("x2") || !input.HasKey("y2") || !input.HasKey("z2")) {
                    return MakeError("addSelection requires x1, y1, z1, x2, y2, z2");
                }
                auto startCoord = int3(int(input["x1"]), int(input["y1"]), int(input["z1"]));
                auto endCoord = int3(int(input["x2"]), int(input["y2"]), int(input["z2"]));
                pmt.CopyPaste_AddOrSubSelection(startCoord, endCoord);
                actions.Add("addSelection");
            } else if (action == "copy") {
                pmt.CopyPaste_Copy();
                actions.Add("copy");
            } else if (action == "cut") {
                pmt.CopyPaste_Cut();
                actions.Add("cut");
            } else if (action == "remove") {
                pmt.CopyPaste_Remove();
                actions.Add("remove");
            } else if (action == "symmetrize") {
                actions.Add(pmt.CopyPaste_Symmetrize() ? "symmetrize:true" : "symmetrize:false");
            } else {
                return MakeError("action must be one of: status, showCustom, hideCustom, resetSelection, selectAll, addSelection, copy, cut, remove, symmetrize");
            }
        } catch {
            return MakeError("selection action failed: " + getExceptionInfo());
        }

        yield();
        Json::Value output = Json::Object();
        output["action"] = action;
        output["actions"] = actions;
        output["before"] = before;
        output["after"] = SelectionToJson(pmt, limit);
        return MakeSuccess(output);
    }

    Json::Value@ GetCursor(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Cursor is null) return MakeError("editor cursor not available");
        CGameCtnBlockInfo@ blockInfo = editor.CurrentBlockInfo;
        if (blockInfo is null) @blockInfo = editor.CurrentGhostBlockInfo;

        Json::Value output = Json::Object();
        output["coord"] = CoordToJson(editor.Cursor.Coord);
        output["dir"] = int(editor.Cursor.Dir);
        if (blockInfo is null) {
            output["blockName"] = Json::Value();
            output["blockIdName"] = Json::Value();
        } else {
            output["blockName"] = blockInfo.Name;
            output["blockIdName"] = blockInfo.IdName;
        }
        return MakeSuccess(output);
    }

    Json::Value@ ControlCursor(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.PluginMapType.Cursor is null) {
            return MakeError("editor cursor API not available");
        }

        auto pmt = editor.PluginMapType;
        auto cursor = pmt.Cursor;
        string action = input.HasKey("action") ? string(input["action"]) : "status";
        int count = input.HasKey("count") ? int(input["count"]) : 1;
        if (count < 1) count = 1;
        if (count > 20) count = 20;

        Json::Value before = CursorApiToJson(pmt);
        Json::Value actions = Json::Array();
        try {
            if (action == "status") {
                actions.Add("status");
            } else if (action == "raise") {
                for (int i = 0; i < count; i++) actions.Add(cursor.Raise() ? "raise:true" : "raise:false");
            } else if (action == "lower") {
                for (int i = 0; i < count; i++) actions.Add(cursor.Lower() ? "lower:true" : "lower:false");
            } else if (action == "rotate") {
                bool clockwise = input.HasKey("clockwise") ? bool(input["clockwise"]) : true;
                for (int i = 0; i < count; i++) {
                    cursor.Rotate(clockwise);
                    actions.Add(clockwise ? "rotate:clockwise" : "rotate:counterclockwise");
                }
            } else if (action == "move") {
                string dir = input.HasKey("direction") ? string(input["direction"]) : "Forward";
                string kind = input.HasKey("directionKind") ? string(input["directionKind"]) : "relative";
                for (int i = 0; i < count; i++) {
                    if (kind == "cardinal") {
                        cursor.Move(DirFromString(dir));
                    } else if (kind == "cardinal8") {
                        cursor.Move(Dir8FromString(dir));
                    } else {
                        cursor.Move(RelativeDirFromString(dir));
                    }
                    actions.Add("move:" + kind + ":" + dir);
                }
            } else if (action == "moveToCameraTarget") {
                cursor.MoveToCameraTarget();
                actions.Add("moveToCameraTarget");
            } else if (action == "followCamera") {
                bool follow = input.HasKey("follow") ? bool(input["follow"]) : true;
                cursor.FollowCameraTarget(follow);
                actions.Add(follow ? "followCamera:true" : "followCamera:false");
            } else if (action == "disableMouseDetection") {
                bool disable = input.HasKey("disable") ? bool(input["disable"]) : true;
                cursor.DisableMouseDetection(disable);
                actions.Add(disable ? "disableMouseDetection:true" : "disableMouseDetection:false");
            } else if (action == "releaseLock") {
                cursor.ReleaseLock();
                actions.Add("releaseLock");
            } else if (action == "resetRGB") {
                cursor.ResetCustomRGB();
                actions.Add("resetRGB");
            } else if (action == "setRGB") {
                cursor.SetCustomRGB(vec3(
                    InputFloatOr(input, "r", 1.0),
                    InputFloatOr(input, "g", 1.0),
                    InputFloatOr(input, "b", 1.0)
                ));
                actions.Add("setRGB");
            } else {
                return MakeError("action must be one of: status, raise, lower, rotate, move, moveToCameraTarget, followCamera, disableMouseDetection, releaseLock, resetRGB, setRGB");
            }
        } catch {
            return MakeError("cursor action failed: " + getExceptionInfo());
        }

        yield();
        Json::Value output = Json::Object();
        output["action"] = action;
        output["count"] = count;
        output["actions"] = actions;
        output["before"] = before;
        output["after"] = CursorApiToJson(pmt);
        return MakeSuccess(output);
    }

    Json::Value@ GetEditorCamera(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        return MakeSuccess(CameraToJson(editor));
    }

    Json::Value@ SetEditorCamera(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        bool hasTarget = input.HasKey("x") && input.HasKey("y") && input.HasKey("z");
        bool hasDistance = input.HasKey("distance");
        bool hasH = input.HasKey("hAngle") || input.HasKey("hAngleRad");
        bool hasV = input.HasKey("vAngle") || input.HasKey("vAngleRad");

        if (!hasTarget && !hasDistance && !hasH && !hasV) {
            return MakeError("missing camera fields: pass target x/y/z, hAngle/vAngle, or distance");
        }

        auto pmt = editor.PluginMapType;
        vec3 target = hasTarget ? PositionInput(input) : pmt.CameraTargetPosition;
        float distance = hasDistance ? float(input["distance"]) : pmt.CameraToTargetDistance;
        float h = hasH ? AngleInputRad(input, "hAngle", "hAngleRad", Math::ToDeg(pmt.CameraHAngle)) : pmt.CameraHAngle;
        float v = hasV ? AngleInputRad(input, "vAngle", "vAngleRad", Math::ToDeg(pmt.CameraVAngle)) : pmt.CameraVAngle;
        bool animate = input.HasKey("animate") ? bool(input["animate"]) : false;

        bool animated = false;
        if (animate) {
            animated = Editor::SetCamAnimationGoTo(vec2(h, v), target, distance);
        } else {
            pmt.CameraTargetPosition = target;
            pmt.CameraToTargetDistance = distance;
            pmt.CameraHAngle = h;
            pmt.CameraVAngle = v;
            if (editor.OrbitalCameraControl !is null) {
                editor.OrbitalCameraControl.m_TargetedPosition = target;
                editor.OrbitalCameraControl.m_CameraToTargetDistance = distance;
            }
        }

        Json::Value output = CameraToJson(editor);
        output["animated"] = animated;
        output["animateRequested"] = animate;
        return MakeSuccess(output);
    }

    Json::Value@ ControlCamera(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.PluginMapType.Camera is null) {
            return MakeError("editor camera API not available");
        }

        auto pmt = editor.PluginMapType;
        auto camera = pmt.Camera;
        string action = input.HasKey("action") ? string(input["action"]) : "status";
        bool smooth = input.HasKey("smooth") ? bool(input["smooth"]) : true;

        Json::Value before = CameraToJson(editor);
        before["api"] = CameraApiToJson(pmt);
        Json::Value actions = Json::Array();
        try {
            if (action == "status") {
                actions.Add("status");
            } else if (action == "centerOnCursor") {
                camera.CenterOnCursor(smooth);
                actions.Add("centerOnCursor");
            } else if (action == "moveToMapCenter") {
                camera.MoveToMapCenter(smooth);
                actions.Add("moveToMapCenter");
            } else if (action == "watchWholeMap") {
                camera.WatchWholeMap(smooth);
                actions.Add("watchWholeMap");
            } else if (action == "watchStart") {
                camera.WatchStart(smooth);
                actions.Add("watchStart");
            } else if (action == "watchClosestFinishLine") {
                camera.WatchClosestFinishLine(smooth);
                actions.Add("watchClosestFinishLine");
            } else if (action == "watchClosestCheckpoint") {
                camera.WatchClosestCheckpoint(smooth);
                actions.Add("watchClosestCheckpoint");
            } else if (action == "zoom") {
                string level = input.HasKey("level") ? string(input["level"]) : "Medium";
                camera.Zoom(ZoomLevelFromString(level), smooth);
                actions.Add("zoom:" + level);
            } else if (action == "zoomIn") {
                bool loop = input.HasKey("loop") ? bool(input["loop"]) : false;
                camera.ZoomIn(loop, smooth);
                actions.Add(loop ? "zoomIn:loop" : "zoomIn");
            } else if (action == "zoomOut") {
                bool loop = input.HasKey("loop") ? bool(input["loop"]) : false;
                camera.ZoomOut(loop, smooth);
                actions.Add(loop ? "zoomOut:loop" : "zoomOut");
            } else if (action == "look") {
                string dir = input.HasKey("direction") ? string(input["direction"]) : "North";
                string kind = input.HasKey("directionKind") ? string(input["directionKind"]) : "cardinal";
                if (kind == "cardinal8") {
                    camera.Look(Dir8FromString(dir), smooth);
                } else {
                    camera.Look(DirFromString(dir), smooth);
                }
                actions.Add("look:" + kind + ":" + dir);
            } else if (action == "followCursor") {
                bool follow = input.HasKey("follow") ? bool(input["follow"]) : true;
                camera.FollowCursor(follow);
                actions.Add(follow ? "followCursor:true" : "followCursor:false");
            } else if (action == "ignoreCollisions") {
                bool ignore = input.HasKey("ignore") ? bool(input["ignore"]) : true;
                camera.IgnoreCameraCollisions(ignore);
                actions.Add(ignore ? "ignoreCollisions:true" : "ignoreCollisions:false");
            } else if (action == "releaseLock") {
                camera.ReleaseLock();
                actions.Add("releaseLock");
            } else if (action == "setVStep") {
                string step = input.HasKey("step") ? string(input["step"]) : "Medium";
                camera.SetVStep(CameraVStepFromString(step));
                actions.Add("setVStep:" + step);
            } else {
                return MakeError("action must be one of: status, centerOnCursor, moveToMapCenter, watchWholeMap, watchStart, watchClosestFinishLine, watchClosestCheckpoint, zoom, zoomIn, zoomOut, look, followCursor, ignoreCollisions, releaseLock, setVStep");
            }
        } catch {
            return MakeError("camera action failed: " + getExceptionInfo());
        }

        yield();
        Json::Value after = CameraToJson(editor);
        after["api"] = CameraApiToJson(pmt);

        Json::Value output = Json::Object();
        output["action"] = action;
        output["smooth"] = smooth;
        output["actions"] = actions;
        output["before"] = before;
        output["after"] = after;
        return MakeSuccess(output);
    }

    Json::Value@ FocusCamera(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) return MakeError("missing x, y, z");
        vec3 target = PositionInput(input);
        float distance = input.HasKey("distance") ? float(input["distance"]) : 60.0;
        bool focused = FocusCameraOn(target, distance);

        Json::Value output = CameraToJson(editor);
        output["focused"] = focused;
        output["target"] = Vec3ToJson(target);
        output["distance"] = distance;
        return MakeSuccess(output);
    }

    Json::Value@ TakeScreenshot(Json::Value &in input) {
        auto app = GetApp();
        if (app is null || app.Viewport is null) return MakeError("viewport not available");

        string format = input.HasKey("format") ? string(input["format"]).ToLower() : "jpg";
        if (format == "jpeg") format = "jpg";

        try {
            if (format == "webp") {
                app.Viewport.ScreenShotDoCaptureWebp();
            } else if (format == "tga") {
                app.Viewport.ScreenShotDoCaptureTga();
            } else if (format == "dds") {
                app.Viewport.ScreenShotDoCaptureDDS();
            } else {
                format = "jpg";
                app.Viewport.ScreenShotDoCaptureJpg();
            }
        } catch {
            return MakeError("screenshot capture failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["requested"] = true;
        output["format"] = format;
        output["extension"] = ScreenshotExtForFormat(format);
        output["gameFolder"] = IO::FromUserGameFolder("");
        output["folder"] = IO::FromUserGameFolder("ScreenShots");
        output["defaultPattern"] = "ScreenShot*" + ScreenshotExtForFormat(format);
        output["note"] = "Capture is asynchronous. Trackmania usually writes viewport captures as ScreenShotNN.jpg in the user game folder, not the ScreenShots subfolder.";
        return MakeSuccess(output);
    }

    Json::Value@ GetBlocks(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        bool hasCenter = input.HasKey("x") && input.HasKey("y") && input.HasKey("z");
        bool world = input.HasKey("world") ? bool(input["world"]) : false;
        float radius = input.HasKey("radius") ? float(input["radius"]) : (world ? 50.0 : 10.0);
        int limit = input.HasKey("limit") ? int(input["limit"]) : 100;
        if (limit < 1) limit = 1;
        if (limit > 1000) limit = 1000;
        string query = input.HasKey("query") ? string(input["query"]).ToLower() : "";
        bool filterFree = input.HasKey("isFree");
        bool wantFree = filterFree ? bool(input["isFree"]) : false;
        nat3 coordCenter = hasCenter ? nat3(uint(input["x"]), uint(input["y"]), uint(input["z"])) : nat3();
        vec3 worldCenter = hasCenter ? PositionInput(input) : vec3();

        Json::Value blocks = Json::Array();
        for (uint i = 0; i < editor.Challenge.Blocks.Length; i++) {
            auto block = editor.Challenge.Blocks[i];
            if (block is null) continue;
            if (query.Length > 0 && !ModelMatchesQuery(block.BlockInfo, query)) continue;

            bool isFree = Editor::IsBlockFree(block);
            if (filterFree && isFree != wantFree) continue;

            if (hasCenter) {
                if (world) {
                    if ((Editor::GetBlockLocation(block) - worldCenter).Length() > radius) continue;
                } else if (float(Nat3Distance(block.Coord, coordCenter)) > radius) {
                    continue;
                }
            }

            auto obj = BlockToJson(block);
            obj["index"] = int(i);
            blocks.Add(obj);
            if (int(blocks.Length) >= limit) break;
        }

        Json::Value output = Json::Object();
        output["blocks"] = blocks;
        output["count"] = int(blocks.Length);
        output["total"] = int(editor.Challenge.Blocks.Length);
        output["filtered"] = query.Length > 0 || filterFree || hasCenter;
        output["world"] = world;
        if (hasCenter) {
            if (world) output["center"] = Vec3ToJson(worldCenter);
            else output["center"] = CoordToJson(coordCenter);
        } else {
            output["center"] = Json::Value();
        }
        output["query"] = query;
        output["isFree"] = filterFree ? Json::Value(wantFree) : Json::Value();
        output["limit"] = limit;
        output["radius"] = radius;
        return MakeSuccess(output);
    }

    Json::Value@ GetRecentBlocks(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        int count = input.HasKey("count") ? int(input["count"]) : 10;
        if (count < 1) count = 1;
        if (count > 100) count = 100;

        Json::Value blocks = Json::Array();
        int total = int(editor.Challenge.Blocks.Length);
        int start = Math::Max(0, total - count);
        for (int i = start; i < total; i++) {
            auto block = editor.Challenge.Blocks[i];
            auto obj = BlockToJson(block);
            obj["index"] = i;
            blocks.Add(obj);
        }

        Json::Value output = Json::Object();
        output["blocks"] = blocks;
        output["count"] = int(blocks.Length);
        output["total"] = total;
        return MakeSuccess(output);
    }

    Json::Value@ GetBlockAt(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) return MakeError("missing x, y, z");
        auto coord = int3(int(input["x"]), int(input["y"]), int(input["z"]));
        auto block = editor.PluginMapType.GetBlock(coord);
        Json::Value output = Json::Object();
        output["found"] = block !is null;
        output["block"] = BlockToJson(block);
        return MakeSuccess(output);
    }

    Json::Value@ GetItems(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        bool hasCenter = input.HasKey("x") && input.HasKey("y") && input.HasKey("z");
        vec3 center = hasCenter ? PositionInput(input) : vec3();
        float radius = input.HasKey("radius") ? float(input["radius"]) : 50.0;
        int limit = input.HasKey("limit") ? int(input["limit"]) : 100;
        if (limit < 1) limit = 1;
        if (limit > 500) limit = 500;
        float radiusSq = radius * radius;

        Json::Value items = Json::Array();
        for (uint i = 0; i < editor.Challenge.AnchoredObjects.Length && items.Length < uint(limit); i++) {
            auto item = editor.Challenge.AnchoredObjects[i];
            if (item is null) continue;
            if (hasCenter && (item.AbsolutePositionInMap - center).LengthSquared() > radiusSq) continue;
            auto obj = ItemToJson(item);
            obj["index"] = int(i);
            items.Add(obj);
        }

        Json::Value output = Json::Object();
        output["items"] = items;
        output["count"] = int(items.Length);
        output["total"] = int(editor.Challenge.AnchoredObjects.Length);
        output["hasCenter"] = hasCenter;
        if (hasCenter) {
            output["center"] = Vec3ToJson(center);
            output["radius"] = radius;
        }
        output["limit"] = limit;
        return MakeSuccess(output);
    }

    Json::Value@ GetRecentItems(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        int count = input.HasKey("count") ? int(input["count"]) : 10;
        if (count < 1) count = 1;
        if (count > 100) count = 100;

        Json::Value items = Json::Array();
        int total = int(editor.Challenge.AnchoredObjects.Length);
        int start = Math::Max(0, total - count);
        for (int i = start; i < total; i++) {
            auto item = editor.Challenge.AnchoredObjects[i];
            auto obj = ItemToJson(item);
            obj["index"] = i;
            items.Add(obj);
        }

        Json::Value output = Json::Object();
        output["items"] = items;
        output["count"] = int(items.Length);
        output["total"] = total;
        return MakeSuccess(output);
    }

    Json::Value@ FindBlockModels(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        string query = input.HasKey("query") ? string(input["query"]).ToLower() : "";
        int limit = input.HasKey("limit") ? int(input["limit"]) : 25;
        if (limit < 1) limit = 1;
        if (limit > 100) limit = 100;
        bool includeTerrain = input.HasKey("includeTerrain") ? bool(input["includeTerrain"]) : true;
        bool terrainOnly = input.HasKey("terrainOnly") ? bool(input["terrainOnly"]) : false;

        Json::Value models = Json::Array();
        if (!terrainOnly) {
            for (uint i = 0; i < editor.PluginMapType.BlockModels.Length && models.Length < uint(limit); i++) {
                auto blockInfo = editor.PluginMapType.BlockModels[i];
                if (ModelMatchesQuery(blockInfo, query)) models.Add(ModelToJson(blockInfo, false));
            }
        }
        if (includeTerrain) {
            for (uint i = 0; i < editor.PluginMapType.TerrainBlockModels.Length && models.Length < uint(limit); i++) {
                auto blockInfo = editor.PluginMapType.TerrainBlockModels[i];
                if (ModelMatchesQuery(blockInfo, query)) models.Add(ModelToJson(blockInfo, true));
            }
        }

        Json::Value output = Json::Object();
        output["models"] = models;
        output["count"] = int(models.Length);
        output["query"] = query;
        return MakeSuccess(output);
    }

    Json::Value@ GetInventorySummary(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        return MakeSuccess(InventorySummary(editor.PluginMapType));
    }

    Json::Value@ FindInventory(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        string query = input.HasKey("query") ? string(input["query"]).ToLower() : "";
        string requestedType = input.HasKey("type") ? string(input["type"]).ToLower() : "all";
        int limit = input.HasKey("limit") ? int(input["limit"]) : 25;
        if (limit < 1) limit = 1;
        if (limit > 200) limit = 200;

        Json::Value results = Json::Array();
        if (InventoryTypeEnabled(requestedType, "block")) {
            for (uint i = 0; i < editor.PluginMapType.BlockModels.Length && results.Length < uint(limit); i++) {
                auto blockInfo = editor.PluginMapType.BlockModels[i];
                if (!ModelMatchesQuery(blockInfo, query)) continue;
                auto entry = ModelToJson(blockInfo, false);
                entry["type"] = "block";
                results.Add(entry);
            }
        }
        if (InventoryTypeEnabled(requestedType, "item")) {
            uint nbItems = Editor::GetInventoryNbItems();
            for (uint i = 0; i < nbItems && results.Length < uint(limit); i++) {
                string path = Editor::GetInventoryItemPath(i);
                string name = Editor::GetInventoryItemName(i);
                if (!TextMatchesQuery(path, query) && !TextMatchesQuery(name, query)) continue;
                Json::Value entry = Json::Object();
                entry["type"] = "item";
                entry["name"] = name;
                entry["path"] = path;
                results.Add(entry);
            }
        }
        if (InventoryTypeEnabled(requestedType, "macroblock")) {
            for (uint i = 0; i < editor.PluginMapType.MacroblockModels.Length && results.Length < uint(limit); i++) {
                auto macroblockInfo = editor.PluginMapType.MacroblockModels[i];
                if (macroblockInfo is null) continue;
                string name = string(macroblockInfo.Name);
                string idName = string(macroblockInfo.IdName);
                if (!TextMatchesQuery(name, query) && !TextMatchesQuery(idName, query)) continue;
                results.Add(MacroblockModelToJson(macroblockInfo));
            }
        }

        Json::Value output = Json::Object();
        output["results"] = results;
        output["count"] = int(results.Length);
        output["query"] = query;
        output["type"] = requestedType;
        output["inventory"] = InventorySummary(editor.PluginMapType);
        return MakeSuccess(output);
    }

    Json::Value@ RefreshInventory(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        uint preCount = Editor::GetInventoryNbItems();
        Editor::RefreshInventoryCache();
        Json::Value output = Json::Object();
        output["nbItemsBefore"] = int(preCount);
        output["isScanningItems"] = Editor::IsInventoryScanningItems();
        output["note"] = "rescan started; poll GetInventorySummary until isScanningItems=false, then re-query";
        return MakeSuccess(output);
    }

    Json::Value@ CreateNamedMacroblock(Json::Value &in input) {
        if (!input.HasKey("name")) return MakeError("missing name");
        string name = string(input["name"]);
        if (name.Length == 0) return MakeError("name is empty");
        bool replace = input.HasKey("replace") ? bool(input["replace"]) : false;
        int index = FindNamedMacroblockIndex(name);
        if (index >= 0 && !replace) return MakeError("named macroblock already exists: " + name);

        auto mb = Editor::MakeMacroblockSpec();
        if (index >= 0) {
            @g_NamedMacroblocks[index] = mb;
            @g_NamedMacroblockSkins[index] = NewNamedMacroblockSkinList();
        } else {
            g_NamedMacroblockNames.InsertLast(name);
            g_NamedMacroblocks.InsertLast(mb);
            g_NamedMacroblockSkins.InsertLast(NewNamedMacroblockSkinList());
        }
        return MakeSuccess(NamedMacroblockSummary(name, mb));
    }

    Json::Value@ ListNamedMacroblocks(Json::Value &in input) {
        Json::Value entries = Json::Array();
        for (uint i = 0; i < g_NamedMacroblockNames.Length; i++) {
            entries.Add(NamedMacroblockSummary(g_NamedMacroblockNames[i], g_NamedMacroblocks[i]));
        }

        Json::Value output = Json::Object();
        output["macroblocks"] = entries;
        output["count"] = int(entries.Length);
        return MakeSuccess(output);
    }

    Json::Value@ GetNamedMacroblockTool(Json::Value &in input) {
        if (!input.HasKey("name")) return MakeError("missing name");
        string name = string(input["name"]);
        auto mb = GetNamedMacroblock(name);
        if (mb is null) return MakeError("named macroblock not found: " + name);

        int limit = input.HasKey("limit") ? int(input["limit"]) : 100;
        if (limit < 1) limit = 1;
        if (limit > 500) limit = 500;
        bool includeItems = input.HasKey("includeItems") ? bool(input["includeItems"]) : true;

        Json::Value blocks = Json::Array();
        for (uint i = 0; i < mb.blocks.Length && blocks.Length < uint(limit); i++) {
            auto obj = BlockSpecToJson(mb.blocks[i]);
            obj["index"] = int(i);
            blocks.Add(obj);
        }

        Json::Value items = Json::Array();
        if (includeItems) {
            for (uint i = 0; i < mb.items.Length && items.Length < uint(limit); i++) {
                auto obj = ItemSpecToJson(mb.items[i]);
                obj["index"] = int(i);
                items.Add(obj);
            }
        }

        Json::Value output = NamedMacroblockSummary(name, mb);
        output["blocks"] = blocks;
        output["items"] = items;
        output["postSkins"] = NamedMacroblockSkinsToJson(GetNamedMacroblockSkins(name), limit);
        output["limit"] = limit;
        output["includeItems"] = includeItems;
        return MakeSuccess(output);
    }

    Json::Value@ ClearNamedMacroblock(Json::Value &in input) {
        bool clearAll = input.HasKey("all") ? bool(input["all"]) : false;
        if (clearAll) {
            int count = int(g_NamedMacroblockNames.Length);
            g_NamedMacroblockNames.RemoveRange(0, g_NamedMacroblockNames.Length);
            g_NamedMacroblocks.RemoveRange(0, g_NamedMacroblocks.Length);
            g_NamedMacroblockSkins.RemoveRange(0, g_NamedMacroblockSkins.Length);
            Json::Value output = Json::Object();
            output["clearedAll"] = true;
            output["count"] = count;
            return MakeSuccess(output);
        }

        if (!input.HasKey("name")) return MakeError("missing name or all=true");
        string name = string(input["name"]);
        int index = FindNamedMacroblockIndex(name);
        if (index < 0) return MakeError("named macroblock not found: " + name);
        g_NamedMacroblockNames.RemoveAt(index);
        g_NamedMacroblocks.RemoveAt(index);
        g_NamedMacroblockSkins.RemoveAt(index);

        Json::Value output = Json::Object();
        output["cleared"] = true;
        output["name"] = name;
        return MakeSuccess(output);
    }

    Json::Value@ AddBlockToNamedMacroblock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("name") || !input.HasKey("blockName") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing name, blockName, x, y, z");
        }

        string name = string(input["name"]);
        string blockName = string(input["blockName"]);
        bool create = input.HasKey("create") ? bool(input["create"]) : true;
        auto mb = GetNamedMacroblock(name);
        if (mb is null && create) {
            @mb = Editor::MakeMacroblockSpec();
            g_NamedMacroblockNames.InsertLast(name);
            g_NamedMacroblocks.InsertLast(mb);
            g_NamedMacroblockSkins.InsertLast(NewNamedMacroblockSkinList());
        }
        if (mb is null) return MakeError("named macroblock not found: " + name);

        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);
        if (isTerrain) return MakeError("terrain models are not supported in named freeblock macroblocks");

        vec3 pos = PositionInput(input);
        vec3 rot = RotationInput(input);
        auto spec = Editor::MakeBlockSpec(blockInfo, pos, rot);
        spec.SetFree();
        spec.isGround = false;
        spec.isGhost = false;
        spec.variant = input.HasKey("variant") ? uint(input["variant"]) : 0;
        bool variantOk = spec.EnsureValidVariant();
        uint blockIndex = mb.blocks.Length;
        mb.blocks.InsertLast(spec);
        string fgSkin = input.HasKey("fgSkin") ? string(input["fgSkin"]) : "";
        string bgSkin = input.HasKey("bgSkin") ? string(input["bgSkin"]) : "";
        if (!input.HasKey("fgSkin") && input.HasKey("skin")) fgSkin = string(input["skin"]);
        AddPostSkinToNamedMacroblock(name, blockIndex, fgSkin, bgSkin);

        Json::Value output = NamedMacroblockSummary(name, mb);
        output["added"] = true;
        output["blockIndex"] = int(blockIndex);
        output["variantOk"] = variantOk;
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["pos"] = Vec3ToJson(pos);
        output["rot"] = Vec3ToJson(rot);
        output["rotDeg"] = Vec3DegToJson(rot);
        output["fgSkin"] = fgSkin;
        output["bgSkin"] = bgSkin;
        return MakeSuccess(output);
    }

    Json::Value@ AddBlocksToNamedMacroblock(Json::Value &in input) {
        if (!input.HasKey("name") || !input.HasKey("blocks")) return MakeError("missing name or blocks");
        auto blocks = input["blocks"];
        if (blocks.GetType() != Json::Type::Array) return MakeError("blocks must be an array");
        string name = string(input["name"]);
        bool create = input.HasKey("create") ? bool(input["create"]) : true;
        bool continueOnError = input.HasKey("continueOnError") ? bool(input["continueOnError"]) : false;

        Json::Value errors = Json::Array();
        int added = 0;
        for (uint i = 0; i < blocks.Length; i++) {
            Json::Value block = blocks[i];
            block["name"] = name;
            block["create"] = create;
            auto result = AddBlockToNamedMacroblock(block);
            if (bool(result["success"])) {
                added++;
                continue;
            }
            Json::Value err = Json::Object();
            err["index"] = int(i);
            err["error"] = string(result["error"]);
            errors.Add(err);
            if (!continueOnError) break;
        }

        auto mb = GetNamedMacroblock(name);
        Json::Value output = mb is null ? Json::Object() : NamedMacroblockSummary(name, mb);
        output["requested"] = int(blocks.Length);
        output["added"] = added;
        output["errors"] = errors;
        output["ok"] = errors.Length == 0;
        return MakeSuccess(output);
    }

    Json::Value@ AddItemToNamedMacroblock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("name") || !input.HasKey("itemPath") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing name, itemPath, x, y, z");
        }

        string name = string(input["name"]);
        string itemPath = string(input["itemPath"]);
        bool create = input.HasKey("create") ? bool(input["create"]) : true;
        auto mb = GetNamedMacroblock(name);
        if (mb is null && create) {
            @mb = Editor::MakeMacroblockSpec();
            g_NamedMacroblockNames.InsertLast(name);
            g_NamedMacroblocks.InsertLast(mb);
            g_NamedMacroblockSkins.InsertLast(NewNamedMacroblockSkinList());
        }
        if (mb is null) return MakeError("named macroblock not found: " + name);

        auto itemModel = ResolveItemModel(itemPath);
        if (itemModel is null) return MakeError("item not found: " + itemPath);

        vec3 pos = PositionInput(input);
        vec3 rot = RotationInput(input);
        auto spec = Editor::MakeItemSpec(itemModel, pos, rot);
        spec.isFlying = 1;
        spec.variantIx = input.HasKey("variant") ? uint16(input["variant"]) : 0;
        uint itemIndex = mb.items.Length;
        mb.items.InsertLast(spec);
        string fgSkin = input.HasKey("fgSkin") ? string(input["fgSkin"]) : "";
        string bgSkin = input.HasKey("bgSkin") ? string(input["bgSkin"]) : "";
        if (!input.HasKey("fgSkin") && input.HasKey("skin")) bgSkin = string(input["skin"]);
        AddPostItemSkinToNamedMacroblock(name, itemIndex, fgSkin, bgSkin);

        Json::Value output = NamedMacroblockSummary(name, mb);
        output["added"] = true;
        output["itemIndex"] = int(itemIndex);
        output["itemPath"] = itemPath;
        output["model"] = ItemModelToJson(itemModel, itemPath);
        output["pos"] = Vec3ToJson(pos);
        output["rot"] = Vec3ToJson(rot);
        output["rotDeg"] = Vec3DegToJson(rot);
        output["variant"] = int(spec.variantIx);
        output["fgSkin"] = fgSkin;
        output["bgSkin"] = bgSkin;
        return MakeSuccess(output);
    }

    Json::Value@ AddItemsToNamedMacroblock(Json::Value &in input) {
        if (!input.HasKey("name") || !input.HasKey("items")) return MakeError("missing name or items");
        auto items = input["items"];
        if (items.GetType() != Json::Type::Array) return MakeError("items must be an array");
        string name = string(input["name"]);
        bool create = input.HasKey("create") ? bool(input["create"]) : true;
        bool continueOnError = input.HasKey("continueOnError") ? bool(input["continueOnError"]) : false;

        Json::Value errors = Json::Array();
        int added = 0;
        for (uint i = 0; i < items.Length; i++) {
            Json::Value item = items[i];
            item["name"] = name;
            item["create"] = create;
            auto result = AddItemToNamedMacroblock(item);
            if (bool(result["success"])) {
                added++;
                continue;
            }
            Json::Value err = Json::Object();
            err["index"] = int(i);
            err["error"] = string(result["error"]);
            errors.Add(err);
            if (!continueOnError) break;
        }

        auto mb = GetNamedMacroblock(name);
        Json::Value output = mb is null ? Json::Object() : NamedMacroblockSummary(name, mb);
        output["requested"] = int(items.Length);
        output["added"] = added;
        output["errors"] = errors;
        output["ok"] = errors.Length == 0;
        return MakeSuccess(output);
    }

    Json::Value@ PlaceNamedMacroblock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("name")) return MakeError("missing name");
        string name = string(input["name"]);
        auto mb = GetNamedMacroblock(name);
        if (mb is null) return MakeError("named macroblock not found: " + name);
        if (mb.blocks.Length == 0 && mb.items.Length == 0) return MakeError("named macroblock is empty: " + name);

        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        bool autofocus = input.HasKey("autofocus") ? bool(input["autofocus"]) : true;
        vec3 offset = OptionalOffsetInput(input);
        vec3 rotation = RotationInput(input);
        vec3 pivot = PivotInput(input);
        bool transformed = HasTransformInput(input);
        auto placedMb = transformed
            ? DuplicateAndTransformMacroblock(mb, offset, rotation, pivot)
            : mb.Duplicate();

        Json::Value mapPre = MapSummary(editor);
        int blockBaseIndex = int(editor.Challenge.Blocks.Length);
        int itemBaseIndex = int(editor.Challenge.AnchoredObjects.Length);
        bool placed = false;
        string error = "";
        try {
            placed = Editor::PlaceMacroblock(placedMb, addUndo);
        } catch {
            error = getExceptionInfo();
        }

        Json::Value skinApplication = Json::Object();
        skinApplication["requested"] = 0;
        bool skinsApplied = false;
        string skinError = "";
        auto postSkins = GetNamedMacroblockSkins(name);
        int skinsRequested = postSkins is null ? 0 : int(postSkins.Length);
        if (placed && skinsRequested > 0) {
            try {
                skinApplication = ApplyNamedMacroblockSkinsDirect(editor.PluginMapType, name, blockBaseIndex, itemBaseIndex);
                skinsApplied = bool(skinApplication["ok"]);
                for (uint i = 0; i < 5; i++) yield();
            } catch {
                skinError = getExceptionInfo();
            }
        }

        Json::Value output = NamedMacroblockSummary(name, mb);
        output["placed"] = placed;
        output["skinsRequested"] = skinsRequested;
        output["skinsApplied"] = skinsApplied;
        output["skinApplication"] = skinApplication;
        output["addUndo"] = addUndo;
        output["transformed"] = transformed;
        output["offset"] = Vec3ToJson(offset);
        output["rot"] = Vec3ToJson(rotation);
        output["rotDeg"] = Vec3DegToJson(rotation);
        output["pivot"] = Vec3ToJson(pivot);
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        if (error.Length > 0) output["error"] = error;
        if (skinError.Length > 0) output["skinError"] = skinError;
        output["autofocus"] = false;
        if (placed && autofocus && (placedMb.blocks.Length > 0 || placedMb.items.Length > 0)) {
            vec3 bMin = vec3(1e18, 1e18, 1e18);
            vec3 bMax = vec3(-1e18, -1e18, -1e18);
            for (uint i = 0; i < placedMb.blocks.Length; i++) {
                vec3 p = placedMb.blocks[i].pos;
                bMin = vec3(Math::Min(bMin.x, p.x), Math::Min(bMin.y, p.y), Math::Min(bMin.z, p.z));
                bMax = vec3(Math::Max(bMax.x, p.x), Math::Max(bMax.y, p.y), Math::Max(bMax.z, p.z));
            }
            for (uint i = 0; i < placedMb.items.Length; i++) {
                vec3 p = placedMb.items[i].pos;
                bMin = vec3(Math::Min(bMin.x, p.x), Math::Min(bMin.y, p.y), Math::Min(bMin.z, p.z));
                bMax = vec3(Math::Max(bMax.x, p.x), Math::Max(bMax.y, p.y), Math::Max(bMax.z, p.z));
            }
            vec3 center = (bMin + bMax) * 0.5 - MacroblockInternalOffset();
            vec3 diag = bMax - bMin;
            float diagonal = Math::Sqrt(diag.x * diag.x + diag.y * diag.y + diag.z * diag.z);
            float autofocusDistance = input.HasKey("autofocusDistance") ? float(input["autofocusDistance"]) : Math::Max(60.0, diagonal * 2.0);
            output["autofocus"] = AutofocusCameraOn(center, autofocusDistance);
            output["autofocusTarget"] = Vec3ToJson(center);
            output["autofocusDistance"] = autofocusDistance;
        }
        return MakeSuccess(output);
    }

    Json::Value@ PlaceBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("blockName") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing blockName, x, y, z");
        }

        string blockName = string(input["blockName"]);
        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);

        string dirName = input.HasKey("dir") ? string(input["dir"]) : "North";
        auto coord = int3(int(input["x"]), int(input["y"]), int(input["z"]));
        bool allowDestruction = input.HasKey("allowDestruction") ? bool(input["allowDestruction"]) : false;
        auto dir = DirFromString(dirName);
        Json::Value mapPre = MapSummary(editor);
        bool canPlace = isTerrain
            ? editor.PluginMapType.CanPlaceTerrainBlocks(blockInfo, coord, coord)
            : (
                allowDestruction
                    ? editor.PluginMapType.CanPlaceBlock(blockInfo, coord, dir, false, 0)
                    : editor.PluginMapType.CanPlaceBlock_NoDestruction(blockInfo, coord, dir, false, 0)
            );
        bool placed = canPlace && (
            isTerrain
                ? (
                    allowDestruction
                        ? editor.PluginMapType.PlaceTerrainBlocks(blockInfo, coord, coord)
                        : editor.PluginMapType.PlaceTerrainBlocks_NoDestruction(blockInfo, coord, coord)
                )
                : (
                    allowDestruction
                        ? editor.PluginMapType.PlaceBlock(blockInfo, coord, dir)
                        : editor.PluginMapType.PlaceBlock_NoDestruction(blockInfo, coord, dir)
                )
        );

        Json::Value output = Json::Object();
        output["placed"] = placed;
        output["canPlace"] = canPlace;
        output["allowDestruction"] = allowDestruction;
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["isTerrain"] = isTerrain;
        output["coord"] = Int3ToJson(coord);
        output["dir"] = dirName;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ CanPlaceBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("blockName") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing blockName, x, y, z");
        }

        string blockName = string(input["blockName"]);
        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);

        string dirName = input.HasKey("dir") ? string(input["dir"]) : "North";
        auto coord = int3(int(input["x"]), int(input["y"]), int(input["z"]));
        bool allowDestruction = input.HasKey("allowDestruction") ? bool(input["allowDestruction"]) : false;
        auto dir = DirFromString(dirName);
        bool canPlace = false;
        try {
            canPlace = isTerrain
                ? editor.PluginMapType.CanPlaceTerrainBlocks(blockInfo, coord, coord)
                : (
                    allowDestruction
                        ? editor.PluginMapType.CanPlaceBlock(blockInfo, coord, dir, false, 0)
                        : editor.PluginMapType.CanPlaceBlock_NoDestruction(blockInfo, coord, dir, false, 0)
                );
        } catch {
            return MakeError("CanPlaceBlock failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["canPlace"] = canPlace;
        output["allowDestruction"] = allowDestruction;
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["isTerrain"] = isTerrain;
        output["coord"] = Int3ToJson(coord);
        output["dir"] = dirName;
        output["map"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ PlaceBlockViaEditorPlusPlus(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("blockName") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing blockName, x, y, z");
        }

        string blockName = string(input["blockName"]);
        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);
        if (isTerrain) return MakeError("terrain models are not supported by Editor++ free-block macroblock placement");

        int repeat = input.HasKey("repeat") ? int(input["repeat"]) : 1;
        if (repeat < 1) repeat = 1;
        if (repeat > 8) repeat = 8;
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        bool autofocus = input.HasKey("autofocus") ? bool(input["autofocus"]) : true;
        float autofocusDistance = input.HasKey("autofocusDistance") ? float(input["autofocusDistance"]) : 60.0;

        vec3 basePos = vec3(float(input["x"]), float(input["y"]), float(input["z"]));
        vec3 baseRot = RotationInput(input);
        vec3 spacing = vec3(
            input.HasKey("spacingX") ? float(input["spacingX"]) : 32.0,
            input.HasKey("spacingY") ? float(input["spacingY"]) : 0.0,
            input.HasKey("spacingZ") ? float(input["spacingZ"]) : 0.0
        );

        Json::Value placements = Json::Array();
        Json::Value mapPre = MapSummary(editor);
        uint beforeBlocks = editor.Challenge.Blocks.Length;
        bool allPlaced = true;

        for (int i = 0; i < repeat; i++) {
            auto pos = basePos + spacing * float(i);
            auto spec = Editor::MakeBlockSpec(blockInfo, pos, baseRot);
            spec.SetFree();
            spec.isGround = false;
            spec.isGhost = false;
            spec.variant = 0;
            bool variantOk = spec.EnsureValidVariant();

            Editor::BlockSpec@[] blocks;
            blocks.InsertLast(spec);

            bool placed = false;
            try {
                placed = Editor::PlaceBlocks(blocks, addUndo);
            } catch {
                allPlaced = false;
                Json::Value failure = Json::Object();
                failure["index"] = i;
                failure["placed"] = false;
                failure["variantOk"] = variantOk;
                failure["error"] = getExceptionInfo();
                failure["pos"] = Vec3ToJson(pos);
                failure["rot"] = Vec3ToJson(baseRot);
                failure["rotDeg"] = Vec3DegToJson(baseRot);
                placements.Add(failure);
                continue;
            }

            if (!placed) allPlaced = false;
            Json::Value placement = Json::Object();
            placement["index"] = i;
            placement["placed"] = placed;
            placement["variantOk"] = variantOk;
            placement["pos"] = Vec3ToJson(pos);
            placement["rot"] = Vec3ToJson(baseRot);
            placement["rotDeg"] = Vec3DegToJson(baseRot);
            placements.Add(placement);
        }

        Json::Value output = Json::Object();
        output["allPlaced"] = allPlaced;
        output["beforeBlocks"] = int(beforeBlocks);
        output["afterBlocks"] = int(editor.Challenge.Blocks.Length);
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["rot"] = Vec3ToJson(baseRot);
        output["rotDeg"] = Vec3DegToJson(baseRot);
        output["repeat"] = repeat;
        output["placements"] = placements;
        output["autofocus"] = false;
        if (autofocus && placements.Length > 0) {
            vec3 focusPos = basePos + spacing * float(repeat - 1);
            output["autofocus"] = AutofocusCameraOn(focusPos, autofocusDistance);
            output["autofocusTarget"] = Vec3ToJson(focusPos);
            output["autofocusDistance"] = autofocusDistance;
        }
        return MakeSuccess(output);
    }

    Json::Value@ PlaceItemViaEditorPlusPlus(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available");
        if (!input.HasKey("itemPath") || !input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) {
            return MakeError("missing itemPath, x, y, z");
        }

        string itemPath = string(input["itemPath"]);
        auto itemModel = ResolveItemModel(itemPath);
        if (itemModel is null) return MakeError("item not found: " + itemPath);

        int repeat = input.HasKey("repeat") ? int(input["repeat"]) : 1;
        if (repeat < 1) repeat = 1;
        if (repeat > 8) repeat = 8;
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        bool autofocus = input.HasKey("autofocus") ? bool(input["autofocus"]) : true;
        float autofocusDistance = input.HasKey("autofocusDistance") ? float(input["autofocusDistance"]) : 60.0;
        uint16 variant = input.HasKey("variant") ? uint16(input["variant"]) : 0;

        vec3 basePos = PositionInput(input);
        vec3 baseRot = RotationInput(input);
        vec3 spacing = vec3(
            input.HasKey("spacingX") ? float(input["spacingX"]) : 8.0,
            input.HasKey("spacingY") ? float(input["spacingY"]) : 0.0,
            input.HasKey("spacingZ") ? float(input["spacingZ"]) : 0.0
        );

        Json::Value placements = Json::Array();
        Json::Value mapPre = MapSummary(editor);
        uint beforeItems = editor.Challenge.AnchoredObjects.Length;
        bool allPlaced = true;

        for (int i = 0; i < repeat; i++) {
            auto pos = basePos + spacing * float(i);
            auto spec = Editor::MakeItemSpec(itemModel, pos, baseRot);
            spec.isFlying = 1;
            spec.variantIx = variant;

            Editor::ItemSpec@[] items;
            items.InsertLast(spec);

            bool placed = false;
            try {
                placed = Editor::PlaceItems(items, addUndo);
            } catch {
                allPlaced = false;
                Json::Value failure = Json::Object();
                failure["index"] = i;
                failure["placed"] = false;
                failure["error"] = getExceptionInfo();
                failure["pos"] = Vec3ToJson(pos);
                failure["rot"] = Vec3ToJson(baseRot);
                failure["rotDeg"] = Vec3DegToJson(baseRot);
                placements.Add(failure);
                continue;
            }

            if (!placed) allPlaced = false;
            Json::Value placement = Json::Object();
            placement["index"] = i;
            placement["placed"] = placed;
            placement["pos"] = Vec3ToJson(pos);
            placement["rot"] = Vec3ToJson(baseRot);
            placement["rotDeg"] = Vec3DegToJson(baseRot);
            placements.Add(placement);
        }

        Json::Value output = Json::Object();
        output["allPlaced"] = allPlaced;
        output["beforeItems"] = int(beforeItems);
        output["afterItems"] = int(editor.Challenge.AnchoredObjects.Length);
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        output["itemPath"] = itemPath;
        output["model"] = ItemModelToJson(itemModel, itemPath);
        output["rot"] = Vec3ToJson(baseRot);
        output["rotDeg"] = Vec3DegToJson(baseRot);
        output["repeat"] = repeat;
        output["variant"] = int(variant);
        output["placements"] = placements;
        output["autofocus"] = false;
        if (autofocus && placements.Length > 0) {
            vec3 focusPos = basePos + spacing * float(repeat - 1);
            output["autofocus"] = AutofocusCameraOn(focusPos, autofocusDistance);
            output["autofocusTarget"] = Vec3ToJson(focusPos);
            output["autofocusDistance"] = autofocusDistance;
        }
        return MakeSuccess(output);
    }

    Json::Value@ RemoveBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("x") || !input.HasKey("y") || !input.HasKey("z")) return MakeError("missing x, y, z");
        auto coord = int3(int(input["x"]), int(input["y"]), int(input["z"]));
        bool removed = editor.PluginMapType.RemoveBlock(coord);

        Json::Value output = Json::Object();
        output["removed"] = removed;
        output["coord"] = Int3ToJson(coord);
        return MakeSuccess(output);
    }

    Json::Value@ ClearBlocks(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available");
        bool autosave = input.HasKey("autosave") ? bool(input["autosave"]) : true;

        Json::Value mapPre = MapSummary(editor);
        int beforeBlocks = int(editor.Challenge.Blocks.Length);
        try {
            editor.PluginMapType.RemoveAllBlocks();
            for (uint i = 0; i < 30 && int(editor.Challenge.Blocks.Length) == beforeBlocks; i++) yield();
            if (autosave) editor.PluginMapType.AutoSave();
        } catch {
            return MakeError("RemoveAllBlocks failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["method"] = "PluginMapType.RemoveAllBlocks";
        output["autosave"] = autosave;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ ClearItems(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available");
        bool autosave = input.HasKey("autosave") ? bool(input["autosave"]) : true;

        Json::Value mapPre = MapSummary(editor);
        int beforeItems = int(editor.Challenge.AnchoredObjects.Length);
        try {
            editor.PluginMapType.RemoveAllObjects();
            for (uint i = 0; i < 30 && int(editor.Challenge.AnchoredObjects.Length) == beforeItems; i++) yield();
            if (autosave) editor.PluginMapType.AutoSave();
        } catch {
            return MakeError("RemoveAllObjects failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["method"] = "PluginMapType.RemoveAllObjects";
        output["autosave"] = autosave;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ ClearMapContent(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available");
        bool autosave = input.HasKey("autosave") ? bool(input["autosave"]) : true;
        bool includeTerrain = input.HasKey("includeTerrain") ? bool(input["includeTerrain"]) : false;

        Json::Value mapPre = MapSummary(editor);
        int beforeBlocks = int(editor.Challenge.Blocks.Length);
        int beforeItems = int(editor.Challenge.AnchoredObjects.Length);
        string method = includeTerrain
            ? "PluginMapType.RemoveAllBlocksAndTerrain + RemoveAllObjects"
            : "PluginMapType.RemoveAllBlocks + RemoveAllObjects";
        try {
            if (includeTerrain) {
                editor.PluginMapType.RemoveAllObjects();
                editor.PluginMapType.RemoveAllBlocksAndTerrain();
            } else {
                editor.PluginMapType.RemoveAllObjects();
                editor.PluginMapType.RemoveAllBlocks();
            }
            for (uint i = 0; i < 30
                    && int(editor.Challenge.Blocks.Length) == beforeBlocks
                    && int(editor.Challenge.AnchoredObjects.Length) == beforeItems; i++) {
                yield();
            }
            if (autosave) editor.PluginMapType.AutoSave();
        } catch {
            return MakeError(method + " failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["method"] = method;
        output["autosave"] = autosave;
        output["includeTerrain"] = includeTerrain;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ RemoveRecentBlocks(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");

        int count = input.HasKey("count") ? int(input["count"]) : 1;
        if (count < 1) count = 1;
        if (count > 50) count = 50;
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        int total = int(editor.Challenge.Blocks.Length);
        if (total == 0) return MakeError("map has no blocks");
        if (count > total) count = total;

        CGameCtnBlock@[] blocks;
        Json::Value removed = Json::Array();
        int first = total - count;
        for (int i = first; i < total; i++) {
            auto block = editor.Challenge.Blocks[i];
            if (block is null) continue;
            blocks.InsertLast(block);
            auto obj = BlockToJson(block);
            obj["index"] = i;
            removed.Add(obj);
        }

        Json::Value mapPre = MapSummary(editor);
        int beforeBlocks = int(editor.Challenge.Blocks.Length);
        bool allFree = true;
        for (uint i = 0; i < blocks.Length; i++) {
            if (!Editor::IsBlockFree(blocks[i])) allFree = false;
        }

        bool ok = false;
        string method = allFree ? "DeleteFreeblocks" : "DeleteBlocks";
        uint queuedFreeblocks = 0;
        try {
            if (allFree) {
                queuedFreeblocks = Editor::DeleteFreeblocks(blocks);
                for (uint i = 0; i < 30 && int(editor.Challenge.Blocks.Length) == beforeBlocks; i++) yield();
                ok = int(editor.Challenge.Blocks.Length) <= beforeBlocks - int(blocks.Length);
                if (ok && addUndo && editor.PluginMapType !is null) editor.PluginMapType.AutoSave();
            } else {
                ok = Editor::DeleteBlocks(blocks, addUndo);
            }
        } catch {
            return MakeError(method + " failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["deleted"] = ok;
        output["method"] = method;
        output["queuedFreeblocks"] = int(queuedFreeblocks);
        output["requestedCount"] = count;
        output["matchedCount"] = int(blocks.Length);
        output["addUndo"] = addUndo;
        output["removed"] = removed;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ RemoveRecentItems(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");

        int count = input.HasKey("count") ? int(input["count"]) : 1;
        if (count < 1) count = 1;
        if (count > 50) count = 50;
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        bool forceBufferFallback = input.HasKey("forceBufferFallback") ? bool(input["forceBufferFallback"]) : false;
        int total = int(editor.Challenge.AnchoredObjects.Length);
        if (total == 0) return MakeError("map has no items");
        if (count > total) count = total;

        CGameCtnAnchoredObject@[] items;
        Json::Value removed = Json::Array();
        int first = total - count;
        for (int i = first; i < total; i++) {
            auto item = editor.Challenge.AnchoredObjects[i];
            if (item is null) continue;
            items.InsertLast(item);
            auto obj = ItemToJson(item);
            obj["index"] = i;
            removed.Add(obj);
        }

        Json::Value mapPre = MapSummary(editor);
        bool ok = false;
        string method = "DeleteItems";
        try {
            ok = Editor::DeleteItems(items, addUndo);
        } catch {
            return MakeError("DeleteItems failed: " + getExceptionInfo());
        }
        if (!ok && forceBufferFallback && total == int(editor.Challenge.AnchoredObjects.Length) && first + count == total) {
            method = "AnchoredObjects.RemoveRangeTail";
            editor.Challenge.AnchoredObjects.RemoveRange(first, count);
            ok = int(editor.Challenge.AnchoredObjects.Length) == first;
            if (ok && addUndo && editor.PluginMapType !is null) editor.PluginMapType.AutoSave();
        }

        Json::Value output = Json::Object();
        output["deleted"] = ok;
        output["method"] = method;
        output["undoSupported"] = method == "DeleteItems";
        output["requestedCount"] = count;
        output["matchedCount"] = int(items.Length);
        output["addUndo"] = addUndo;
        output["removed"] = removed;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    bool ReadIndexArgs(Json::Value &in input, int total, int maxCount, array<int> &out indices, string &out err) {
        if (input.HasKey("index")) {
            int ix = int(input["index"]);
            if (ix < 0 || ix >= total) {
                err = "index out of range: " + ix + " / " + total;
                return false;
            }
            indices.InsertLast(ix);
        }
        if (input.HasKey("indices")) {
            auto raw = input["indices"];
            if (raw.GetType() != Json::Type::Array) {
                err = "indices must be an array";
                return false;
            }
            for (uint i = 0; i < raw.Length; i++) {
                int ix = int(raw[i]);
                if (ix < 0 || ix >= total) {
                    err = "index out of range: " + ix + " / " + total;
                    return false;
                }
                if (indices.Find(ix) == -1) indices.InsertLast(ix);
                if (indices.Length > uint(maxCount)) {
                    err = "too many indices; max is " + maxCount;
                    return false;
                }
            }
        }
        if (indices.Length == 0) {
            err = "missing index or indices";
            return false;
        }
        return true;
    }

    Json::Value@ RemoveBlocksByIndex(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");

        array<int> indices;
        string err;
        int total = int(editor.Challenge.Blocks.Length);
        if (!ReadIndexArgs(input, total, 50, indices, err)) return MakeError(err);
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;

        CGameCtnBlock@[] blocks;
        Json::Value removed = Json::Array();
        for (uint i = 0; i < indices.Length; i++) {
            auto block = editor.Challenge.Blocks[indices[i]];
            if (block is null) continue;
            blocks.InsertLast(block);
            auto obj = BlockToJson(block);
            obj["index"] = indices[i];
            removed.Add(obj);
        }

        Json::Value mapPre = MapSummary(editor);
        int beforeBlocks = int(editor.Challenge.Blocks.Length);
        bool allFree = true;
        for (uint i = 0; i < blocks.Length; i++) {
            if (!Editor::IsBlockFree(blocks[i])) allFree = false;
        }

        bool ok = false;
        string method = allFree ? "DeleteFreeblocks" : "DeleteBlocks";
        uint queuedFreeblocks = 0;
        try {
            if (allFree) {
                queuedFreeblocks = Editor::DeleteFreeblocks(blocks);
                for (uint i = 0; i < 30 && int(editor.Challenge.Blocks.Length) == beforeBlocks; i++) yield();
                ok = int(editor.Challenge.Blocks.Length) <= beforeBlocks - int(blocks.Length);
                if (ok && addUndo && editor.PluginMapType !is null) editor.PluginMapType.AutoSave();
            } else {
                ok = Editor::DeleteBlocks(blocks, addUndo);
            }
        } catch {
            return MakeError(method + " failed: " + getExceptionInfo());
        }

        Json::Value output = Json::Object();
        output["deleted"] = ok;
        output["method"] = method;
        output["queuedFreeblocks"] = int(queuedFreeblocks);
        output["requestedCount"] = int(indices.Length);
        output["matchedCount"] = int(blocks.Length);
        output["addUndo"] = addUndo;
        output["removed"] = removed;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ RemoveItemsByIndex(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");

        array<int> indices;
        string err;
        int total = int(editor.Challenge.AnchoredObjects.Length);
        if (!ReadIndexArgs(input, total, 50, indices, err)) return MakeError(err);
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        bool forceBufferFallback = input.HasKey("forceBufferFallback") ? bool(input["forceBufferFallback"]) : false;

        CGameCtnAnchoredObject@[] items;
        Json::Value removed = Json::Array();
        for (uint i = 0; i < indices.Length; i++) {
            auto item = editor.Challenge.AnchoredObjects[indices[i]];
            if (item is null) continue;
            items.InsertLast(item);
            auto obj = ItemToJson(item);
            obj["index"] = indices[i];
            removed.Add(obj);
        }

        Json::Value mapPre = MapSummary(editor);
        bool ok = false;
        string method = "DeleteItems";
        try {
            ok = Editor::DeleteItems(items, addUndo);
        } catch {
            return MakeError("DeleteItems failed: " + getExceptionInfo());
        }
        if (!ok && forceBufferFallback && total == int(editor.Challenge.AnchoredObjects.Length)) {
            method = "AnchoredObjects.RemoveRangeByIndex";
            while (indices.Length > 0) {
                int bestPos = 0;
                for (uint i = 1; i < indices.Length; i++) {
                    if (indices[i] > indices[bestPos]) bestPos = int(i);
                }
                editor.Challenge.AnchoredObjects.RemoveRange(indices[bestPos], 1);
                indices.RemoveAt(bestPos);
            }
            ok = int(editor.Challenge.AnchoredObjects.Length) == total - int(items.Length);
            if (ok && addUndo && editor.PluginMapType !is null) editor.PluginMapType.AutoSave();
        }

        Json::Value output = Json::Object();
        output["deleted"] = ok;
        output["method"] = method;
        output["undoSupported"] = method == "DeleteItems";
        output["requestedCount"] = int(removed.Length);
        output["matchedCount"] = int(items.Length);
        output["addUndo"] = addUndo;
        output["removed"] = removed;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        return MakeSuccess(output);
    }

    Json::Value@ SetCursorBlock(Json::Value &in input) {
        return SelectBlockModel(input);
    }

    Json::Value@ SelectBlockModel(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("blockName")) return MakeError("missing blockName");
        string blockName = string(input["blockName"]);
        bool isTerrain = false;
        auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
        if (blockInfo is null) return MakeError("block not found: " + blockName);
        if (isTerrain) return MakeError("terrain models cannot be selected as the current block model");

        string selection = input.HasKey("selection") ? string(input["selection"]).ToLower() : "both";
        if (selection == "normal") {
            Editor::SetSelectedNormalBlockInfo(editor, blockInfo);
        } else if (selection == "ghost") {
            Editor::SetSelectedGhostBlockInfo(editor, blockInfo);
        } else if (selection == "both" || selection.Length == 0) {
            Editor::SetSelectedBlockInfo(editor, blockInfo);
        } else {
            return MakeError("selection must be one of: both, normal, ghost");
        }

        Json::Value output = Json::Object();
        output["selected"] = true;
        output["selection"] = selection.Length == 0 ? "both" : selection;
        output["blockName"] = blockName;
        output["modelName"] = blockInfo.Name;
        output["modelIdName"] = blockInfo.IdName;
        output["currentBlockName"] = editor.CurrentBlockInfo is null ? "" : string(editor.CurrentBlockInfo.Name);
        output["currentBlockIdName"] = editor.CurrentBlockInfo is null ? "" : string(editor.CurrentBlockInfo.IdName);
        output["currentGhostBlockName"] = editor.CurrentGhostBlockInfo is null ? "" : string(editor.CurrentGhostBlockInfo.Name);
        output["currentGhostBlockIdName"] = editor.CurrentGhostBlockInfo is null ? "" : string(editor.CurrentGhostBlockInfo.IdName);
        return MakeSuccess(output);
    }

    Json::Value@ Undo(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        Json::Value output = Json::Object();
        output["undone"] = editor.PluginMapType.Undo();
        return MakeSuccess(output);
    }

    Json::Value@ Redo(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        Json::Value output = Json::Object();
        output["redone"] = editor.PluginMapType.Redo();
        return MakeSuccess(output);
    }
}
