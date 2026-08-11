namespace TmMcp {
    class TaggedObject {
        string tag;
        string kind; // "block" | "item"
        string idName;
        float x;
        float y;
        float z;
        uint placedAtMs;
        int lastKnownIndex;

        TaggedObject() {
            tag = "";
            kind = "";
            idName = "";
            x = 0; y = 0; z = 0;
            placedAtMs = 0;
            lastKnownIndex = -1;
        }
    }

    string g_DefaultAgentTag = "";
    array<TaggedObject@> g_TaggedObjects;
    const uint MCP_TAG_MAX = 4000;
    const float MCP_TAG_POS_EPS = 0.08;

    string ResolvePlacementTag(Json::Value &in input) {
        if (input.HasKey("tag")) {
            string t = string(input["tag"]);
            return t;
        }
        return g_DefaultAgentTag;
    }

    void RecordTaggedPlacement(const string &in tag, const string &in kind, const string &in idName, const vec3 &in pos, int lastIndex = -1) {
        if (tag.Length == 0) return;
        if (g_TaggedObjects.Length >= MCP_TAG_MAX) {
            // Drop oldest 10% to avoid unbounded growth
            uint drop = MCP_TAG_MAX / 10;
            if (drop < 1) drop = 1;
            g_TaggedObjects.RemoveRange(0, drop);
        }
        auto obj = TaggedObject();
        obj.tag = tag;
        obj.kind = kind;
        obj.idName = idName;
        obj.x = pos.x;
        obj.y = pos.y;
        obj.z = pos.z;
        obj.placedAtMs = Time::Now;
        obj.lastKnownIndex = lastIndex;
        g_TaggedObjects.InsertLast(obj);
    }

    void RecordTaggedPlacementsFromPlaceItem(Json::Value &in input, Json::Value@ placeOutput, const string &in itemPath) {
        string tag = ResolvePlacementTag(input);
        if (tag.Length == 0) return;
        if (placeOutput is null || !placeOutput.HasKey("placements")) return;
        auto placements = placeOutput["placements"];
        if (placements.GetType() != Json::Type::Array) return;
        auto editor = GetEditor();
        int afterItems = placeOutput.HasKey("afterItems") ? int(placeOutput["afterItems"]) : -1;
        int beforeItems = placeOutput.HasKey("beforeItems") ? int(placeOutput["beforeItems"]) : -1;
        for (uint i = 0; i < placements.Length; i++) {
            auto p = placements[i];
            if (!bool(p["placed"])) continue;
            vec3 pos = vec3(0, 0, 0);
            if (p.HasKey("pos") && p["pos"].GetType() == Json::Type::Array && p["pos"].Length >= 3) {
                pos = vec3(float(p["pos"][0]), float(p["pos"][1]), float(p["pos"][2]));
            }
            int idx = -1;
            if (beforeItems >= 0 && afterItems > beforeItems) {
                // Best-effort: sequential place indices
                idx = beforeItems + int(i);
                if (idx >= afterItems) idx = afterItems - 1;
            }
            RecordTaggedPlacement(tag, "item", itemPath, pos, idx);
        }
    }

    void RecordTaggedPlacementsFromPlaceBlock(Json::Value &in input, Json::Value@ placeOutput, const string &in blockName) {
        string tag = ResolvePlacementTag(input);
        if (tag.Length == 0) return;
        if (placeOutput is null || !placeOutput.HasKey("placements")) return;
        auto placements = placeOutput["placements"];
        if (placements.GetType() != Json::Type::Array) return;
        int afterBlocks = placeOutput.HasKey("afterBlocks") ? int(placeOutput["afterBlocks"]) : -1;
        int beforeBlocks = placeOutput.HasKey("beforeBlocks") ? int(placeOutput["beforeBlocks"]) : -1;
        for (uint i = 0; i < placements.Length; i++) {
            auto p = placements[i];
            if (!bool(p["placed"])) continue;
            vec3 pos = vec3(0, 0, 0);
            if (p.HasKey("pos") && p["pos"].GetType() == Json::Type::Array && p["pos"].Length >= 3) {
                pos = vec3(float(p["pos"][0]), float(p["pos"][1]), float(p["pos"][2]));
            }
            int idx = -1;
            if (beforeBlocks >= 0 && afterBlocks > beforeBlocks) {
                idx = beforeBlocks + int(i);
                if (idx >= afterBlocks) idx = afterBlocks - 1;
            }
            RecordTaggedPlacement(tag, "block", blockName, pos, idx);
        }
    }

    bool TagMatchesFilter(const string &in tag, const string &in filter, bool prefix) {
        if (filter.Length == 0) return true;
        if (prefix) return tag.StartsWith(filter);
        return tag == filter;
    }

    float PosDist2(const vec3 &in a, float x, float y, float z) {
        float dx = a.x - x;
        float dy = a.y - y;
        float dz = a.z - z;
        return dx * dx + dy * dy + dz * dz;
    }

    bool LiveItemMatches(CGameCtnEditorFree@ editor, int index, const string &in idName, float x, float y, float z, float eps) {
        if (editor is null || editor.Challenge is null || index < 0 || uint(index) >= editor.Challenge.AnchoredObjects.Length) return false;
        auto item = editor.Challenge.AnchoredObjects[uint(index)];
        if (item is null || item.ItemModel is null) return false;
        string name = string(item.ItemModel.IdName);
        string n2 = string(item.ItemModel.Name);
        string idLower = idName.ToLower();
        if (idLower.Length > 0) {
            if (!name.ToLower().Contains(idLower) && !n2.ToLower().Contains(idLower) && idLower != name.ToLower() && idLower != n2.ToLower()) {
                if (!idLower.EndsWith(name.ToLower()) && !name.ToLower().EndsWith(idLower)) return false;
            }
        }
        return PosDist2(item.AbsolutePositionInMap, x, y, z) <= eps * eps;
    }

    int FindLiveItemIndex(CGameCtnEditorFree@ editor, const string &in idName, float x, float y, float z, float eps, int preferredIndex, int &out candidateCount) {
        if (editor is null || editor.Challenge is null) return -1;
        candidateCount = 0;
        if (LiveItemMatches(editor, preferredIndex, idName, x, y, z, eps)) {
            candidateCount = 1;
            return preferredIndex;
        }
        int match = -1;
        for (uint i = 0; i < editor.Challenge.AnchoredObjects.Length; i++) {
            if (!LiveItemMatches(editor, int(i), idName, x, y, z, eps)) continue;
            match = int(i);
            candidateCount++;
        }
        return candidateCount == 1 ? match : -1;
    }

    bool LiveBlockMatches(CGameCtnEditorFree@ editor, int index, const string &in idName, float x, float y, float z, float eps) {
        if (editor is null || editor.Challenge is null || index < 0 || uint(index) >= editor.Challenge.Blocks.Length) return false;
        auto block = editor.Challenge.Blocks[uint(index)];
        if (block is null || block.BlockInfo is null) return false;
        string name = string(block.BlockInfo.IdName);
        string n2 = string(block.BlockInfo.Name);
        string idLower = idName.ToLower();
        if (idLower.Length > 0 && name.ToLower() != idLower && n2.ToLower() != idLower
            && !name.ToLower().Contains(idLower) && !n2.ToLower().Contains(idLower)) return false;
        vec3 pos;
        try {
            pos = Editor::GetBlockLocation(block, true);
        } catch {
            pos = vec3(float(block.Coord.x) * 32.0, (float(block.Coord.y) - 8.0) * 8.0, float(block.Coord.z) * 32.0);
        }
        return PosDist2(pos, x, y, z) <= eps * eps;
    }

    int FindLiveBlockIndex(CGameCtnEditorFree@ editor, const string &in idName, float x, float y, float z, float eps, int preferredIndex, int &out candidateCount) {
        if (editor is null || editor.Challenge is null) return -1;
        candidateCount = 0;
        if (LiveBlockMatches(editor, preferredIndex, idName, x, y, z, eps)) {
            candidateCount = 1;
            return preferredIndex;
        }
        int match = -1;
        for (uint i = 0; i < editor.Challenge.Blocks.Length; i++) {
            if (!LiveBlockMatches(editor, int(i), idName, x, y, z, eps)) continue;
            match = int(i);
            candidateCount++;
        }
        return candidateCount == 1 ? match : -1;
    }

    void RecordTaggedNamedMacroblock(Json::Value &in input, Editor::MacroblockSpec@ placedMb, int blockBaseIndex, int itemBaseIndex) {
        string tag = ResolvePlacementTag(input);
        if (tag.Length == 0 || placedMb is null) return;
        for (uint i = 0; i < placedMb.blocks.Length; i++) {
            auto block = placedMb.blocks[i];
            if (block is null) continue;
            RecordTaggedPlacement(tag, "block", block.name, block.pos - MacroblockInternalOffset(), blockBaseIndex + int(i));
        }
        for (uint i = 0; i < placedMb.items.Length; i++) {
            auto item = placedMb.items[i];
            if (item is null) continue;
            RecordTaggedPlacement(tag, "item", item.name, item.pos - MacroblockInternalOffset(), itemBaseIndex + int(i));
        }
    }

    Json::Value@ SetAgentTag(Json::Value &in input) {
        string tag = input.HasKey("tag") ? string(input["tag"]) : "";
        g_DefaultAgentTag = tag;
        Json::Value output = Json::Object();
        output["tag"] = g_DefaultAgentTag;
        output["active"] = g_DefaultAgentTag.Length > 0;
        output["trackedCount"] = int(g_TaggedObjects.Length);
        return MakeSuccess(output);
    }

    Json::Value@ ListTagged(Json::Value &in input) {
        string filter = input.HasKey("tag") ? string(input["tag"]) : "";
        bool prefix = input.HasKey("prefix") ? bool(input["prefix"]) : false;
        if (!input.HasKey("prefix") && filter.Length > 0 && !input.HasKey("tagExact")) {
            // If tag ends with ':' treat as prefix (run:)
            if (filter.EndsWith(":")) prefix = true;
        }
        int limit = input.HasKey("limit") ? int(input["limit"]) : 100;
        if (limit < 1) limit = 1;
        if (limit > 500) limit = 500;

        Json::Value entries = Json::Array();
        for (uint i = 0; i < g_TaggedObjects.Length && entries.Length < uint(limit); i++) {
            auto obj = g_TaggedObjects[i];
            if (obj is null) continue;
            if (!TagMatchesFilter(obj.tag, filter, prefix)) continue;
            Json::Value e = Json::Object();
            e["tag"] = obj.tag;
            e["kind"] = obj.kind;
            e["idName"] = obj.idName;
            e["pos"] = Vec3ToJson(vec3(obj.x, obj.y, obj.z));
            e["placedAtMs"] = int(obj.placedAtMs);
            e["lastKnownIndex"] = obj.lastKnownIndex;
            e["trackIndex"] = int(i);
            entries.Add(e);
        }
        Json::Value output = Json::Object();
        output["entries"] = entries;
        output["count"] = int(entries.Length);
        output["trackedTotal"] = int(g_TaggedObjects.Length);
        output["defaultTag"] = g_DefaultAgentTag;
        output["filter"] = filter;
        output["prefix"] = prefix;
        return MakeSuccess(output);
    }

    Json::Value@ ClearTagIndex(Json::Value &in input) {
        string filter = input.HasKey("tag") ? string(input["tag"]) : "";
        bool prefix = input.HasKey("prefix") ? bool(input["prefix"]) : filter.EndsWith(":");
        bool all = input.HasKey("all") ? bool(input["all"]) : (filter.Length == 0);
        int removed = 0;
        if (all) {
            removed = int(g_TaggedObjects.Length);
            g_TaggedObjects.RemoveRange(0, g_TaggedObjects.Length);
        } else {
            for (int i = int(g_TaggedObjects.Length) - 1; i >= 0; i--) {
                auto obj = g_TaggedObjects[uint(i)];
                if (obj is null || !TagMatchesFilter(obj.tag, filter, prefix)) continue;
                g_TaggedObjects.RemoveAt(uint(i));
                removed++;
            }
        }
        Json::Value output = Json::Object();
        output["cleared"] = removed;
        output["remaining"] = int(g_TaggedObjects.Length);
        output["all"] = all;
        return MakeSuccess(output);
    }

    Json::Value@ RemoveByTag(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) {
            return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor", "Enter editor / WaitUntil readiness");
        }
        if (!input.HasKey("tag")) {
            return MakeError("missing tag", "INVALID_INPUT", false, "", "Provide tag or tag prefix ending with ':'");
        }
        string filter = string(input["tag"]);
        if (filter.Length == 0) return MakeError("tag is empty", "INVALID_INPUT");
        bool prefix = input.HasKey("prefix") ? bool(input["prefix"]) : filter.EndsWith(":");
        bool addUndo = input.HasKey("addUndo") ? bool(input["addUndo"]) : true;
        float eps = input.HasKey("eps") ? float(input["eps"]) : MCP_TAG_POS_EPS;
        bool dryRun = input.HasKey("dryRun") ? bool(input["dryRun"]) : false;

        CGameCtnAnchoredObject@[] itemsToDelete;
        CGameCtnBlock@[] blocksToDelete;
        Json::Value matched = Json::Array();
        Json::Value missed = Json::Array();
        array<uint> removeTrackIdx;

        for (uint i = 0; i < g_TaggedObjects.Length; i++) {
            auto obj = g_TaggedObjects[i];
            if (obj is null) continue;
            if (!TagMatchesFilter(obj.tag, filter, prefix)) continue;

            Json::Value row = Json::Object();
            row["tag"] = obj.tag;
            row["kind"] = obj.kind;
            row["idName"] = obj.idName;
            row["pos"] = Vec3ToJson(vec3(obj.x, obj.y, obj.z));

            if (obj.kind == "item") {
                int candidateCount = 0;
                int idx = FindLiveItemIndex(editor, obj.idName, obj.x, obj.y, obj.z, eps, obj.lastKnownIndex, candidateCount);
                row["resolvedIndex"] = idx;
                row["candidateCount"] = candidateCount;
                if (idx < 0) {
                    row["reason"] = candidateCount > 1 ? "ambiguous live match" : "no matching live object";
                    missed.Add(row);
                    continue;
                }
                auto item = editor.Challenge.AnchoredObjects[uint(idx)];
                if (item is null) {
                    missed.Add(row);
                    continue;
                }
                // de-dupe
                bool already = false;
                for (uint j = 0; j < itemsToDelete.Length; j++) {
                    if (itemsToDelete[j] is item) { already = true; break; }
                }
                if (!already) itemsToDelete.InsertLast(item);
                matched.Add(row);
                removeTrackIdx.InsertLast(i);
            } else if (obj.kind == "block") {
                int candidateCount = 0;
                int idx = FindLiveBlockIndex(editor, obj.idName, obj.x, obj.y, obj.z, eps, obj.lastKnownIndex, candidateCount);
                row["resolvedIndex"] = idx;
                row["candidateCount"] = candidateCount;
                if (idx < 0) {
                    row["reason"] = candidateCount > 1 ? "ambiguous live match" : "no matching live object";
                    missed.Add(row);
                    continue;
                }
                auto block = editor.Challenge.Blocks[uint(idx)];
                if (block is null) {
                    missed.Add(row);
                    continue;
                }
                bool already = false;
                for (uint j = 0; j < blocksToDelete.Length; j++) {
                    if (blocksToDelete[j] is block) { already = true; break; }
                }
                if (!already) blocksToDelete.InsertLast(block);
                matched.Add(row);
                removeTrackIdx.InsertLast(i);
            } else {
                missed.Add(row);
            }
        }

        Json::Value mapPre = MapSummary(editor);
        bool itemsOk = true;
        bool blocksOk = true;
        string itemMethod = "none";
        string blockMethod = "none";

        if (!dryRun) {
            if (itemsToDelete.Length > 0) {
                itemMethod = "DeleteItems";
                try {
                    itemsOk = Editor::DeleteItems(itemsToDelete, addUndo);
                } catch {
                    return MakeError("DeleteItems failed: " + getExceptionInfo(), "DELETE_FAILED", true);
                }
            }
            if (blocksToDelete.Length > 0) {
                blockMethod = "DeleteBlocks";
                try {
                    blocksOk = Editor::DeleteBlocks(blocksToDelete, addUndo);
                } catch {
                    return MakeError("DeleteBlocks failed: " + getExceptionInfo(), "DELETE_FAILED", true);
                }
            }
            // Drop matched track entries (reverse order)
            if (itemsOk && blocksOk) {
                for (int i = int(removeTrackIdx.Length) - 1; i >= 0; i--) {
                    uint idx = removeTrackIdx[uint(i)];
                    if (idx < g_TaggedObjects.Length) g_TaggedObjects.RemoveAt(idx);
                }
            }
        }

        Json::Value output = Json::Object();
        output["dryRun"] = dryRun;
        output["deleted"] = !dryRun && itemsOk && blocksOk;
        output["itemsMatched"] = int(itemsToDelete.Length);
        output["blocksMatched"] = int(blocksToDelete.Length);
        output["matched"] = matched;
        output["missed"] = missed;
        output["itemMethod"] = itemMethod;
        output["blockMethod"] = blockMethod;
        output["itemsOk"] = itemsOk;
        output["blocksOk"] = blocksOk;
        output["undoSupported"] = true;
        output["mapPre"] = mapPre;
        output["mapPost"] = MapSummary(editor);
        output["trackedRemaining"] = int(g_TaggedObjects.Length);
        return MakeSuccess(output);
    }
}
