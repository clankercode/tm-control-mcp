#if DEPENDENCY_EDITOR
namespace TmMcp {
    string EditModeToString(CGameEditorPluginMap::EditMode mode) {
        if (mode == CGameEditorPluginMap::EditMode::Unknown) return "Unknown";
        if (mode == CGameEditorPluginMap::EditMode::Place) return "Place";
        if (mode == CGameEditorPluginMap::EditMode::FreeLook) return "FreeLook";
        if (mode == CGameEditorPluginMap::EditMode::Erase) return "Erase";
        if (mode == CGameEditorPluginMap::EditMode::Pick) return "Pick";
        return "EditMode(" + int(mode) + ")";
    }

    string PlaceModeToString(CGameEditorPluginMap::EPlaceMode mode) {
        if (mode == CGameEditorPluginMap::EPlaceMode::Unknown) return "Unknown";
        if (mode == CGameEditorPluginMap::EPlaceMode::Block) return "Block";
        if (mode == CGameEditorPluginMap::EPlaceMode::Macroblock) return "Macroblock";
        if (mode == CGameEditorPluginMap::EPlaceMode::Plugin) return "Plugin";
        if (mode == CGameEditorPluginMap::EPlaceMode::CustomSelection) return "CustomSelection";
        if (mode == CGameEditorPluginMap::EPlaceMode::GhostBlock) return "GhostBlock";
        if (mode == CGameEditorPluginMap::EPlaceMode::Item) return "Item";
        if (mode == CGameEditorPluginMap::EPlaceMode::FreeBlock) return "FreeBlock";
        if (mode == CGameEditorPluginMap::EPlaceMode::FreeMacroblock) return "FreeMacroblock";
        return "PlaceMode(" + int(mode) + ")";
    }

    bool EditModeFromString(const string &in raw, CGameEditorPluginMap::EditMode &out mode) {
        string s = raw.ToLower().Replace("_", "").Replace("-", "").Replace(" ", "");
        if (s == "place") { mode = CGameEditorPluginMap::EditMode::Place; return true; }
        if (s == "freelook" || s == "free") { mode = CGameEditorPluginMap::EditMode::FreeLook; return true; }
        if (s == "erase" || s == "delete" || s == "remove") { mode = CGameEditorPluginMap::EditMode::Erase; return true; }
        if (s == "pick" || s == "eyedropper") { mode = CGameEditorPluginMap::EditMode::Pick; return true; }
        if (s == "unknown") { mode = CGameEditorPluginMap::EditMode::Unknown; return true; }
        return false;
    }

    bool PlaceModeFromString(const string &in raw, CGameEditorPluginMap::EPlaceMode &out mode) {
        string s = raw.ToLower().Replace("_", "").Replace("-", "").Replace(" ", "");
        if (s == "block" || s == "normalblock") { mode = CGameEditorPluginMap::EPlaceMode::Block; return true; }
        if (s == "freeblock") { mode = CGameEditorPluginMap::EPlaceMode::FreeBlock; return true; }
        if (s == "ghostblock" || s == "ghost") { mode = CGameEditorPluginMap::EPlaceMode::GhostBlock; return true; }
        if (s == "item") { mode = CGameEditorPluginMap::EPlaceMode::Item; return true; }
        if (s == "macroblock" || s == "mb") { mode = CGameEditorPluginMap::EPlaceMode::Macroblock; return true; }
        if (s == "freemacroblock" || s == "freemb") { mode = CGameEditorPluginMap::EPlaceMode::FreeMacroblock; return true; }
        if (s == "customselection" || s == "custom") { mode = CGameEditorPluginMap::EPlaceMode::CustomSelection; return true; }
        if (s == "plugin") { mode = CGameEditorPluginMap::EPlaceMode::Plugin; return true; }
        return false;
    }

    Json::Value EditModeStatusJson(CGameCtnEditorFree@ editor) {
        Json::Value output = Json::Object();
        if (editor is null || editor.PluginMapType is null) {
            output["available"] = false;
            return output;
        }
        auto em = editor.PluginMapType.EditMode;
        auto pm = editor.PluginMapType.PlaceMode;
        output["available"] = true;
        output["editMode"] = int(em);
        output["editModeName"] = EditModeToString(em);
        output["placeMode"] = int(pm);
        output["placeModeName"] = PlaceModeToString(pm);
        output["isBlockPlacement"] = Editor::IsInBlockPlacementMode(editor, false);
        output["isFreeBlockPlacement"] = Editor::IsInFreeBlockPlacementMode(editor, false);
        output["isMacroblockPlacement"] = Editor::IsInMacroblockPlacementMode(editor, false);
        output["isAnyItemPlacement"] = Editor::IsInAnyItemPlacementMode(editor, false);
        if (editor.CurrentBlockInfo !is null) {
            output["currentBlockInfo"] = BlockInfoToJson(editor.CurrentBlockInfo);
        }
        if (editor.CurrentItemModel !is null) {
            Json::Value im = Json::Object();
            im["name"] = string(editor.CurrentItemModel.Name);
            im["idName"] = string(editor.CurrentItemModel.IdName);
            output["currentItemModel"] = im;
        }
        if (editor.CurrentMacroBlockInfo !is null) {
            output["currentMacroBlockInfo"] = MacroblockModelToJson(editor.CurrentMacroBlockInfo);
        }
        return output;
    }

    Json::Value@ ControlEditMode(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) {
            return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        }

        string action = input.HasKey("action") ? string(input["action"]).ToLower() : "status";
        if (action.Length == 0) action = "status";

        Json::Value before = EditModeStatusJson(editor);
        Json::Value actions = Json::Array();

        if (action == "status") {
            Json::Value output = before;
            output["action"] = "status";
            return MakeSuccess(output);
        }

        try {
            if (action == "setedit" || action == "set_edit" || action == "edit") {
                if (!input.HasKey("editMode")) return MakeError("missing editMode", "INVALID_INPUT");
                CGameEditorPluginMap::EditMode em;
                if (!EditModeFromString(string(input["editMode"]), em)) {
                    return MakeError("unknown editMode: " + string(input["editMode"]), "INVALID_INPUT", false, "", "Place|Erase|FreeLook|Pick|SelectionAdd|SelectionRemove");
                }
                Editor::SetEditMode(editor, em);
                actions.Add("setEdit:" + EditModeToString(em));
            } else if (action == "setplace" || action == "set_place" || action == "place") {
                if (!input.HasKey("placeMode")) return MakeError("missing placeMode", "INVALID_INPUT");
                CGameEditorPluginMap::EPlaceMode pm;
                if (!PlaceModeFromString(string(input["placeMode"]), pm)) {
                    return MakeError("unknown placeMode: " + string(input["placeMode"]), "INVALID_INPUT", false, "", "Block|FreeBlock|GhostBlock|Item|Macroblock|FreeMacroblock|CustomSelection|...");
                }
                // Ensure Place edit mode when switching placement tools
                if (editor.PluginMapType.EditMode != CGameEditorPluginMap::EditMode::Place
                    && editor.PluginMapType.EditMode != CGameEditorPluginMap::EditMode::Erase) {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    actions.Add("setEdit:Place");
                }
                Editor::SetPlacementMode(editor, pm);
                actions.Add("setPlace:" + PlaceModeToString(pm));
            } else if (action == "set") {
                if (input.HasKey("editMode")) {
                    CGameEditorPluginMap::EditMode em;
                    if (!EditModeFromString(string(input["editMode"]), em)) {
                        return MakeError("unknown editMode: " + string(input["editMode"]), "INVALID_INPUT");
                    }
                    Editor::SetEditMode(editor, em);
                    actions.Add("setEdit:" + EditModeToString(em));
                }
                if (input.HasKey("placeMode")) {
                    CGameEditorPluginMap::EPlaceMode pm;
                    if (!PlaceModeFromString(string(input["placeMode"]), pm)) {
                        return MakeError("unknown placeMode: " + string(input["placeMode"]), "INVALID_INPUT");
                    }
                    if (editor.PluginMapType.EditMode != CGameEditorPluginMap::EditMode::Place
                        && editor.PluginMapType.EditMode != CGameEditorPluginMap::EditMode::Erase
                        && editor.PluginMapType.EditMode != CGameEditorPluginMap::EditMode::Pick) {
                        Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                        actions.Add("setEdit:Place");
                    }
                    Editor::SetPlacementMode(editor, pm);
                    actions.Add("setPlace:" + PlaceModeToString(pm));
                }
                if (!input.HasKey("editMode") && !input.HasKey("placeMode")) {
                    return MakeError("set requires editMode and/or placeMode", "INVALID_INPUT");
                }
            } else {
                return MakeError("action must be status|set|setEdit|setPlace", "INVALID_INPUT");
            }

            // Optional model select after mode change
            if (input.HasKey("blockName")) {
                string blockName = string(input["blockName"]);
                bool isTerrain = false;
                auto blockInfo = ResolveBlockModel(editor.PluginMapType, blockName, isTerrain);
                if (blockInfo is null) return MakeError("block not found: " + blockName, "NOT_FOUND");
                Editor::SetSelectedBlockInfo(editor, blockInfo);
                actions.Add("selectBlock:" + blockName);
            }
            if (input.HasKey("itemPath")) {
                auto sel = SelectItemModelInternal(editor, string(input["itemPath"]));
                if (!bool(sel["ok"])) return MakeError(string(sel["error"]), "NOT_FOUND");
                actions.Add("selectItem:" + string(input["itemPath"]));
            }
            if (input.HasKey("macroblock") || input.HasKey("macroblockName")) {
                string mbName = input.HasKey("macroblock") ? string(input["macroblock"]) : string(input["macroblockName"]);
                auto sel = SelectMacroblockModelInternal(editor, mbName);
                if (!bool(sel["ok"])) return MakeError(string(sel["error"]), "NOT_FOUND");
                actions.Add("selectMacroblock:" + mbName);
            }
        } catch {
            return MakeError("ControlEditMode failed: " + getExceptionInfo(), "UNKNOWN", true);
        }

        yield();
        Json::Value output = EditModeStatusJson(editor);
        output["action"] = action;
        output["actions"] = actions;
        output["before"] = before;
        return MakeSuccess(output);
    }

    Json::Value SelectItemModelInternal(CGameCtnEditorFree@ editor, const string &in itemPath) {
        Json::Value result = Json::Object();
        result["ok"] = false;
        if (editor is null || editor.PluginMapType is null || editor.PluginMapType.Inventory is null) {
            result["error"] = "editor inventory unavailable";
            return result;
        }
        auto model = ResolveItemModel(itemPath);
        if (model is null) {
            result["error"] = "item not found: " + itemPath;
            return result;
        }

        // Prefer inventory article select so CurrentItemModel updates
        auto inv = editor.PluginMapType.Inventory;
        string err;
        auto root = inv.RootNodes.Length > 3 ? inv.RootNodes[3] : null;
        CGameCtnArticleNodeArticle@ found;
        @found = FindArticleByCollectorName(root, itemPath, model);
        if (found !is null) {
            Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
            Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Item);
            inv.SelectArticle(found);
            result["ok"] = true;
            result["method"] = "SelectArticle";
            result["idName"] = string(model.IdName);
            return result;
        }

        // Fallback: still enter item place mode; path-place remains canonical
        Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
        Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Item);
        result["ok"] = true;
        result["method"] = "placeModeOnly";
        result["warning"] = "inventory article not found; set Item place mode only. Prefer PlaceItemViaEditorPlusPlus for placement.";
        result["idName"] = string(model.IdName);
        return result;
    }

    Json::Value SelectMacroblockModelInternal(CGameCtnEditorFree@ editor, const string &in mbName) {
        Json::Value result = Json::Object();
        result["ok"] = false;
        if (editor is null || editor.PluginMapType is null) {
            result["error"] = "editor unavailable";
            return result;
        }
        string lower = mbName.ToLower();
        CGameCtnMacroBlockInfo@ model;
        for (uint i = 0; i < editor.PluginMapType.MacroblockModels.Length; i++) {
            auto m = editor.PluginMapType.MacroblockModels[i];
            if (m is null) continue;
            if (string(m.Name).ToLower() == lower || string(m.IdName).ToLower() == lower
                || string(m.Name).ToLower().Contains(lower) || string(m.IdName).ToLower().Contains(lower)) {
                @model = m;
                break;
            }
        }
        if (model is null) {
            result["error"] = "macroblock model not found: " + mbName;
            return result;
        }

        // Try inventory select
        if (editor.PluginMapType.Inventory !is null && editor.PluginMapType.Inventory.RootNodes.Length > 4) {
            auto root = editor.PluginMapType.Inventory.RootNodes[4];
            auto article = FindArticleByMacroblock(root, model);
            if (article !is null) {
                Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Macroblock);
                editor.PluginMapType.Inventory.SelectArticle(article);
                result["ok"] = true;
                result["method"] = "SelectArticle";
                result["name"] = string(model.Name);
                return result;
            }
        }

        Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
        Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Macroblock);
        result["ok"] = true;
        result["method"] = "placeModeOnly";
        result["warning"] = "macroblock article not found in inventory tree; place mode set only";
        result["name"] = string(model.Name);
        return result;
    }

    CGameCtnArticleNodeArticle@ FindArticleByCollectorName(CGameCtnArticleNode@ node, const string &in itemPath, CGameItemModel@ model, int depth = 12) {
        if (node is null || depth < 0) return null;
        auto article = cast<CGameCtnArticleNodeArticle>(node);
        if (article !is null) {
            auto collector = article.GetCollectorNod();
            auto im = cast<CGameItemModel>(collector);
            if (im !is null) {
                if (im is model) return article;
                string id = string(im.IdName).ToLower();
                string nm = string(im.Name).ToLower();
                string path = itemPath.ToLower();
                if (id == path || nm == path || path.EndsWith(id) || path.EndsWith(nm) || id.EndsWith(path) || nm.Contains(path)) {
                    return article;
                }
            }
        }
        auto dir = cast<CGameCtnArticleNodeDirectory>(node);
        if (dir is null) return null;
        for (uint i = 0; i < dir.ChildNodes.Length; i++) {
            auto found = FindArticleByCollectorName(dir.ChildNodes[i], itemPath, model, depth - 1);
            if (found !is null) return found;
        }
        return null;
    }

    CGameCtnArticleNodeArticle@ FindArticleByMacroblock(CGameCtnArticleNode@ node, CGameCtnMacroBlockInfo@ model, int depth = 12) {
        if (node is null || depth < 0 || model is null) return null;
        auto article = cast<CGameCtnArticleNodeArticle>(node);
        if (article !is null) {
            auto mb = cast<CGameCtnMacroBlockInfo>(article.GetCollectorNod());
            if (mb !is null) {
                if (mb is model) return article;
                if (string(mb.IdName) == string(model.IdName)) return article;
                if (string(mb.Name) == string(model.Name)) return article;
            }
        }
        auto dir = cast<CGameCtnArticleNodeDirectory>(node);
        if (dir is null) return null;
        for (uint i = 0; i < dir.ChildNodes.Length; i++) {
            auto found = FindArticleByMacroblock(dir.ChildNodes[i], model, depth - 1);
            if (found !is null) return found;
        }
        return null;
    }

    Json::Value@ SelectItemModel(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        if (!input.HasKey("itemPath") && !input.HasKey("path")) {
            return MakeError("missing itemPath", "INVALID_INPUT");
        }
        string path = input.HasKey("itemPath") ? string(input["itemPath"]) : string(input["path"]);
        auto sel = SelectItemModelInternal(editor, path);
        if (!bool(sel["ok"])) return MakeError(string(sel["error"]), "NOT_FOUND");
        Json::Value output = EditModeStatusJson(editor);
        output["selected"] = sel;
        return MakeSuccess(output);
    }

    Json::Value@ SelectMacroblockModel(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        if (!input.HasKey("name") && !input.HasKey("macroblock")) {
            return MakeError("missing name", "INVALID_INPUT");
        }
        string name = input.HasKey("name") ? string(input["name"]) : string(input["macroblock"]);
        auto sel = SelectMacroblockModelInternal(editor, name);
        if (!bool(sel["ok"])) return MakeError(string(sel["error"]), "NOT_FOUND");
        Json::Value output = EditModeStatusJson(editor);
        output["selected"] = sel;
        return MakeSuccess(output);
    }
}
#endif
