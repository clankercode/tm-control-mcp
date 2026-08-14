// Editor++ is an optional dependency (info.toml optional_dependencies).
// DEPENDENCY_EDITOR is defined only when Editor is installed at compile time.

namespace TmMcp {
    bool IsEditorPlusPlusAvailable() {
#if DEPENDENCY_EDITOR
        auto p = Meta::GetPluginFromID("Editor");
        return p !is null && p.Enabled;
#else
        return false;
#endif
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

    Json::Value@ EditorPlusPlusMissingError() {
        return MissingPluginError("Editor");
    }

    bool ToolRequiresEditorPlusPlus(const string &in name) {
        return name == "FocusCamera"
            || name == "GetInventorySummary"
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
}

#if !DEPENDENCY_EDITOR
namespace TmMcp {
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
    Json::Value@ GetInventorySummary(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ FindInventory(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ RefreshInventory(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ FocusCamera(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SelectBlockModel(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    Json::Value@ SpikeGizmoVehiclePreview(Json::Value &in input) { return EditorPlusPlusMissingError(); }
    void RememberMapDelta(const string &in tool, Json::Value@ mapPre, Json::Value@ mapPost) {}
}
#endif
