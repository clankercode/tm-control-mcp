namespace TmMcp {
    // Last mutator map snapshots for AssertPlacement convenience
    Json::Value@ g_LastMapPre = null;
    Json::Value@ g_LastMapPost = null;
    string g_LastMutator = "";

    void RememberMapDelta(const string &in tool, Json::Value@ mapPre, Json::Value@ mapPost) {
        g_LastMutator = tool;
        @g_LastMapPre = mapPre;
        @g_LastMapPost = mapPost;
    }

    string NamedMbDataDir() {
        return IO::FromDataFolder("tm-control-mcp/named-mb");
    }

    string SanitizeMbFileStem(const string &in name) {
        string stem = "";
        for (uint i = 0; i < name.Length; i++) {
            string ch = name.SubStr(i, 1);
            bool ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
                || (ch >= "0" && ch <= "9") || ch == "_" || ch == "-" || ch == ".";
            stem += ok ? ch : "_";
        }
        if (stem.Length == 0) stem = "unnamed";
        if (stem.Length > 80) stem = stem.SubStr(0, 80);
        return stem;
    }

    string NamedMbPathFor(const string &in name, const string &in fileName) {
        string stem = fileName.Length > 0 ? SanitizeMbFileStem(fileName) : SanitizeMbFileStem(name);
        if (!stem.ToLower().EndsWith(".json")) stem += ".json";
        return NamedMbDataDir() + "/" + stem;
    }

    void EnsureNamedMbDir() {
        string dir = NamedMbDataDir();
        if (!IO::FolderExists(dir)) {
            IO::CreateFolder(dir, true);
        }
    }

    void AddNamedMbLoadError(Json::Value &inout errors, const string &in kind, int index, const string &in error) {
        Json::Value e = Json::Object();
        e["kind"] = kind;
        e["index"] = index;
        e["error"] = error;
        errors.Add(e);
    }

    Json::Value NamedMbToDiskJson(const string &in name, Editor::MacroblockSpec@ mb) {
        Json::Value root = Json::Object();
        root["format"] = "tm-control-mcp-named-mb-v2";
        root["name"] = name;
        root["savedAtMs"] = int(Time::Now);
        Json::Value blocks = Json::Array();
        Json::Value items = Json::Array();
        if (mb !is null) {
            for (uint i = 0; i < mb.blocks.Length; i++) {
                auto b = mb.blocks[i];
                if (b is null) continue;
                Json::Value o = Json::Object();
                o["blockName"] = b.name;
                vec3 pos = b.pos - MacroblockInternalOffset();
                o["x"] = pos.x; o["y"] = pos.y; o["z"] = pos.z;
                o["pitch"] = Math::ToDeg(b.pyr.x);
                o["yaw"] = Math::ToDeg(b.pyr.y);
                o["roll"] = Math::ToDeg(b.pyr.z);
                o["variant"] = int(b.variant);
                o["isFree"] = b.isFree;
                o["isGround"] = b.isGround;
                o["isGhost"] = b.isGhost;
                blocks.Add(o);
            }
            for (uint i = 0; i < mb.items.Length; i++) {
                auto it = mb.items[i];
                if (it is null) continue;
                Json::Value o = Json::Object();
                // ItemSpec.name is model id/name; path-place resolves by inventory path or name
                o["itemPath"] = it.name;
                vec3 pos = it.pos - MacroblockInternalOffset();
                o["x"] = pos.x; o["y"] = pos.y; o["z"] = pos.z;
                o["pitch"] = Math::ToDeg(it.pyr.x);
                o["yaw"] = Math::ToDeg(it.pyr.y);
                o["roll"] = Math::ToDeg(it.pyr.z);
                o["variant"] = int(it.variantIx);
                items.Add(o);
            }
        }
        // post skins
        Json::Value skins = Json::Array();
        auto skinList = GetNamedMacroblockSkins(name);
        if (skinList !is null) {
            for (uint i = 0; i < skinList.Length; i++) {
                auto s = skinList[i];
                if (s is null) continue;
                Json::Value o = Json::Object();
                o["isItem"] = s.isItem;
                if (s.isItem) o["itemIndex"] = int(s.itemIndex);
                else o["blockIndex"] = int(s.blockIndex);
                o["fgSkin"] = s.fgSkin;
                o["bgSkin"] = s.bgSkin;
                skins.Add(o);
            }
        }
        root["blocks"] = blocks;
        root["items"] = items;
        root["postSkins"] = skins;
        return root;
    }

    Json::Value@ SaveNamedMacroblock(Json::Value &in input) {
        if (!input.HasKey("name")) return MakeError("missing name", "INVALID_INPUT");
        string name = string(input["name"]);
        auto mb = GetNamedMacroblock(name);
        if (mb is null) return MakeError("named macroblock not found: " + name, "NOT_FOUND");
        string fileName = input.HasKey("fileName") ? string(input["fileName"]) : name;
        EnsureNamedMbDir();
        string path = NamedMbPathFor(name, fileName);
        auto root = NamedMbToDiskJson(name, mb);
        try {
            Json::ToFile(path, root);
        } catch {
            return MakeError("failed to write " + path + ": " + getExceptionInfo(), "UNKNOWN");
        }
        Json::Value output = NamedMacroblockSummary(name, mb);
        output["saved"] = true;
        output["path"] = path;
        output["fileName"] = fileName;
        return MakeSuccess(output);
    }

    Json::Value@ LoadNamedMacroblock(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) {
            // Allow load without editor for blocks/items that only need models at place-time —
            // but Add* needs ResolveBlockModel now. Require editor.
            return MakeError("editor not available (needed to resolve models while loading)", "NOT_IN_EDITOR", true, "Editor");
        }
        if (!input.HasKey("name") && !input.HasKey("fileName")) {
            return MakeError("missing name or fileName", "INVALID_INPUT");
        }
        string name = input.HasKey("name") ? string(input["name"]) : "";
        string fileName = input.HasKey("fileName") ? string(input["fileName"]) : name;
        if (name.Length == 0) name = SanitizeMbFileStem(fileName).Replace(".json", "");
        bool replace = input.HasKey("replace") ? bool(input["replace"]) : true;

        string path = NamedMbPathFor(name, fileName);
        if (!IO::FileExists(path)) {
            return MakeError("file not found: " + path, "NOT_FOUND");
        }
        Json::Value@ root;
        try {
            @root = Json::FromFile(path);
        } catch {
            return MakeError("failed to read " + path + ": " + getExceptionInfo(), "UNKNOWN");
        }
        if (root is null || root.GetType() != Json::Type::Object) {
            return MakeError("invalid named-mb JSON: " + path, "INVALID_INPUT");
        }
        if (root.HasKey("name") && string(root["name"]).Length > 0) {
            // Prefer embedded name unless caller forced a different name
            if (!input.HasKey("name")) name = string(root["name"]);
        }

        int existing = FindNamedMacroblockIndex(name);
        if (existing >= 0 && !replace) {
            return MakeError("named macroblock already exists: " + name, "INVALID_INPUT", false, "", "Pass replace=true");
        }

        // Create empty
        auto mb = Editor::MakeMacroblockSpec();
        if (existing >= 0) {
            @g_NamedMacroblocks[existing] = mb;
            @g_NamedMacroblockSkins[existing] = NewNamedMacroblockSkinList();
        } else {
            g_NamedMacroblockNames.InsertLast(name);
            g_NamedMacroblocks.InsertLast(mb);
            g_NamedMacroblockSkins.InsertLast(NewNamedMacroblockSkinList());
        }

        Json::Value errors = Json::Array();
        int blocksAdded = 0;
        int itemsAdded = 0;

        if (root.HasKey("blocks") && root["blocks"].GetType() == Json::Type::Array) {
            auto blocks = root["blocks"];
            for (uint i = 0; i < blocks.Length; i++) {
                Json::Value b = blocks[i];
                b["name"] = name;
                b["create"] = false;
                if (!b.HasKey("blockName") && b.HasKey("name")) {
                    // disk format uses blockName; ignore summary name
                }
                auto result = AddBlockToNamedMacroblock(b);
                if (bool(result["success"])) blocksAdded++;
                else {
                    Json::Value e = Json::Object();
                    e["kind"] = "block";
                    e["index"] = int(i);
                    e["error"] = string(result["error"]);
                    errors.Add(e);
                }
            }
        }
        if (root.HasKey("items") && root["items"].GetType() == Json::Type::Array) {
            auto items = root["items"];
            for (uint i = 0; i < items.Length; i++) {
                Json::Value it = items[i];
                it["name"] = name;
                it["create"] = false;
                auto result = AddItemToNamedMacroblock(it);
                if (bool(result["success"])) itemsAdded++;
                else {
                    Json::Value e = Json::Object();
                    e["kind"] = "item";
                    e["index"] = int(i);
                    e["error"] = string(result["error"]);
                    errors.Add(e);
                }
            }
        }
        // re-apply post skins indices from file if present
        if (root.HasKey("postSkins") && root["postSkins"].GetType() == Json::Type::Array) {
            auto skins = root["postSkins"];
            for (uint i = 0; i < skins.Length; i++) {
                auto s = skins[i];
                if (s is null || s.GetType() != Json::Type::Object) {
                    AddNamedMbLoadError(errors, "postSkin", int(i), "skin row must be an object");
                    continue;
                }
                bool isItem = false; // v1 rows were block-only and omit isItem
                if (s.HasKey("isItem")) {
                    if (s["isItem"].GetType() != Json::Type::Boolean) {
                        AddNamedMbLoadError(errors, "postSkin", int(i), "isItem must be boolean");
                        continue;
                    }
                    isItem = bool(s["isItem"]);
                }
                if (s.HasKey("fgSkin") && s["fgSkin"].GetType() != Json::Type::String) {
                    AddNamedMbLoadError(errors, "postSkin", int(i), "fgSkin must be string");
                    continue;
                }
                if (s.HasKey("bgSkin") && s["bgSkin"].GetType() != Json::Type::String) {
                    AddNamedMbLoadError(errors, "postSkin", int(i), "bgSkin must be string");
                    continue;
                }
                string fg = s.HasKey("fgSkin") ? string(s["fgSkin"]) : "";
                string bg = s.HasKey("bgSkin") ? string(s["bgSkin"]) : "";
                string indexKey = isItem ? "itemIndex" : "blockIndex";
                if (!s.HasKey(indexKey) || s[indexKey].GetType() != Json::Type::Number) {
                    AddNamedMbLoadError(errors, "postSkin", int(i), indexKey + " must be a number");
                    continue;
                }
                int skinIndex = int(s[indexKey]);
                int targetCount = isItem ? int(mb.items.Length) : int(mb.blocks.Length);
                if (skinIndex < 0 || skinIndex >= targetCount) {
                    AddNamedMbLoadError(errors, "postSkin", int(i), indexKey + " is out of range");
                    continue;
                }
                if (isItem) AddPostItemSkinToNamedMacroblock(name, uint(skinIndex), fg, bg);
                else AddPostSkinToNamedMacroblock(name, uint(skinIndex), fg, bg);
            }
        }

        Json::Value output = NamedMacroblockSummary(name, GetNamedMacroblock(name));
        output["loaded"] = true;
        output["path"] = path;
        output["blocksAdded"] = blocksAdded;
        output["itemsAdded"] = itemsAdded;
        output["errors"] = errors;
        output["ok"] = errors.Length == 0;
        return MakeSuccess(output);
    }

    Json::Value@ ListSavedNamedMacroblocks(Json::Value &in input) {
        EnsureNamedMbDir();
        string dir = NamedMbDataDir();
        Json::Value files = Json::Array();
        // Openplanet has no portable directory list API on all versions — try IO::IndexFolder
        try {
            auto entries = IO::IndexFolder(dir, false);
            for (uint i = 0; i < entries.Length; i++) {
                string p = entries[i];
                if (!p.ToLower().EndsWith(".json")) continue;
                Json::Value e = Json::Object();
                e["path"] = p;
                // basename
                auto parts = p.Replace("\\", "/").Split("/");
                e["fileName"] = parts.Length > 0 ? parts[parts.Length - 1] : p;
                files.Add(e);
            }
        } catch {
            Json::Value output = Json::Object();
            output["files"] = files;
            output["dir"] = dir;
            output["error"] = "IndexFolder failed: " + getExceptionInfo();
            output["note"] = "Directory listing unavailable; pass fileName explicitly to LoadNamedMacroblock";
            return MakeSuccess(output);
        }
        Json::Value output = Json::Object();
        output["files"] = files;
        output["count"] = int(files.Length);
        output["dir"] = dir;
        return MakeSuccess(output);
    }

    Json::Value@ AssertPlacement(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) {
            return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        }

        Json::Value failures = Json::Array();
        Json::Value found = Json::Array();
        bool ok = true;

        auto mapNow = MapSummary(editor);
        Json::Value@ mapPre = g_LastMapPre;
        if (input.HasKey("mapPre")) @mapPre = input["mapPre"];

        if (input.HasKey("expectItemsDelta")) {
            int expect = int(input["expectItemsDelta"]);
            int before = mapPre !is null && mapPre.HasKey("nbItems") ? int(mapPre["nbItems"]) : -1;
            int after = int(mapNow["nbItems"]);
            if (before < 0) {
                failures.Add("expectItemsDelta set but no mapPre available (pass mapPre or run a place tool first)");
                ok = false;
            } else if (after - before != expect) {
                failures.Add("items delta " + (after - before) + " != expected " + expect);
                ok = false;
            } else {
                Json::Value f = Json::Object();
                f["check"] = "expectItemsDelta";
                f["delta"] = after - before;
                found.Add(f);
            }
        }
        if (input.HasKey("expectBlocksDelta")) {
            int expect = int(input["expectBlocksDelta"]);
            int before = mapPre !is null && mapPre.HasKey("nbBlocks") ? int(mapPre["nbBlocks"]) : -1;
            int after = int(mapNow["nbBlocks"]);
            if (before < 0) {
                failures.Add("expectBlocksDelta set but no mapPre available");
                ok = false;
            } else if (after - before != expect) {
                failures.Add("blocks delta " + (after - before) + " != expected " + expect);
                ok = false;
            } else {
                Json::Value f = Json::Object();
                f["check"] = "expectBlocksDelta";
                f["delta"] = after - before;
                found.Add(f);
            }
        }

        if (input.HasKey("near")) {
            auto near = input["near"];
            if (near.GetType() != Json::Type::Object) {
                failures.Add("near must be object with x,y,z,radius?");
                ok = false;
            } else if (!near.HasKey("x") || !near.HasKey("y") || !near.HasKey("z")) {
                failures.Add("near must include x, y, and z");
                ok = false;
            } else if (near["x"].GetType() != Json::Type::Number || near["y"].GetType() != Json::Type::Number || near["z"].GetType() != Json::Type::Number) {
                failures.Add("near x, y, and z must be numbers");
                ok = false;
            } else if (near.HasKey("radius") && near["radius"].GetType() != Json::Type::Number) {
                failures.Add("near radius must be a number");
                ok = false;
            } else {
                float x = float(near["x"]);
                float y = float(near["y"]);
                float z = float(near["z"]);
                float radius = near.HasKey("radius") ? float(near["radius"]) : 1.0;
                if (radius < 0) {
                    failures.Add("near radius must be nonnegative");
                    ok = false;
                } else {
                float r2 = radius * radius;
                string itemPath = input.HasKey("itemPath") ? string(input["itemPath"]).ToLower() : "";
                string blockName = input.HasKey("blockName") ? string(input["blockName"]).ToLower() : "";
                bool any = false;
                bool scanItems = itemPath.Length > 0 || (itemPath.Length == 0 && blockName.Length == 0);
                bool scanBlocks = blockName.Length > 0 || (itemPath.Length == 0 && blockName.Length == 0);
                if (scanItems) {
                    // scan items when itemPath given or neither model filter
                    for (uint i = 0; i < editor.Challenge.AnchoredObjects.Length; i++) {
                        auto item = editor.Challenge.AnchoredObjects[i];
                        if (item is null) continue;
                        vec3 pos = item.AbsolutePositionInMap;
                        float d = PosDist2(pos, x, y, z);
                        if (d > r2) continue;
                        if (itemPath.Length > 0 && item.ItemModel !is null) {
                            string id = string(item.ItemModel.IdName).ToLower();
                            string nm = string(item.ItemModel.Name).ToLower();
                            if (!id.Contains(itemPath) && !nm.Contains(itemPath) && !itemPath.Contains(id) && !itemPath.EndsWith(id)) continue;
                        } else if (itemPath.Length > 0) {
                            continue;
                        }
                        any = true;
                        Json::Value f = Json::Object();
                        f["kind"] = "item";
                        f["index"] = int(i);
                        f["pos"] = Vec3ToJson(pos);
                        if (item.ItemModel !is null) f["idName"] = string(item.ItemModel.IdName);
                        found.Add(f);
                    }
                }
                if (scanBlocks) {
                    for (uint i = 0; i < editor.Challenge.Blocks.Length; i++) {
                        auto block = editor.Challenge.Blocks[i];
                        if (block is null || block.BlockInfo is null) continue;
                        if (blockName.Length > 0) {
                            string id = string(block.BlockInfo.IdName).ToLower();
                            string nm = string(block.BlockInfo.Name).ToLower();
                            if (!id.Contains(blockName) && !nm.Contains(blockName)) continue;
                        }
                        vec3 pos;
                        try { pos = Editor::GetBlockLocation(block, true); } catch {
                            pos = vec3(float(block.Coord.x) * 32.0, (float(block.Coord.y) - 8.0) * 8.0, float(block.Coord.z) * 32.0);
                        }
                        float d = PosDist2(pos, x, y, z);
                        if (d > r2) continue;
                        any = true;
                        Json::Value f = Json::Object();
                        f["kind"] = "block";
                        f["index"] = int(i);
                        f["pos"] = Vec3ToJson(pos);
                        f["idName"] = string(block.BlockInfo.IdName);
                        found.Add(f);
                    }
                }
                if (!any) {
                    failures.Add("no matching object near (" + x + "," + y + "," + z + ") r=" + radius);
                    ok = false;
                }
                }
            }
        }

        if (input.HasKey("tag")) {
            string tag = string(input["tag"]);
            int n = 0;
            for (uint i = 0; i < g_TaggedObjects.Length; i++) {
                if (g_TaggedObjects[i] !is null && g_TaggedObjects[i].tag == tag) n++;
            }
            int minCount = input.HasKey("tagMinCount") ? int(input["tagMinCount"]) : 1;
            if (n < minCount) {
                failures.Add("tag '" + tag + "' has " + n + " tracked < min " + minCount);
                ok = false;
            } else {
                Json::Value f = Json::Object();
                f["check"] = "tag";
                f["tag"] = tag;
                f["count"] = n;
                found.Add(f);
            }
        }

        Json::Value output = Json::Object();
        output["ok"] = ok;
        output["failures"] = failures;
        output["found"] = found;
        output["map"] = mapNow;
        output["lastMutator"] = g_LastMutator;
        if (mapPre !is null) output["mapPre"] = mapPre;
        return MakeSuccess(output);
    }
}
