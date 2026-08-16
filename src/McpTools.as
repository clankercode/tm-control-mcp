
namespace TmMcp {
    array<string> g_NamedMacroblockNames;

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
        return MakeError(err, "", false, "", "");
    }

    Json::Value@ MakeError(
        const string &in err,
        const string &in code,
        bool retryable = false,
        const string &in requiredMode = "",
        const string &in hint = ""
    ) {
        Json::Value result = Json::Object();
        result["success"] = false;
        result["error"] = err;
        if (code.Length > 0) result["code"] = code;
        if (retryable) result["retryable"] = true;
        if (requiredMode.Length > 0) result["requiredMode"] = requiredMode;
        if (hint.Length > 0) result["hint"] = hint;
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


    // High-angle autofocus: look down at `pos` from above, keeping the horizontal yaw
    // pointing from the target back toward the current camera so the transition animates
    // naturally from the user's viewpoint.

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
        output["dialogKind"] = bd.Dialog == CGameDialogs::EDialog::None ? "none"
            : (bd.Dialog == CGameDialogs::EDialog::Message ? "message" : "wait");
        output["hasFrame"] = frame !is null;
        if (frame !is null) {
            output["frameIdName"] = frame.IdName;
        }
        if (bd.Dialog == CGameDialogs::EDialog::Message) {
            output["messageText"] = string(bd.Message_LabelText);
            output["messageButtonText"] = string(bd.Message_ButtonText);
        } else if (bd.Dialog == CGameDialogs::EDialog::WaitMessage) {
            output["waitText"] = string(bd.WaitMessage_LabelText);
            output["waitButtonText"] = string(bd.WaitMessage_ButtonText);
            output["waitProgress"] = bd.WaitMessage_Progress;
            output["waitShowAbortButton"] = bd.WaitMessage_ShowAbortButton;
        }
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
        obj["isFree"] = false;
        obj["variant"] = int(block.BlockInfoVariantIndex);
        obj["mobilIndex"] = int(block.MobilIndex);
        obj["mobilVariant"] = int(block.MobilVariantIndex);
        obj["isGround"] = block.IsGround;
        obj["isGhost"] = block.IsGhostBlock();
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
        output["nbItems"] =
            0;
        output["nbMacroblocks"] = int(pmt.MacroblockModels.Length);
        output["isScanningBlocks"] = false;
        output["isScanningItems"] =
            false;
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


    bool IsMovedEppTool(const string &in name) {
        return name == "FocusCamera"
            || name == "FindInventory"
            || name == "RefreshInventory"
            || name == "InspectMacroblockModel"
            || name == "ListMacroblockInstances"
            || name == "RunGizmoApplyBlock"
            || name == "SpikeGizmoVehiclePreview"
            || name == "RunRandomFuzz"
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
            || name == "PlaceBlockViaEditorPlusPlus"
            || name == "PlaceItemViaEditorPlusPlus"
            || name == "RemoveRecentBlocks"
            || name == "RemoveRecentItems"
            || name == "RemoveBlocksByIndex"
            || name == "RemoveItemsByIndex"
            || name == "SaveNamedMacroblock"
            || name == "LoadNamedMacroblock"
            || name == "ListSavedNamedMacroblocks"
            || name == "ControlMapObjectives"
            || name == "ControlItemEditor"
            || name == "ControlEditMode"
            || name == "SelectItemModel"
            || name == "SelectMacroblockModel"
            || name == "ControlInventory"
            || name == "GetEditorSelectionState"
            || name == "SelectBlockModel"
            || name == "SetCursorBlock"
            || name == "RemoveByTag"
            || name == "DumpMacroblockHeader";
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
            || name == "ControlCursor"
            || name == "GetEditorCamera"
            || name == "SetEditorCamera"
            || name == "ControlCamera"
            || name == "TakeScreenshot"
            || name == "GetBlocks"
            || name == "GetRecentBlocks"
            || name == "GetBlockAt"
            || name == "GetItems"
            || name == "GetRecentItems"
            || name == "GetInventorySummary"
            || name == "BrowseInventoryTree"
            || name == "FindBlockModels"
#if DEV
            || name == "RunComputeItemsDiagnostic"
            || name == "DevSafeRead"
            || name == "DevGetPointers"
            || name == "DevComputeItemsPointers"
#endif
            || name == "CanPlaceBlock"
            || name == "PlaceBlock"
            || name == "RemoveBlock"
            || name == "ClearBlocks"
            || name == "ClearItems"
            || name == "ClearMapContent"
            || name == "Undo"
            || name == "Redo"
            || name == "SetMenuPage"
            || name == "GetMenuPage"
            || name == "ListKnownMenuRoutes"
            || name == "ListGuides"
            || name == "GetGuide"
            || name == "EditNewMap"
            || name == "ListMenuManialinkControls"
            || name == "FocusMenuControl"
            || name == "GetUILayers"
            || name == "GetActiveMenuPages"
            || name == "GetLayerTree"
            || name == "FindMenuButtons"
            || name == "FindControlsByClass"
            || name == "FindControlsByLabel"
            || name == "GetLayerXml"
            || name == "BackToMainMenu"
            || name == "ClickMenuButton"
            || name == "InspectMenuControl"
            || name == "SetMenuControlVisible"
            || name == "TriggerControlOnAction"
            || name == "CreateMapViaMenu"
            || name == "RunManialinkScript"
            || name == "GetReadiness"
            || name == "WaitUntil"
            || name == "SetAgentTag"
            || name == "ListTagged"
            || name == "ClearTagIndex"
            || name == "AssertPlacement"
            || name == "ListPlugins"
            || name == "GetPlugin"
            || name == "ControlPlugin"
            || name == "ListPluginSettings"
            || name == "GetPluginSetting"
            || name == "SetPluginSetting"
            || name == "ResetPluginSetting"
            || name == "SavePluginSettings"
            || name == "GetRaceData"
            || name == "GetPlayers"
            || name == "GetServerInfo"
            || name == "GetVehicleState"
            || name == "ListVehicleVis"
            || name == "GetVehicleVis"
            || name == "GetRenderCamera"
            || name == "ProjectWorldToScreen"
            || name == "SetEditorOrbitalTarget"
            || name == "GetResult"
            || name == "ListToolPacks"
            || IsPackToolName(name)
            || IsMovedEppTool(name);
    }

    string CompactJsonForTrace(Json::Value &in value) {
        string s = "{}";
        try { s = Json::Write(value); } catch {}
        if (s.Length > 180) s = s.SubStr(0, 180) + "...";
        return s;
    }

    Json::Value@ CallTool(const string &in name, Json::Value &in input) {
        if (!PushCallStack(name)) {
            return MakeError("reentrant tool call: " + name, "reentrant_tool", false);
        }
        uint started = Time::Now;
        trace("TM Control MCP tool start " + name + " " + CompactJsonForTrace(input));
        Json::Value@ result = null;
        try {
            @result = DispatchTool(name, input);
        } catch {
            @result = MakeError("tool threw: " + getExceptionInfo(), "tool_exception", true);
        }
        PopCallStack();
        string status = "err";
        string extra = "";
        if (result !is null && result.HasKey("success") && bool(result["success"])) {
            status = "ok";
        } else if (result !is null && result.HasKey("code")) {
            extra = " " + string(result["code"]);
        }
        trace("TM Control MCP tool done " + name + " " + status + extra + " " + (Time::Now - started) + "ms");
        return result;
    }

    Json::Value@ DispatchTool(const string &in name, Json::Value &in input) {
        if (ToolRequiresEditorPlusPlus(name) && !IsEditorPlusPlusAvailable()) {
            return EditorPlusPlusMissingError();
        }
        if (name == "GetMode") return GetMode(input);
        if (name == "OpenMapInEditor") return OpenMapInEditor(input);
        if (name == "GetMapInfo") return GetMapInfo(input);
        if (name == "GetMapEnvironment") return GetMapEnvironment(input);
        if (name == "ControlMapObjectives") return ControlMapObjectives(input);
        if (name == "ControlItemEditor") return ControlItemEditor(input);
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
#if DEV
        if (name == "DevSafeRead") return RunDevSafeRead(input);
        if (name == "DevGetPointers") return RunDevGetPointers(input);
#endif
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
        if (name == "FocusMenuControl") return FocusMenuControl(input);
        if (name == "GetUILayers") return GetUILayers(input);
        if (name == "GetActiveMenuPages") return GetActiveMenuPages(input);
        if (name == "GetLayerTree") return GetLayerTree(input);
        if (name == "FindMenuButtons") return FindMenuButtons(input);
        if (name == "FindControlsByClass") return FindControlsByClass(input);
        if (name == "FindControlsByLabel") return FindControlsByLabel(input);
        if (name == "GetLayerXml") return GetLayerXml(input);
        if (name == "BackToMainMenu") return BackToMainMenu(input);
        if (name == "ClickMenuButton") return ClickMenuButton(input);
        if (name == "InspectMenuControl") return InspectMenuControl(input);
        if (name == "SetMenuControlVisible") return SetMenuControlVisible(input);
        if (name == "TriggerControlOnAction") return TriggerControlOnAction(input);
        if (name == "CreateMapViaMenu") return CreateMapViaMenu(input);
        if (name == "RunManialinkScript") return RunManialinkScript(input);
        if (name == "GetReadiness") return GetReadiness(input);
        if (name == "WaitUntil") return WaitUntil(input);
        if (name == "SetAgentTag") return SetAgentTag(input);
        if (name == "ListTagged") return ListTagged(input);
        if (name == "RemoveByTag") return RemoveByTag(input);
        if (name == "ClearTagIndex") return ClearTagIndex(input);
        if (name == "ControlEditMode") return ControlEditMode(input);
        if (name == "SelectItemModel") return SelectItemModel(input);
        if (name == "SelectMacroblockModel") return SelectMacroblockModel(input);
        if (name == "ControlInventory") return ControlInventory(input);
        if (name == "SaveNamedMacroblock") return SaveNamedMacroblock(input);
        if (name == "LoadNamedMacroblock") return LoadNamedMacroblock(input);
        if (name == "ListSavedNamedMacroblocks") return ListSavedNamedMacroblocks(input);
        if (name == "AssertPlacement") return AssertPlacement(input);
        if (name == "ListPlugins") return ListPlugins(input);
        if (name == "GetPlugin") return GetPluginInfo(input);
        if (name == "ControlPlugin") return ControlPlugin(input);
        if (name == "ListPluginSettings") return ListPluginSettings(input);
        if (name == "GetPluginSetting") return GetPluginSetting(input);
        if (name == "SetPluginSetting") return SetPluginSetting(input);
        if (name == "ResetPluginSetting") return ResetPluginSetting(input);
        if (name == "SavePluginSettings") return SavePluginSettings(input);
        if (name == "GetRaceData") return GetRaceData(input);
        if (name == "GetPlayers") return GetPlayers(input);
        if (name == "GetServerInfo") return GetServerInfo(input);
        if (name == "GetVehicleState") return GetVehicleState(input);
        if (name == "ListVehicleVis") return ListVehicleVis(input);
        if (name == "GetVehicleVis") return GetVehicleVis(input);
        if (name == "GetRenderCamera") return GetRenderCamera(input);
        if (name == "ProjectWorldToScreen") return ProjectWorldToScreen(input);
        if (name == "SetEditorOrbitalTarget") return SetEditorOrbitalTarget(input);
        if (name == "GetResult") return GetResult(input);
        if (name == "ListToolPacks") return ListToolPacks(input);
        Json::Value@ packResult = DispatchPackTool(name, input);
        if (packResult !is null) return packResult;
        return MakeError("unknown tool: " + name, "unknown_tool", false, "", "");
    }

    Json::Value@ GetToolList() {
        Json::Value tools = Json::Array();
        tools.Add(MakeTool("GetMode", "Get current game mode.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("OpenMapInEditor", "Open a local map file in the editor.", '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetMapInfo", "Get current editor map name and counts.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetMapEnvironment", "Read map collection, decoration, map type/style, mood, and collection-unit metadata.", '{"type":"object","properties":{},"additionalProperties":false}'));

        tools.Add(MakeTool("SaveMapAs", "Save the current editor map to a named file under the user Maps folder. Use fileName for an explicit path relative to Maps, or name/folder for Maps/folder/name.Map.Gbx.", '{"type":"object","properties":{"name":{"type":"string"},"folder":{"type":"string"},"fileName":{"type":"string"},"overwrite":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetDialog", "Inspect Trackmania's current BasicDialogs state and active dialog frame.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("RespondDialog", "Respond to Trackmania BasicDialogs. action: yes, no, cancel, ok, validate, hide.", '{"type":"object","properties":{"action":{"type":"string"}},"required":["action"],"additionalProperties":false}'));
        tools.Add(MakeTool("ControlValidation", "Inspect or trigger map validation/test/playground controls. Actions: status, validate, requestEnterPlayground, requestLeavePlayground, testFromStart, testFromCoord.", '{"type":"object","properties":{"action":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ControlSelection", "Inspect or control editor copy-paste/custom selection. Actions: status, showCustom, hideCustom, resetSelection, selectAll, addSelection, copy, cut, remove, symmetrize.", '{"type":"object","properties":{"action":{"type":"string"},"x1":{"type":"integer"},"y1":{"type":"integer"},"z1":{"type":"integer"},"x2":{"type":"integer"},"y2":{"type":"integer"},"z2":{"type":"integer"},"limit":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetCursor", "Get editor cursor coordinate and selected block.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("ControlCursor", "Use the editor cursor API: status, raise, lower, rotate, move, moveToCameraTarget, followCamera, disableMouseDetection, releaseLock, resetRGB, setRGB.", '{"type":"object","properties":{"action":{"type":"string"},"direction":{"type":"string"},"directionKind":{"type":"string"},"count":{"type":"integer"},"clockwise":{"type":"boolean"},"follow":{"type":"boolean"},"disable":{"type":"boolean"},"r":{"type":"number"},"g":{"type":"number"},"b":{"type":"number"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetEditorCamera", "Get editor camera target, angles, distance, and current orbital position.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("SetEditorCamera", "Set editor camera target, angles, and target distance. Angles default to degrees; use hAngleRad/vAngleRad for radians.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"hAngle":{"type":"number"},"vAngle":{"type":"number"},"hAngleRad":{"type":"number"},"vAngleRad":{"type":"number"},"distance":{"type":"number"},"animate":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ControlCamera", "Use the editor camera API: status, centerOnCursor, moveToMapCenter, watchWholeMap, watchStart, watchClosestFinishLine, watchClosestCheckpoint, zoom, zoomIn, zoomOut, look, followCursor, ignoreCollisions, releaseLock, setVStep.", '{"type":"object","properties":{"action":{"type":"string"},"smooth":{"type":"boolean"},"loop":{"type":"boolean"},"clockwise":{"type":"boolean"},"halfSteps":{"type":"boolean"},"level":{"type":"string"},"direction":{"type":"string"},"directionKind":{"type":"string"},"follow":{"type":"boolean"},"ignore":{"type":"boolean"},"step":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("TakeScreenshot", "Native viewport screenshot. Waits for the file and returns its game-side path (fullName) + size. Options: format jpg|webp|tga|dds (default jpg), waitMs (default 5000, 0 or noWait skips waiting), hideOverlay (omit HUD/overlays for one frame), forceRes+width+height (render at a forced resolution, restored after). Capture is asynchronous; on timeout output includes timedOut=true — see the 'screenshots' guide.", '{"type":"object","properties":{"format":{"type":"string"},"waitMs":{"type":"integer"},"noWait":{"type":"boolean"},"hideOverlay":{"type":"boolean"},"forceRes":{"type":"boolean"},"width":{"type":"integer"},"height":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetBlocks", "Get blocks by optional grid/world radius, model query, and freeblock filter.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"radius":{"type":"number"},"world":{"type":"boolean"},"query":{"type":"string"},"isFree":{"type":"boolean"},"limit":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetRecentBlocks", "Get the last N blocks in map block order, useful for freeblock placement readback.", '{"type":"object","properties":{"count":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetBlockAt", "Get block info at exact grid coordinate.", '{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"}},"required":["x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetItems", "Get anchored items near a world position, or all items up to limit if no position is provided.", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"radius":{"type":"number"},"limit":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetRecentItems", "Get the last N anchored items in map item order.", '{"type":"object","properties":{"count":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetInventorySummary", "Get E++ inventory cache counts and scan status.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("BrowseInventoryTree", "Read-only browse of the editor inventory root/directories. Supports root, rootIndex, path, depth, limit, query.", '{"type":"object","properties":{"root":{"type":"string"},"rootIndex":{"type":"integer"},"path":{"type":"string"},"depth":{"type":"integer"},"limit":{"type":"integer"},"query":{"type":"string"},"includeArticles":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("FindBlockModels", "Search loaded editor block models.", '{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"},"includeTerrain":{"type":"boolean"},"terrainOnly":{"type":"boolean"}},"additionalProperties":false}'));
#if DEV
        tools.Add(MakeTool("RunComputeItemsDiagnostic", "DEV diagnostic: create a CGameEditorMapMacroBlockInstance at the given grid coord for a macroblock file, call ComputeItemsForMacroblockInstance, and report wrapper pointers + live AnchoredObject matches. Optional testSkin={itemIndex,bgSkin,fgSkin} tries SetItemSkin(s) on the wrapper and reports pre/post skin persistence.", '{"type":"object","properties":{"mbPath":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"force":{"type":"boolean"},"testSkin":{"type":"object","properties":{"itemIndex":{"type":"integer"},"bgSkin":{"type":"string"},"fgSkin":{"type":"string"}}}},"required":["mbPath","x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("DevSafeRead", "Read memory at an arbitrary address using Dev::SafeRead*. ptr accepts hex string \"0x...\" or integer. Optional offset/offsets (array of ints) are summed. kind: u8|u16|u32|u64|i8|i16|i32|i64|f32|vec2|vec3|vec4|cstr|bytes. For cstr/bytes, len caps bytes read (default 256/64, bytes max 4096). Reports probe result, value, and readError on faults.", '{"type":"object","properties":{"ptr":{"type":["string","integer"]},"offset":{"type":"integer"},"offsets":{"type":"array","items":{"type":"integer"}},"kind":{"type":"string"},"len":{"type":"integer"}},"required":["ptr"],"additionalProperties":false}'));
        tools.Add(MakeTool("DevGetPointers", "Return raw pointers for the current editor, PluginMapType, Challenge, Cursor, and App, with per-nod vtable/refcount peeks. Optional listAnchoredObjects, listBlocks, and listPmtItems include map items/blocks/pmt.Items pointers (capped by *Limit params, default 20). listPmtItems exposes healthy CGameCtnEditorScriptAnchoredObject wrappers for memory comparison against compute-path wrappers.", '{"type":"object","properties":{"listAnchoredObjects":{"type":"boolean"},"anchoredObjectsLimit":{"type":"integer"},"listBlocks":{"type":"boolean"},"blocksLimit":{"type":"integer"},"listPmtItems":{"type":"boolean"},"pmtItemsLimit":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("DevComputeItemsPointers", "Like RunComputeItemsDiagnostic but NEVER accesses wrapper fields (Position/ItemModel). Returns raw pointers + vtable/refcount peeks for each MacroblockInstanceItemsResults entry so you can inspect layout via DevSafeRead without crashing.", '{"type":"object","properties":{"mbPath":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"force":{"type":"boolean"}},"required":["mbPath","x","y","z"],"additionalProperties":false}'));
#endif
        tools.Add(MakeTool("CanPlaceBlock", "Check whether a normal grid/terrain block can be placed without mutating the map.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"allowDestruction":{"type":"boolean"}},"required":["blockName","x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("PlaceBlock", "Place a block in the editor and return mapPre/mapPost metadata.", '{"type":"object","properties":{"blockName":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"},"dir":{"type":"string"},"allowDestruction":{"type":"boolean"}},"required":["blockName","x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("RemoveBlock", "Remove a block at grid coordinates.", '{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"z":{"type":"integer"}},"required":["x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("ClearBlocks", "Remove all map blocks through the editor PluginMapType RemoveAllBlocks method.", '{"type":"object","properties":{"autosave":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ClearItems", "Remove all map items/objects through the editor PluginMapType RemoveAllObjects method.", '{"type":"object","properties":{"autosave":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ClearMapContent", "Remove all map blocks and items through editor PluginMapType remove-all methods.", '{"type":"object","properties":{"autosave":{"type":"boolean"},"includeTerrain":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("Undo", "Undo the last editor action.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("Redo", "Redo the last undone editor action.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("SetMenuPage", "Navigate the main-menu router to a route via MLHook. Routes are hierarchical (e.g. '/create/mapeditorsettings', not '/mapeditorsettings'); see ListKnownMenuRoutes. 'extra' is a JSON string for route hydration (e.g. '{\"Campaign\":\"...\"}'), default '{}'. 'history' is a JSON string for navigation-history controls (e.g. '{\"SaveHistory\":true,\"HidePreviousPage\":true}'), default '{}'. Known side-effect routes (e.g. /solo/campaigndisplay) are blocked unless allowPlaygroundLaunch:true — they can silently auto-load a map into Race mode. Only works while in the main-menu module; use GetMode to check.", '{"type":"object","properties":{"route":{"type":"string"},"extra":{"type":"string"},"history":{"type":"string"},"allowPlaygroundLaunch":{"type":"boolean"}},"required":["route"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetMenuPage", "Report current top-level game mode (Menu/Editor/Race) and whether the main-menu module is active. Does not attempt to read the specific menu route.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("ListKnownMenuRoutes", "Return a hardcoded catalogue of main-menu Router_Push routes known to work (sourced from tm-menu-page-manager).", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("ListGuides", "List available self-documentation guides. Each has a short title; call GetGuide {topic} to fetch the full body.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetGuide", "Fetch the full body of a named guide. Use ListGuides to see topics.", '{"type":"object","properties":{"topic":{"type":"string"}},"required":["topic"],"additionalProperties":false}'));
        tools.Add(MakeTool("EditNewMap", "Create a new map in the editor with a specific Environment + Decoration (vista). Defaults: Stadium / 48x48Day / TrackMania TM_Race. See the map-vistas guide for decoration strings. Call returns immediately; poll GetMode until mode becomes Editor.", '{"type":"object","properties":{"environment":{"type":"string"},"decoration":{"type":"string"},"mapType":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ListMenuManialinkControls", "Walk the main-menu UI layer tree and return controls with their ControlId, classes, visibility, and path. Used to discover button IDs before firing Manialink events. maxDepth default 8; onlyWithId default true (skip anonymous frames); includeHidden default false.", '{"type":"object","properties":{"maxDepth":{"type":"integer"},"onlyWithId":{"type":"boolean"},"includeHidden":{"type":"boolean"},"maxResults":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("FocusMenuControl", "Find a menu control by ControlId across all UI layers and call Focus() on it. Probe step before trying synthetic click events. Does not perform click.", '{"type":"object","properties":{"controlId":{"type":"string"}},"required":["controlId"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetUILayers", "Lightweight: list main-menu UI layers with index, type, visibility, attachId, pageUrl, and (default) the extracted <manialink name> attribute. Does NOT traverse the control tree. Use GetLayerTree for per-layer introspection. Use includeXmlSize=true to also return the XML length (avoids returning the full XML).", '{"type":"object","properties":{"includeName":{"type":"boolean"},"includeXmlSize":{"type":"boolean"},"onlyVisible":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetActiveMenuPages", "Return visible main-menu layers named Page_* (e.g. Page_HomePage, Page_Create, Page_MapEditorSettings). Use after SetMenuPage to verify the route actually rendered, and as a cheap 'where am I in the menu' check.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetLayerTree", "Walk the control tree of one UI layer (by layerIndex) with optional rootPath (slash-separated ControlIds). Returns controls starting at that point. Used with GetUILayers to drill in without dumping every layer.", '{"type":"object","properties":{"layerIndex":{"type":"integer"},"maxDepth":{"type":"integer"},"rootPath":{"type":"string"},"onlyWithId":{"type":"boolean"},"includeHidden":{"type":"boolean"},"maxResults":{"type":"integer"}},"required":["layerIndex"],"additionalProperties":false}'));
        tools.Add(MakeTool("FindMenuButtons", "High-level: flat list of visible main-menu navigation buttons across all visible UI layers. Default classFilter is \"component-navigation-item\" (Nadeo menu button pattern). For each match, includes layerIndex, layerName, controlId, classes, absPos/size, raw label (|PageName|Text), and stripped displayText (Text).", '{"type":"object","properties":{"onlyVisible":{"type":"boolean"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"},"className":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("FindControlsByClass", "Search across main-menu UI layers for controls whose class list matches classPattern. substring=true (default) does Contains match, substring=false requires exact equality. Returns same enriched entries as FindMenuButtons (includes child label text if present).", '{"type":"object","properties":{"classPattern":{"type":"string"},"substring":{"type":"boolean"},"onlyVisible":{"type":"boolean"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"}},"required":["classPattern"],"additionalProperties":false}'));
        tools.Add(MakeTool("FindControlsByLabel", "Search across main-menu UI layers for Label controls whose Value contains the given substring. Case-insensitive by default. Returns layerIndex, layerName, controlId, raw label, displayText (translation prefix stripped), classes, absPos, size.", '{"type":"object","properties":{"substring":{"type":"string"},"caseInsensitive":{"type":"boolean"},"onlyVisible":{"type":"boolean"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"}},"required":["substring"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetLayerXml", "Read a slice of a UI layer's Manialink XML, or substring-grep it. Either {layerIndex, find, context?=120, maxHits?=20, caseInsensitive?=false} to grep, or {layerIndex, offset?=0, length?=2048} to slice. Use instead of dumping the whole 10-50 KB XML for a layer.", '{"type":"object","properties":{"layerIndex":{"type":"integer"},"find":{"type":"string"},"context":{"type":"integer"},"maxHits":{"type":"integer"},"caseInsensitive":{"type":"boolean"},"offset":{"type":"integer"},"length":{"type":"integer"}},"required":["layerIndex"],"additionalProperties":false}'));
        tools.Add(MakeTool("BackToMainMenu", "Unwind out of whatever module the game is currently in (Editor, Race) and return to the main menu. Works from a live race, self-hosted solo, or the editor. Async — poll GetMode until mode=='Menu'.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("ClickMenuButton", "High-level click on a Nadeo main-menu nav-item. Resolve with {controlId} (e.g. 'button-map-editor') or {indexPath, layerIndex|layerName}. Descends to the component-navigation-item-zone leaf and invokes its CControlBase::OnAction — the same dispatch a real click uses. Works across button templates (expendable-button, Trackmania_Button). For non-nav controls without the nav-zone class, use TriggerControlOnAction directly. After firing, poll GetActiveMenuPages / GetMode / GetDialog to observe the route change.", '{"type":"object","properties":{"controlId":{"type":"string"},"indexPath":{"type":"string"},"layerIndex":{"type":"integer"},"layerName":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("InspectMenuControl", "Probe: resolve a ControlId on the active Page_* (or named layer) via LocalPage.GetFirstChild and MainFrame.GetFirstChild. Returns type, classes, visibility, position, plus two path encodings from MainFrame: 'path' is slash-joined child indexes (e.g. '3/0' = MainFrame.Controls[3].Controls[0]), 'idPath' is slash-joined ControlIds (e.g. 'frame-global/button-create'). By default includes up to 32 direct children. Pass recursive:true with maxDepth to return a 'descendants' array walked via the same logic as GetLayerTree. Read-only — safe to call from Angelscript.", '{"type":"object","properties":{"controlId":{"type":"string"},"layerName":{"type":"string"},"recursive":{"type":"boolean"},"maxDepth":{"type":"integer"},"onlyWithId":{"type":"boolean"},"includeHidden":{"type":"boolean"},"maxResults":{"type":"integer"}},"required":["controlId"],"additionalProperties":false}'));
        tools.Add(MakeTool("SetMenuControlVisible", "Call Show()/Hide() on a menu control. Resolve either by {controlId} (global search) or {indexPath, layerIndex|layerName} (direct walk from MainFrame). visible=true calls Show; false calls Hide. Menu may re-render and reset visibility on the next tick — re-observe after to confirm. Works from Angelscript (unlike TriggerPageAction).", '{"type":"object","properties":{"controlId":{"type":"string"},"indexPath":{"type":"string"},"layerIndex":{"type":"integer"},"layerName":{"type":"string"},"visible":{"type":"boolean"}},"required":["visible"],"additionalProperties":false}'));
        tools.Add(MakeTool("TriggerControlOnAction", "Click a menu control by invoking its underlying CControlBase.OnAction() — the same dispatch the game uses when a button is activated. Resolve via {controlId} (global search) or {indexPath, layerIndex|layerName}. For Nadeo expendable-button nav-items (e.g. button-create on Page_HomePage) the click target is the leaf nav-zone at Controls[0]/[4]/[0]; pass that indexPath explicitly. Safe from Angelscript (OnAction is on CControlBase, not the script-handler). Set recursive=true to fire OnAction on every descendant (DFS) — useful when a single nav-zone click does not advance the state machine; tune with maxDepth (default 10), maxFires (default 128), onlyVisible (default true).", '{"type":"object","properties":{"controlId":{"type":"string"},"indexPath":{"type":"string"},"layerIndex":{"type":"integer"},"layerName":{"type":"string"},"recursive":{"type":"boolean"},"maxDepth":{"type":"integer"},"maxFires":{"type":"integer"},"onlyVisible":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("CreateMapViaMenu", "Single-call tool: navigate Page_MapEditorSettings and launch the editor for a chosen map type, environment, mood, input device, and difficulty. Drives the full 7-step click-chain (SetMenuPage + 6 OnAction clicks), polling for each intermediate frame transition. Returns {ok, finalMode, elapsedMs, steps} on success or {ok:false, failedAt, expectedFrame, lastObserved, elapsedMs, steps} on failure. Requires QuickStart disabled (MapEditorUseQuickstart off). Click-chain verified 2026-04-20.", '{"type":"object","properties":{"mapType":{"type":"string","description":"race | royal | stunt | platform"},"environment":{"type":"string","description":"Stadium | RedIsland | GreenCoast | BlueBay | WhiteShore"},"mood":{"type":"string","description":"Sunrise | Day | Sunset | Night"},"inputDevice":{"type":"string","description":"mouse | gamepad"},"difficulty":{"type":"string","description":"simple | advanced"},"timeoutMs":{"type":"integer","description":"Final poll timeout waiting for Editor mode (default 10000ms)"}},"required":["mapType","environment","mood","inputDevice","difficulty","timeoutMs"],"additionalProperties":false}'));
        tools.Add(MakeTool("RunManialinkScript", "Inject ad-hoc ManiaScript via MLHook (menu/in-map/in-editor). script without outer <manialink>. Optional collectMs>0 registers a result hook: script should SendCustomEvent(\"MLHook_Event_McpAdHoc_Result\", [payload...]) (or resultEvent). Also pageUid/replace/persist/waitMs.", '{"type":"object","properties":{"script":{"type":"string"},"context":{"type":"string"},"pageUid":{"type":"string"},"replace":{"type":"boolean"},"persist":{"type":"boolean"},"waitMs":{"type":"integer"},"collectMs":{"type":"integer"},"resultEvent":{"type":"string"}},"required":["script"],"additionalProperties":false}'));

        tools.Add(MakeTool("GetReadiness", "Composite preflight: mode/dialog/editor-ready/inventory/map checks. want=editor|menu|any|race.", '{"type":"object","properties":{"want":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("WaitUntil", "Poll until condition is true. condition=mode|dialogClear|editorReady|pageVisible|mapItems|mapBlocks|readiness. Returns ok/timedOut (not a hard error on timeout).", '{"type":"object","properties":{"condition":{"type":"string"},"equals":{"type":"string"},"page":{"type":"string"},"op":{"type":"string"},"count":{"type":"integer"},"want":{"type":"string"},"timeoutMs":{"type":"integer"},"pollMs":{"type":"integer"}},"required":["condition"],"additionalProperties":false}'));
        tools.Add(MakeTool("AssertPlacement", "Verify recent placement: expectItemsDelta/expectBlocksDelta, near{x,y,z,radius}+itemPath/blockName, tag/tagMinCount.", '{"type":"object","properties":{"expectItemsDelta":{"type":"integer"},"expectBlocksDelta":{"type":"integer"},"near":{"type":"object"},"itemPath":{"type":"string"},"blockName":{"type":"string"},"mapPre":{"type":"object"},"tag":{"type":"string"},"tagMinCount":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ListPlugins", "List loaded Openplanet plugins (Meta::AllPlugins). Optional query, includeDisabled (default true), includeUnloaded, includeSourcePath (full paths; default basename only).", '{"type":"object","properties":{"query":{"type":"string"},"includeDisabled":{"type":"boolean"},"includeUnloaded":{"type":"boolean"},"includeSourcePath":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetPlugin", "Get one plugin by id or name. includeSettings=true embeds setting values. includeSourcePath=true adds full SourcePath (may be Wine absolute); default is sourcePathBase only.", '{"type":"object","properties":{"id":{"type":"string"},"plugin":{"type":"string"},"name":{"type":"string"},"includeSettings":{"type":"boolean"},"includeSourcePath":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ControlPlugin", "Plugin lifecycle (RemoteBuild-parity): enable|disable|setEnabled|reload|unload|load|openSettings|getLogs. load accepts id (Plugins/<id>/ or <id>.op) like tm-remote-build, or absolute path. Already-loaded id is unloaded then reloaded from disk. getLogs tails Openplanet.log filtered by plugin id. Refuses disable/unload/rebuild of self.", '{"type":"object","properties":{"action":{"type":"string"},"id":{"type":"string"},"plugin":{"type":"string"},"name":{"type":"string"},"enabled":{"type":"boolean"},"path":{"type":"string"},"source":{"type":"string"},"type":{"type":"string"},"maxLines":{"type":"integer"},"compileOnly":{"type":"boolean"}},"required":["action"],"additionalProperties":false}'));
        tools.Add(MakeTool("ListPluginSettings", "List Meta::PluginSetting for a plugin (default: this MCP plugin). Filters: category, query, includeHidden, includeValues.", '{"type":"object","properties":{"id":{"type":"string"},"plugin":{"type":"string"},"name":{"type":"string"},"category":{"type":"string"},"query":{"type":"string"},"includeHidden":{"type":"boolean"},"includeValues":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetPluginSetting", "Read one setting by varName (or unique display name). Default plugin = self.", '{"type":"object","properties":{"id":{"type":"string"},"plugin":{"type":"string"},"varName":{"type":"string"},"setting":{"type":"string"},"name":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("SetPluginSetting", "Write a setting value (typed). save=true (default) calls Meta::SaveSettings. This plugin's socket host/port/enable apply live (no reload).", '{"type":"object","properties":{"id":{"type":"string"},"plugin":{"type":"string"},"varName":{"type":"string"},"setting":{"type":"string"},"value":{},"save":{"type":"boolean"}},"required":["value"],"additionalProperties":false}'));
        tools.Add(MakeTool("ResetPluginSetting", "Reset one setting to default via PluginSetting.Reset(); optional save.", '{"type":"object","properties":{"id":{"type":"string"},"plugin":{"type":"string"},"varName":{"type":"string"},"setting":{"type":"string"},"save":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("SavePluginSettings", "Persist all Openplanet plugin settings to disk (Meta::SaveSettings).", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetRaceData", "Get live race data via MLFeed::GetRaceData_V4. Requires an active playground (Race mode). Returns map name, CP count, lap count, and sorted players.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetPlayers", "Get live player data via MLFeed::GetRaceData_V4. Richer than GetRaceData: includes login, currentLap, teamNum, isMVP, respawnRank. Requires Race mode.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetServerInfo", "Get current server connection info from CTrackManiaNetwork. Returns serverName, connected, playerCount, maxPlayers.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("GetVehicleState", "VehicleState:: viewing dump: GetViewingPlayer + ViewingPlayerState plus RPM/sideSpeed/turbo/reactor/cruise/vehicleType/wheel dirt+falling. Needs Race/replay vis.", '{"type":"object","properties":{},"additionalProperties":false}'));
        tools.Add(MakeTool("ListVehicleVis", "VehicleState::GetAllVis — all vehicle vis in GameScene. limit default 32.", '{"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetVehicleVis", "VehicleState::GetSingularVis, GetVisFromId (entityId), or GetVis(player) via name/login.", '{"type":"object","properties":{"entityId":{"type":"integer"},"name":{"type":"string"},"login":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("GetRenderCamera", "Camera::GetCurrent (or find=true → FindCurrent) + GetCurrentPosition + projection/fov/clip.", '{"type":"object","properties":{"find":{"type":"boolean"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ProjectWorldToScreen", "Camera::ToScreen + ToScreenSpace + IsBehind for world (x,y,z).", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"}},"required":["x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("SetEditorOrbitalTarget", "Camera::SetEditorOrbitalTarget — focus editor orbital camera on world (x,y,z).", '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"}},"required":["x","y","z"],"additionalProperties":false}'));
        tools.Add(MakeTool("GetResult", "Poll for async tool result. input: {requestId}. Returns {request_id, status:'pending'|'done'|'error', result?/error?}. Used after DispatchAsync (in-process only).", '{"type":"object","properties":{"requestId":{"type":"string"},"request_id":{"type":"string"}},"additionalProperties":false}'));
        tools.Add(MakeTool("ListToolPacks", "List registered MCP tool packs (id, plugin, toolCount, enabled).", '{"type":"object","properties":{},"additionalProperties":false}'));
        AppendPackTools(tools);
        return tools;
    }

    Json::Value MakeTool(const string &in name, const string &in description, const string &in inputSchemaJson) {
        Json::Value tool = Json::Object();
        tool["name"] = name;
        tool["description"] = description;
        tool["input_schema"] = Json::Parse(inputSchemaJson);
        return tool;
    }

    // Item editor control: state readout + safe EME nullify via E++ (issue #28).

    Json::Value@ GetMode(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        Json::Value output = Json::Object();
        if (app is null) {
            output["mode"] = "Unknown";
            return MakeSuccess(output);
        }
        if (app.Editor !is null) {
            output["mode"] = "Editor";
        } else if (app.CurrentPlayground !is null) {
            output["mode"] = "Race";
            output["selfHosted"] = app.PlaygroundScript !is null;
        } else {
            output["mode"] = "Menu";
        }
        if (app.RootMap !is null) {
            output["mapName"] = app.RootMap.MapName;
            output["mapUid"] = app.RootMap.MapInfo !is null ? app.RootMap.MapInfo.MapUid : "";
        }
        return MakeSuccess(output);
    }

    Json::Value@ BackToMainMenu(Json::Value &in input) {
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return MakeError("app not available", "UNKNOWN", true);
        uint readyWaitedMs = 0;
        bool editorWasReady = true;
        auto editor = cast<CGameCtnEditorFree>(app.Editor);
        if (editor !is null && editor.PluginMapType !is null) {
            // Wait for the editor to quiesce before tearing down; calling
            // BackToMainMenu mid-operation (e.g. right after a burst of
            // PlaceMacroblock) can deadlock the unwind.
            editorWasReady = editor.PluginMapType.IsEditorReadyForRequest;
            uint64 t0 = Time::Now;
            while (!editor.PluginMapType.IsEditorReadyForRequest && readyWaitedMs < 5000) {
                yield();
                readyWaitedMs = uint(Time::Now - t0);
            }
            @editor = null;
        }
        app.BackToMainMenu();
        uint menuWaitedMs = 0;
        bool reachedMenu = false;
        uint64 t1 = Time::Now;
        while (menuWaitedMs < 10000) {
            if (app.Switcher.ModuleStack.Length > 0
                && cast<CTrackManiaMenus>(app.Switcher.ModuleStack[app.Switcher.ModuleStack.Length - 1]) !is null) {
                reachedMenu = true;
                break;
            }
            yield();
            menuWaitedMs = uint(Time::Now - t1);
        }
        Json::Value output = Json::Object();
        output["editorWasReady"] = editorWasReady;
        output["readyWaitedMs"] = int(readyWaitedMs);
        output["menuWaitedMs"] = int(menuWaitedMs);
        output["reachedMenu"] = reachedMenu;
        if (!reachedMenu) {
            output["note"] = "BackToMainMenu() issued but menu module not on top after 10s; poll GetMode manually.";
        } else {
            output["note"] = "BackToMainMenu() complete; menu module on top of stack.";
        }
        return MakeSuccess(output);
    }

    bool _IsDangerousMenuRoute(const string &in route) {
        // Routes observed to auto-launch a playground instead of only swapping a Page_*.
        // See research/MenuManialinkLayers.md "Routes with side-effects".
        return route == "/solo/campaigndisplay"
            || route == "/solo/monthlycampaigndisplay";
    }

    Json::Value@ SetMenuPage(Json::Value &in input) {
#if DEPENDENCY_MLHOOK
        if (!input.HasKey("route")) return MakeError("missing route");
        string route = string(input["route"]);
        if (route.Length == 0 || route.SubStr(0, 1) != "/") {
            return MakeError("route must start with '/': got '" + route + "'. Known routes begin with '/' (e.g. '/home', '/create'). Router_Push silently wedges the menu into Page_LoadingScreen on an invalid route.");
        }
        string extra = input.HasKey("extra") ? string(input["extra"]) : "{}";
        string history = input.HasKey("history") ? string(input["history"]) : "{}";
        bool allowPlaygroundLaunch = input.HasKey("allowPlaygroundLaunch")
            ? bool(input["allowPlaygroundLaunch"]) : false;
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return MakeError("app not available", "UNKNOWN", true);
        if (app.Switcher.ModuleStack.Length == 0) {
            return MakeError("not in menu; Switcher.ModuleStack is empty");
        }
        if (cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) {
            auto mod = app.Switcher.ModuleStack[0];
            string modTy = "<unknown>";
            if (mod !is null) {
                auto ty = Reflection::TypeOf(mod);
                if (ty !is null) modTy = ty.Name;
            }
            return MakeError("not in menu; current module is " + modTy + " (expected CTrackManiaMenus)");
        }
        if (_IsDangerousMenuRoute(route) && !allowPlaygroundLaunch) {
            return MakeError("route '" + route + "' can auto-launch a playground (observed live: silently loaded active campaign map). Pass allowPlaygroundLaunch:true to confirm. Use GetMode to detect and BackToMainMenu to unwind.");
        }
        MLHook::Queue_Menu_SendCustomEvent("Router_Push", { route, extra, history });
        Json::Value output = Json::Object();
        output["route"] = route;
        output["history"] = history;
        output["extra"] = extra;
        output["note"] = "Router_Push queued via MLHook; menu transition is async";
        if (_IsDangerousMenuRoute(route)) {
            output["warning"] = "side-effect route: may cascade into Race mode. Poll GetMode; use BackToMainMenu to unwind.";
        }
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
        // Routes are hierarchical: subpages use their FULL path (e.g.
        // "/create/mapeditorsettings"), not the leaf name alone. The bare
        // leaf form generally renders a blank Page_LoadingScreen. See
        // research/MenuManialinkLayers.md for how these were mined from
        // each parent page's Select() switch via GetLayerXml.
        Json::Value output = Json::Object();
        Json::Value topLevel = Json::Array();
        string[] top = {
            "/home", "/solo", "/live", "/local", "/arcade",
            "/clubs", "/create", "/settings", "/profile",
            "/play-map", "/against-replay", "/press-start",
            "/empty"
        };
        for (uint i = 0; i < top.Length; i++) topLevel.Add(top[i]);
        output["topLevel"] = topLevel;

        Json::Value sub = Json::Array();
        string[] subpages = {
            // Verified on 2026-04-20 live TM session.
            "/create/mapeditorsettings",
            "/create/garage",
            "/create/edit-replay",
            "/create/server-review",
            "/create/prestige-recap",
            "/solo/library-clubcampaigns",
            "/solo/monthlycampaigndisplay",
            "/solo/campaigndisplay",
            "/solo/weekly-tracks"
        };
        for (uint i = 0; i < subpages.Length; i++) sub.Add(subpages[i]);
        output["subpages"] = sub;

        output["note"] = "Pushing a bare leaf (e.g. '/mapeditorsettings') renders blank. Use the full path ('/create/mapeditorsettings'). Some subpages (e.g. /solo/campaigndisplay) expect structured 'extra' payloads; without them the page may render empty.";
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
        if (editor is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        return MakeSuccess(MapSummary(editor));
    }

    Json::Value@ SaveMapAs(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) {
            return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (pmt is null) return MakeError("editor map type plugin not available", "NOT_IN_EDITOR", true, "Editor");

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
        if (pmt is null) return MakeError("editor map type plugin not available", "NOT_IN_EDITOR", true, "Editor");

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
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        return MakeSuccess(CameraToJson(editor));
    }

    Json::Value@ SetEditorCamera(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (!animated) {
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


    Json::Value@ TakeScreenshot(Json::Value &in input) {
        auto app = GetApp();
        if (app is null || app.Viewport is null) return MakeError("viewport not available");

        string format = input.HasKey("format") ? string(input["format"]).ToLower() : "jpg";
        if (format == "jpeg") format = "jpg";
        if (format != "jpg" && format != "webp" && format != "tga" && format != "dds") {
            return MakeError("unknown format: " + format, "INVALID_INPUT", false, "", "format: jpg (default), webp, tga, dds");
        }

        int waitMs = input.HasKey("waitMs") ? int(input["waitMs"]) : 5000;
        if (waitMs < 0) waitMs = 0;
        if (waitMs > 15000) waitMs = 15000;
        bool noWait = input.HasKey("noWait") ? bool(input["noWait"]) : false;
        if (noWait) waitMs = 0;

        bool hideOverlay = input.HasKey("hideOverlay") ? bool(input["hideOverlay"]) : false;
        bool forceRes = input.HasKey("forceRes") ? bool(input["forceRes"]) : false;
        if (input.HasKey("width") || input.HasKey("height")) forceRes = true;
        uint width = input.HasKey("width") ? uint(Math::Max(1, int(input["width"]))) : 1920;
        uint height = input.HasKey("height") ? uint(Math::Max(1, int(input["height"]))) : 1080;

        CHmsViewport@ vp = app.Viewport;
        // Baseline before capture: the name of the last completed capture (or empty).
        string fullNameBefore = string(vp.ScreenShotFullName);

        // Native override state (restored after the file lands or the wait times out).
        bool overlaySaved = vp.DisableOverlayRender;
        bool forceResSaved = vp.ScreenShotForceRes;
        uint widthSaved = vp.ScreenShotWidth;
        uint heightSaved = vp.ScreenShotHeight;

        try {
            if (hideOverlay) vp.DisableOverlayRender = true;
            if (forceRes) {
                vp.ScreenShotForceRes = true;
                vp.ScreenShotWidth = width;
                vp.ScreenShotHeight = height;
            }
            // Let override flags apply for at least one rendered frame before queuing the capture.
            yield();

            if (format == "webp") vp.ScreenShotDoCaptureWebp();
            else if (format == "tga") vp.ScreenShotDoCaptureTga();
            else if (format == "dds") vp.ScreenShotDoCaptureDDS();
            else vp.ScreenShotDoCaptureJpg();
        } catch {
            vp.DisableOverlayRender = overlaySaved;
            vp.ScreenShotForceRes = forceResSaved;
            vp.ScreenShotWidth = widthSaved;
            vp.ScreenShotHeight = heightSaved;
            return MakeError("screenshot capture failed: " + getExceptionInfo());
        }

        // Poll for the finished file. ScreenShotFullName updates to the new capture's
        // path once the game queues/completes it; file existence + size confirm the write.
        string fullName = "";
        bool detected = false;
        uint64 sizeBytes = 0;
        uint64 waitedStart = Time::Now;
        string pollError = "";
        try {
            while (Time::Now - waitedStart < uint(waitMs)) {
                yield();
                string candidate = string(vp.ScreenShotFullName);
                if (candidate.Length > 0 && candidate != fullNameBefore) {
                    if (IO::FileExists(candidate)) {
                        uint64 sz = uint64(IO::FileSize(candidate));
                        if (sz > 0) {
                            fullName = candidate;
                            sizeBytes = sz;
                            detected = true;
                            break;
                        }
                    }
                }
            }
        } catch {
            pollError = getExceptionInfo();
        }

        // Always restore native override state — including on poll errors, so a bad
        // path can never leave DisableOverlayRender/ForceRes stuck on.
        vp.DisableOverlayRender = overlaySaved;
        vp.ScreenShotForceRes = forceResSaved;
        vp.ScreenShotWidth = widthSaved;
        vp.ScreenShotHeight = heightSaved;

        Json::Value output = Json::Object();
        output["requested"] = true;
        output["format"] = format;
        output["extension"] = ScreenshotExtForFormat(format);
        output["detected"] = detected;
        output["waitMs"] = waitMs;
        output["waitedMs"] = int(Time::Now - waitedStart);
        if (detected) {
            output["fullName"] = fullName;
            output["sizeBytes"] = int64(sizeBytes);
        } else if (waitMs > 0) {
            output["timedOut"] = true;
            output["fullNameBefore"] = fullNameBefore;
            output["hint"] = "Capture is asynchronous and the file did not appear within waitMs. Retry, raise waitMs, or use call.py Linux-side detection (detectedScreenshot).";
        }
        if (pollError.Length > 0) output["pollError"] = pollError;
        output["gameFolder"] = IO::FromUserGameFolder("");
        output["folder"] = IO::FromUserGameFolder("ScreenShots");
        output["defaultPattern"] = "ScreenShot*" + ScreenshotExtForFormat(format);
        output["note"] = "Trackmania writes viewport captures as ScreenShotNN.<ext> in the user game folder root (gameFolder), not the ScreenShots subfolder. fullName is the game-side path from the viewport; convert to a Linux path via the Proton prefix or use call.py detectedScreenshot.";
        if (hideOverlay) output["hideOverlay"] = true;
        if (forceRes) {
            output["forceRes"] = true;
            output["width"] = int(width);
            output["height"] = int(height);
        }
        return MakeSuccess(output);
    }

    Json::Value@ GetBlocks(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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

            bool isFree = false;
            if (filterFree && isFree != wantFree) continue;

            if (hasCenter) {
                if (world) {
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
        if (editor is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        return MakeSuccess(InventorySummary(editor.PluginMapType));
    }












    Json::Value@ PlaceBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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



    Json::Value@ RemoveBlock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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
        if (editor is null || editor.Challenge is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
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





    Json::Value@ Undo(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        Json::Value output = Json::Object();
        output["undone"] = editor.PluginMapType.Undo();
        return MakeSuccess(output);
    }

    Json::Value@ Redo(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        Json::Value output = Json::Object();
        output["redone"] = editor.PluginMapType.Redo();
        return MakeSuccess(output);
    }
}
