// Editor++ (E++) tools moved to the tm-mcp-pack-epp tool pack.
// This plugin no longer depends on Editor++. The old tool names still
// dispatch and return a structured "moved" error pointing at the pack.

namespace TmMcp {
    const string EPP_PACK_ID = "tm-mcp-pack-epp";

    bool IsEditorPlusPlusAvailable() {
        auto p = Meta::GetPluginFromID(EPP_PACK_ID);
        return p !is null && p.Enabled;
    }

    Json::Value@ MissingPluginError(const string &in pluginId) {
        return MakeError(
            pluginId + " is not available. Install/enable that Openplanet plugin.",
            "missing_dependency",
            false,
            "",
            "optional_dependencies: " + pluginId
        );
    }

    Json::Value@ ToolMovedToEppPackError() {
        return MakeError(
            "This E++ tool moved to the " + EPP_PACK_ID + " tool pack. Call " + EPP_PACK_ID + ".<Tool> instead (or install/enable the pack).",
            "moved_to_pack",
            false,
            "",
            EPP_PACK_ID
        );
    }

    Json::Value@ EditorPlusPlusMissingError() {
        return ToolMovedToEppPackError();
    }

    bool ToolRequiresEditorPlusPlus(const string &in name) {
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

    // --- deprecated E++ stubs: names stay dispatchable, return "moved" ---
    Json::Value@ RunGizmoApplyBlock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RunRandomFuzz(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ InspectMacroblockModel(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ListMacroblockInstances(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ PreflightNamedMacroblockPlacement(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SaveNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ LoadNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ListSavedNamedMacroblocks(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ AssertPlacement(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ControlEditMode(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SelectItemModel(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SelectMacroblockModel(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ControlInventory(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ GetEditorSelectionState(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ PlaceBlockViaEditorPlusPlus(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ PlaceItemViaEditorPlusPlus(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ PlaceNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ CreateNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ GetNamedMacroblockTool(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ListNamedMacroblocks(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ClearNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ AddBlockToNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ AddBlocksToNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ AddItemToNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ AddItemsToNamedMacroblock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RemoveRecentBlocks(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RemoveRecentItems(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RemoveBlocksByIndex(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RemoveItemsByIndex(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ControlItemEditor(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ControlMapObjectives(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SetCursorBlock(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ FindInventory(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RefreshInventory(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ FocusCamera(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SelectBlockModel(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ DumpMacroblockHeader(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RunDumpMacroblockHeader(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    void RememberMapDelta(const string &in tool, Json::Value@ mapPre, Json::Value@ mapPost) {}
    Json::Value@ BrowseInventoryTree(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SetAgentTag(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ListTagged(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RemoveByTag(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ ClearTagIndex(Json::Value &in input) { return EditorPlusPlusMissingError(); }
}
