namespace TmMcp {
    class InventoryBrowseState {
        int remaining;
        bool truncated;
        bool includeArticles;
        string query;

        InventoryBrowseState(int limit, bool includeArticles, const string &in query) {
            this.remaining = limit;
            this.truncated = false;
            this.includeArticles = includeArticles;
            this.query = query.ToLower();
        }
    }

    string InventoryNodeName(CGameCtnArticleNode@ node) {
        if (node is null) return "";
        string name = string(node.Name);
        if (name.Length > 0) return name;
        name = string(node.NodeName);
        if (name.Length > 0) return name;
        return string(node.IdName);
    }

    string InventoryNodeRootName(int index) {
        if (index == 0) return "crashBlocks";
        if (index == 1) return "blocks";
        if (index == 2) return "grass";
        if (index == 3) return "items";
        if (index == 4) return "macroblocks";
        if (index == 9) return "plugins";
        return "root-" + index;
    }

    int InventoryRootIndexFromName(const string &in root) {
        string normalized = root.ToLower();
        if (normalized == "crashblocks" || normalized == "crash-blocks") return 0;
        if (normalized == "blocks" || normalized == "block") return 1;
        if (normalized == "grass" || normalized == "terrain") return 2;
        if (normalized == "items" || normalized == "item") return 3;
        if (normalized == "macroblocks" || normalized == "macroblock") return 4;
        if (normalized == "plugins" || normalized == "plugin") return 9;
        return -1;
    }

    bool InventoryNodeMatches(CGameCtnArticleNode@ node, const string &in query) {
        if (query.Length == 0) return true;
        if (node is null) return false;
        if (string(node.Name).ToLower().Contains(query)) return true;
        if (string(node.NodeName).ToLower().Contains(query)) return true;
        return string(node.IdName).ToLower().Contains(query);
    }

    bool InventoryDescendantMatches(CGameCtnArticleNode@ node, const string &in query, bool includeArticles, int depth) {
        if (InventoryNodeMatches(node, query)) return true;
        if (query.Length == 0 || depth <= 0) return false;
        auto dir = cast<CGameCtnArticleNodeDirectory>(node);
        if (dir is null) return false;
        for (uint i = 0; i < dir.ChildNodes.Length; i++) {
            auto child = dir.ChildNodes[i];
            if (child is null) continue;
            if (!child.IsDirectory && !includeArticles) continue;
            if (InventoryDescendantMatches(child, query, includeArticles, depth - 1)) return true;
        }
        return false;
    }

    bool InventoryChildMatchesPath(CGameCtnArticleNode@ node, const string &in partLower) {
        if (node is null) return false;
        if (string(node.Name).ToLower() == partLower) return true;
        if (string(node.NodeName).ToLower() == partLower) return true;
        return string(node.IdName).ToLower() == partLower;
    }

    CGameCtnArticleNode@ FindInventoryChild(CGameCtnArticleNodeDirectory@ dir, const string &in part) {
        if (dir is null) return null;
        string partLower = part.ToLower();
        for (uint i = 0; i < dir.ChildNodes.Length; i++) {
            auto child = dir.ChildNodes[i];
            if (InventoryChildMatchesPath(child, partLower)) return child;
        }
        return null;
    }

    CGameCtnArticleNode@ FollowInventoryPath(CGameCtnArticleNode@ root, const string &in rawPath, string &out err) {
        err = "";
        if (rawPath.Length == 0) return root;
        auto parts = rawPath.Replace("\\", "/").Split("/");
        CGameCtnArticleNode@ current = root;
        for (uint i = 0; i < parts.Length; i++) {
            string part = parts[i].Trim();
            if (part.Length == 0) continue;
            auto dir = cast<CGameCtnArticleNodeDirectory>(current);
            if (dir is null) {
                err = "path component is not a directory before: " + part;
                return null;
            }
            @current = FindInventoryChild(dir, part);
            if (current is null) {
                err = "inventory path component not found: " + part;
                return null;
            }
        }
        return current;
    }

    Json::Value InventoryCollectorToJson(CGameCtnArticleNodeArticle@ article) {
        Json::Value output = Json::Object();
        if (article is null) return output;
        auto collector = article.GetCollectorNod();
        if (collector is null) return output;

        auto blockInfo = cast<CGameCtnBlockInfo>(collector);
        if (blockInfo !is null) return ModelToJson(blockInfo, false);

        auto itemModel = cast<CGameItemModel>(collector);
        if (itemModel !is null) return ItemModelToJson(itemModel);

        auto macroblockInfo = cast<CGameCtnMacroBlockInfo>(collector);
        if (macroblockInfo !is null) return MacroblockModelToJson(macroblockInfo);

        output["idName"] = collector.IdName;
        return output;
    }

    Json::Value InventoryNodeToJson(CGameCtnArticleNode@ node, int depth, InventoryBrowseState@ state, const string &in path) {
        Json::Value output = Json::Object();
        if (node is null) return output;
        output["name"] = node.Name;
        output["nodeName"] = node.NodeName;
        output["idName"] = node.IdName;
        output["path"] = path;
        output["isDirectory"] = node.IsDirectory;

        auto dir = cast<CGameCtnArticleNodeDirectory>(node);
        if (dir !is null) {
            output["type"] = "directory";
            output["hasChildDirectory"] = dir.HasChildDirectory;
            output["hasChildArticle"] = dir.HasChildArticle;
            output["childCount"] = int(dir.ChildNodes.Length);
            if (depth > 0 && state.remaining > 0) {
                Json::Value children = Json::Array();
                for (uint i = 0; i < dir.ChildNodes.Length; i++) {
                    if (state.remaining <= 0) {
                        state.truncated = true;
                        break;
                    }
                    auto child = dir.ChildNodes[i];
                    if (child is null) continue;
                    if (!child.IsDirectory && !state.includeArticles) continue;
                    if (state.query.Length > 0 && !InventoryDescendantMatches(child, state.query, state.includeArticles, depth - 1)) continue;

                    state.remaining--;
                    string childName = InventoryNodeName(child);
                    string childPath = path.Length == 0 ? childName : path + "/" + childName;
                    children.Add(InventoryNodeToJson(child, depth - 1, state, childPath));
                }
                output["children"] = children;
                output["returnedChildren"] = int(children.Length);
            }
            return output;
        }

        auto article = cast<CGameCtnArticleNodeArticle>(node);
        output["type"] = "article";
        output["collector"] = InventoryCollectorToJson(article);
        return output;
    }

    Json::Value InventoryRootsToJson(CGameEditorGenericInventory@ inv, int depth, InventoryBrowseState@ state) {
        Json::Value output = Json::Object();
        output["type"] = "root-list";
        output["name"] = "roots";
        output["isDirectory"] = true;
        output["childCount"] = int(inv.RootNodes.Length);

        Json::Value roots = Json::Array();
        for (uint i = 0; i < inv.RootNodes.Length; i++) {
            if (state.remaining <= 0) {
                state.truncated = true;
                break;
            }
            auto root = inv.RootNodes[i];
            if (root is null) continue;
            if (state.query.Length > 0 && !InventoryDescendantMatches(root, state.query, state.includeArticles, depth - 1)) continue;
            state.remaining--;
            string rootPath = InventoryNodeRootName(int(i));
            roots.Add(InventoryNodeToJson(root, depth - 1, state, rootPath));
        }
        output["children"] = roots;
        output["returnedChildren"] = int(roots.Length);
        return output;
    }

    Json::Value@ BrowseInventoryTree(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        auto inv = editor.PluginMapType.Inventory;
        if (inv is null) return MakeError("inventory not available");

        string rootName = input.HasKey("root") ? string(input["root"]) : "root";
        string path = input.HasKey("path") ? string(input["path"]) : "";
        int depth = input.HasKey("depth") ? int(input["depth"]) : 1;
        if (depth < 0) depth = 0;
        if (depth > 5) depth = 5;
        int limit = input.HasKey("limit") ? int(input["limit"]) : 80;
        if (limit < 1) limit = 1;
        if (limit > 500) limit = 500;
        bool includeArticles = input.HasKey("includeArticles") ? bool(input["includeArticles"]) : true;
        string query = input.HasKey("query") ? string(input["query"]) : "";

        InventoryBrowseState state(limit, includeArticles, query);
        Json::Value node = Json::Object();
        int rootIndex = input.HasKey("rootIndex") ? int(input["rootIndex"]) : InventoryRootIndexFromName(rootName);

        if (rootName.ToLower() == "root" && !input.HasKey("rootIndex")) {
            node = InventoryRootsToJson(inv, depth, state);
        } else {
            CGameCtnArticleNode@ rootNode;
            if (rootName.ToLower() == "current") {
                @rootNode = inv.CurrentDirectory;
                if (rootNode is null) @rootNode = inv.CurrentRootNode;
            } else {
                if (rootIndex < 0 || rootIndex >= int(inv.RootNodes.Length)) return MakeError("unknown inventory root: " + rootName);
                @rootNode = inv.RootNodes[uint(rootIndex)];
            }
            if (rootNode is null) return MakeError("inventory root not available: " + rootName);

            string err;
            auto target = FollowInventoryPath(rootNode, path, err);
            if (target is null) return MakeError(err);
            string nodePath = path.Length > 0 ? path : (rootName.ToLower() == "current" ? "current" : InventoryNodeRootName(rootIndex));
            node = InventoryNodeToJson(target, depth, state, nodePath);
        }

        Json::Value output = Json::Object();
        output["root"] = rootName;
        output["rootIndex"] = rootIndex;
        output["path"] = path;
        output["depth"] = depth;
        output["limit"] = limit;
        output["query"] = query;
        output["includeArticles"] = includeArticles;
        output["truncated"] = state.truncated;
        output["returned"] = limit - state.remaining;
        output["node"] = node;
        output["inventory"] = InventorySummary(editor.PluginMapType);
        return MakeSuccess(output);
    }
}
