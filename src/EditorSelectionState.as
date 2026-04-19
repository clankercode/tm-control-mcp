namespace TmMcp {
    Json::Value BlockInfoToJson(CGameCtnBlockInfo@ blockInfo) {
        if (blockInfo is null) return Json::Value();
        Json::Value obj = Json::Object();
        obj["name"] = blockInfo.Name;
        obj["idName"] = blockInfo.IdName;
        obj["groundVariants"] = int(blockInfo.AdditionalVariantsGround.Length + 1);
        obj["airVariants"] = int(blockInfo.AdditionalVariantsAir.Length + 1);
        return obj;
    }

    Json::Value@ GetEditorSelectionState(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Cursor is null) {
            return MakeError("editor not available");
        }

        Json::Value output = Json::Object();
        output["gizmoActive"] = Editor::IsGizmoActive();
        output["editMode"] = int(editor.PluginMapType.EditMode);
        output["placeMode"] = int(editor.PluginMapType.PlaceMode);
        output["itemPlacementMode"] = Editor::GetItemPlacementModeInt(false, false);
        output["isBlockPlacement"] = Editor::IsInBlockPlacementMode(editor, false);
        output["isFreeBlockPlacement"] = Editor::IsInFreeBlockPlacementMode(editor, false);
        output["isMacroblockPlacement"] = Editor::IsInMacroblockPlacementMode(editor, false);
        output["isAnyItemPlacement"] = Editor::IsInAnyItemPlacementMode(editor, false);
        output["cursorCoord"] = CoordToJson(editor.Cursor.Coord);
        output["cursorDir"] = int(editor.Cursor.Dir);
        output["currentBlockVariant"] = int(Editor::GetCurrentBlockVariant(editor.Cursor));
        output["currentBlockInfo"] = BlockInfoToJson(editor.CurrentBlockInfo);
        output["currentGhostBlockInfo"] = BlockInfoToJson(editor.CurrentGhostBlockInfo);
        output["selectedBlockInfo"] = BlockInfoToJson(Editor::GetSelectedBlockInfo(editor));

        auto picked = Editor::GetPickedBlock();
        if (picked is null) {
            output["pickedBlock"] = Json::Value();
        } else {
            output["pickedBlock"] = BlockToJson(picked);
        }
        return MakeSuccess(output);
    }
}
