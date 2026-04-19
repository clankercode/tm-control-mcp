namespace TmMcp {
    CGameCtnMacroBlockInfo@ ResolveMacroblockModel(CGameEditorPluginMap@ pmt, Json::Value &in input, string &out source) {
        source = "";
        if (pmt is null) return null;

        if (input.HasKey("index")) {
            int index = int(input["index"]);
            if (index < 0 || index >= int(pmt.MacroblockModels.Length)) {
                source = "index out of range";
                return null;
            }
            source = "index";
            return pmt.MacroblockModels[uint(index)];
        }

        if (input.HasKey("path")) {
            string path = string(input["path"]);
            auto model = pmt.GetMacroblockModelFromFilePath(path);
            source = "path";
            return model;
        }

        if (input.HasKey("name")) {
            string name = string(input["name"]);
            auto model = pmt.GetMacroblockModelFromName(name);
            if (model !is null) {
                source = "name";
                return model;
            }

            string lowerName = name.ToLower();
            for (uint i = 0; i < pmt.MacroblockModels.Length; i++) {
                @model = pmt.MacroblockModels[i];
                if (model is null) continue;
                if (string(model.Name).ToLower() == lowerName || string(model.IdName).ToLower() == lowerName) {
                    source = "name scan";
                    return model;
                }
            }
            source = "name";
        }
        return null;
    }

    Json::Value MacroblockInfoDetailsToJson(CGameCtnMacroBlockInfo@ model) {
        Json::Value output = MacroblockModelToJson(model);
        if (model is null) return output;
        output["connected"] = model.Connected;
        output["initialized"] = model.Initialized;
        output["isGround"] = model.IsGround;
        output["hasStart"] = model.HasStart;
        output["hasFinish"] = model.HasFinish;
        output["hasCheckpoint"] = model.HasCheckpoint;
        output["hasMultilap"] = model.HasMultilap;
        if (model.GeneratedBlockInfo !is null) {
            output["generatedBlockInfo"] = ModelToJson(model.GeneratedBlockInfo, false);
        }
        return output;
    }

    Json::Value MacroblockSpecContentsToJson(Editor::MacroblockSpec@ spec, int limit, bool includeItems) {
        Json::Value output = Json::Object();
        if (spec is null) return output;
        output["nbBlocks"] = int(spec.blocks.Length);
        output["nbItems"] = int(spec.items.Length);

        Json::Value blocks = Json::Array();
        for (uint i = 0; i < spec.blocks.Length && blocks.Length < uint(limit); i++) {
            auto obj = BlockSpecToJson(spec.blocks[i]);
            obj["index"] = int(i);
            blocks.Add(obj);
        }
        output["blocks"] = blocks;

        Json::Value items = Json::Array();
        if (includeItems) {
            for (uint i = 0; i < spec.items.Length && items.Length < uint(limit); i++) {
                auto obj = ItemSpecToJson(spec.items[i]);
                obj["index"] = int(i);
                items.Add(obj);
            }
        }
        output["items"] = items;
        output["returnedBlocks"] = int(blocks.Length);
        output["returnedItems"] = int(items.Length);
        return output;
    }

    Json::Value@ InspectMacroblockModel(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        if (!input.HasKey("name") && !input.HasKey("path") && !input.HasKey("index")) {
            return MakeError("missing name, path, or index");
        }

        string source;
        auto model = ResolveMacroblockModel(editor.PluginMapType, input, source);
        if (model is null) return MakeError("macroblock model not found via " + source);

        int limit = input.HasKey("limit") ? int(input["limit"]) : 100;
        if (limit < 1) limit = 1;
        if (limit > 500) limit = 500;
        bool includeItems = input.HasKey("includeItems") ? bool(input["includeItems"]) : true;

        Editor::MacroblockSpec@ spec = null;
        string specError = "";
        try {
            @spec = Editor::MakeMacroblockSpec(model);
        } catch {
            specError = getExceptionInfo();
        }

        Json::Value output = Json::Object();
        output["source"] = source;
        output["model"] = MacroblockInfoDetailsToJson(model);
        output["limit"] = limit;
        output["includeItems"] = includeItems;
        output["contents"] = MacroblockSpecContentsToJson(spec, limit, includeItems);
        output["specOk"] = spec !is null;
        output["specError"] = specError;
        output["skinNote"] = "Block skins are not included here; this uses E++ MacroblockSpec block/item conversion.";
        output["inventory"] = InventorySummary(editor.PluginMapType);
        return MakeSuccess(output);
    }
}
