#if DEPENDENCY_EDITOR
namespace TmMcp {
    Json::Value@ ControlInventory(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.PluginMapType.Inventory is null) {
            return MakeError("editor inventory not available", "NOT_IN_EDITOR", true, "Editor");
        }
        auto inv = editor.PluginMapType.Inventory;
        string action = input.HasKey("action") ? string(input["action"]).ToLower() : "status";
        if (action.Length == 0) action = "status";

        if (action == "status") {
            Json::Value output = Json::Object();
            output["action"] = "status";
            output["rootCount"] = int(inv.RootNodes.Length);
            output["inventory"] = InventorySummary(editor.PluginMapType);
            output["editMode"] = EditModeStatusJson(editor);
            return MakeSuccess(output);
        }

        string typeName = input.HasKey("type") ? string(input["type"]).ToLower() : "item";
        int rootIndex = InventoryRootIndexFromName(typeName);
        if (rootIndex < 0) {
            // allow explicit root name
            rootIndex = InventoryRootIndexFromName(input.HasKey("root") ? string(input["root"]) : typeName);
        }
        if (rootIndex < 0) {
            if (typeName == "block" || typeName == "blocks") rootIndex = 1;
            else if (typeName == "item" || typeName == "items") rootIndex = 3;
            else if (typeName == "macroblock" || typeName == "macroblocks") rootIndex = 4;
            else rootIndex = 3;
        }
        if (rootIndex < 0 || rootIndex >= int(inv.RootNodes.Length)) {
            return MakeError("inventory root unavailable for type=" + typeName, "NOT_FOUND");
        }
        auto root = inv.RootNodes[uint(rootIndex)];
        bool isItem = rootIndex == 3;

        if (action == "openfolder" || action == "open_folder" || action == "folder") {
            string path = input.HasKey("path") ? string(input["path"]) : "";
            string err;
            auto node = FollowInventoryPath(root, path, err);
            if (node is null) return MakeError(err.Length > 0 ? err : "folder not found", "NOT_FOUND");
            auto dir = cast<CGameCtnArticleNodeDirectory>(node);
            if (dir is null) return MakeError("path is not a folder: " + path, "INVALID_INPUT");
            try {
                if (isItem) {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Item);
                } else if (rootIndex == 4) {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Macroblock);
                } else {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Block);
                }
                inv.SelectNode(dir);
            } catch {
                return MakeError("SelectNode failed: " + getExceptionInfo(), "UNKNOWN", true);
            }
            Json::Value output = Json::Object();
            output["action"] = "openFolder";
            output["path"] = path;
            output["type"] = typeName;
            output["nodeName"] = InventoryNodeName(dir);
            output["editMode"] = EditModeStatusJson(editor);
            return MakeSuccess(output);
        }

        if (action == "select" || action == "open" || action == "set") {
            string path = input.HasKey("path") ? string(input["path"]) : "";
            string query = input.HasKey("query") ? string(input["query"]) : "";
            CGameCtnArticleNodeArticle@ article;

            if (path.Length > 0) {
                string err;
                auto node = FollowInventoryPath(root, path, err);
                if (node is null && query.Length == 0) {
                    // path may be a bare article name — search tree
                    @article = FindArticleRecursive(root, path, 14);
                    if (article is null) return MakeError(err.Length > 0 ? err : ("article not found: " + path), "NOT_FOUND");
                } else if (node !is null) {
                    @article = cast<CGameCtnArticleNodeArticle>(node);
                    if (article is null) {
                        return MakeError("path points to a folder; use action=openFolder or append article name", "INVALID_INPUT");
                    }
                }
            }
            if (article is null && query.Length > 0) {
                @article = FindArticleRecursive(root, query, 14);
            }
            if (article is null && path.Length > 0) {
                @article = FindArticleRecursive(root, path, 14);
            }
            if (article is null) {
                return MakeError("article not found (provide path or query)", "NOT_FOUND", false, "", "BrowseInventoryTree / FindInventory first");
            }

            try {
                if (isItem) {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Item);
                } else if (rootIndex == 4) {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Macroblock);
                } else {
                    Editor::SetEditMode(editor, CGameEditorPluginMap::EditMode::Place);
                    Editor::SetPlacementMode(editor, CGameEditorPluginMap::EPlaceMode::Block);
                }
                inv.SelectArticle(article);
            } catch {
                return MakeError("SelectArticle failed: " + getExceptionInfo(), "UNKNOWN", true);
            }

            yield();
            Json::Value output = Json::Object();
            output["action"] = "select";
            output["type"] = typeName;
            output["path"] = path;
            output["query"] = query;
            output["nodeName"] = InventoryNodeName(article);
            output["collector"] = InventoryCollectorToJson(article);
            output["method"] = "Inventory.SelectArticle";
            output["editMode"] = EditModeStatusJson(editor);
            output["note"] = "Path-based Place* APIs remain preferred for headless placement; inventory select is for UI-native picker parity.";
            return MakeSuccess(output);
        }

        return MakeError("action must be status|select|openFolder", "INVALID_INPUT");
    }

    CGameCtnArticleNodeArticle@ FindArticleRecursive(CGameCtnArticleNode@ node, const string &in query, int depth) {
        if (node is null || depth < 0 || query.Length == 0) return null;
        string q = query.ToLower();
        auto article = cast<CGameCtnArticleNodeArticle>(node);
        if (article !is null) {
            if (InventoryNodeMatches(article, q)) return article;
            // also match collector names
            auto collector = article.GetCollectorNod();
            if (collector !is null) {
                auto block = cast<CGameCtnBlockInfo>(collector);
                if (block !is null) {
                    if (string(block.Name).ToLower().Contains(q) || string(block.IdName).ToLower().Contains(q)) return article;
                }
                auto item = cast<CGameItemModel>(collector);
                if (item !is null) {
                    if (string(item.Name).ToLower().Contains(q) || string(item.IdName).ToLower().Contains(q)) return article;
                }
                auto mb = cast<CGameCtnMacroBlockInfo>(collector);
                if (mb !is null) {
                    if (string(mb.Name).ToLower().Contains(q) || string(mb.IdName).ToLower().Contains(q)) return article;
                }
            }
        }
        auto dir = cast<CGameCtnArticleNodeDirectory>(node);
        if (dir is null) return null;
        for (uint i = 0; i < dir.ChildNodes.Length; i++) {
            auto found = FindArticleRecursive(dir.ChildNodes[i], query, depth - 1);
            if (found !is null) return found;
        }
        return null;
    }
}
#endif
