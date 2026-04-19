namespace TmMcp {
    class NamedMacroblockSkin {
        uint blockIndex;
        uint itemIndex;
        bool isItem;
        string fgSkin;
        string bgSkin;

        NamedMacroblockSkin(uint blockIndex, const string &in fgSkin, const string &in bgSkin) {
            this.blockIndex = blockIndex;
            this.itemIndex = 0;
            this.isItem = false;
            this.fgSkin = fgSkin;
            this.bgSkin = bgSkin;
        }

        NamedMacroblockSkin(bool isItem, uint itemIndex, const string &in fgSkin, const string &in bgSkin) {
            this.blockIndex = 0;
            this.itemIndex = itemIndex;
            this.isItem = isItem;
            this.fgSkin = fgSkin;
            this.bgSkin = bgSkin;
        }
    }

    NamedMacroblockSkin@[]@ NewNamedMacroblockSkinList() {
        NamedMacroblockSkin@[] skins;
        return skins;
    }

    Json::Value BlockSkinToJson(CGameCtnBlock@ block) {
        Json::Value skin = Json::Object();
        skin["hasSkin"] = block !is null && block.Skin !is null;
        if (block !is null && block.Skin !is null) {
            skin["bgSkin"] = PackDescPath(block.Skin.PackDesc);
            skin["fgSkin"] = PackDescPath(block.Skin.ForegroundPackDesc);
            skin["parentSkin"] = PackDescPath(block.Skin.ParentPackDesc);
        }
        return skin;
    }

    Json::Value ItemSkinToJson(CGameCtnAnchoredObject@ item) {
        Json::Value skin = Json::Object();
        CSystemPackDesc@ bgSkin;
        CSystemPackDesc@ fgSkin;
        if (item !is null) {
            @bgSkin = Editor::GetItemBGSkin(item);
            @fgSkin = Editor::GetItemFGSkin(item);
        }
        skin["hasSkin"] = bgSkin !is null || fgSkin !is null;
        skin["bgSkin"] = PackDescPath(bgSkin);
        skin["fgSkin"] = PackDescPath(fgSkin);
        return skin;
    }

    NamedMacroblockSkin@[]@ GetNamedMacroblockSkins(const string &in name) {
        int index = FindNamedMacroblockIndex(name);
        if (index < 0 || index >= int(g_NamedMacroblockSkins.Length)) return null;
        return g_NamedMacroblockSkins[index];
    }

    Json::Value NamedMacroblockSkinToJson(NamedMacroblockSkin@ skin) {
        Json::Value obj = Json::Object();
        if (skin is null) return obj;
        obj["target"] = skin.isItem ? "item" : "block";
        obj["blockIndex"] = int(skin.blockIndex);
        obj["itemIndex"] = int(skin.itemIndex);
        obj["fgSkin"] = skin.fgSkin;
        obj["bgSkin"] = skin.bgSkin;
        return obj;
    }

    Json::Value NamedMacroblockSkinsToJson(NamedMacroblockSkin@[]@ skins, int limit = 100) {
        Json::Value output = Json::Array();
        if (skins is null) return output;
        if (limit < 1) limit = 1;
        for (uint i = 0; i < skins.Length && output.Length < uint(limit); i++) {
            output.Add(NamedMacroblockSkinToJson(skins[i]));
        }
        return output;
    }

    void AddPostSkinToNamedMacroblock(const string &in name, uint blockIndex, const string &in fgSkin, const string &in bgSkin) {
        if (fgSkin.Length == 0 && bgSkin.Length == 0) return;
        auto skins = GetNamedMacroblockSkins(name);
        if (skins is null) return;
        skins.InsertLast(NamedMacroblockSkin(blockIndex, fgSkin, bgSkin));
    }

    void AddPostItemSkinToNamedMacroblock(const string &in name, uint itemIndex, const string &in fgSkin, const string &in bgSkin) {
        if (fgSkin.Length == 0 && bgSkin.Length == 0) return;
        auto skins = GetNamedMacroblockSkins(name);
        if (skins is null) return;
        skins.InsertLast(NamedMacroblockSkin(true, itemIndex, fgSkin, bgSkin));
    }

    CGameCtnEditorScriptAnchoredObject@ FindScriptItemForMapItem(CGameEditorPluginMapMapType@ pmt, CGameCtnAnchoredObject@ mapItem) {
        if (pmt is null || mapItem is null) return null;
        for (uint i = 0; i < pmt.Items.Length; i++) {
            auto scriptItem = pmt.Items[i];
            if (scriptItem is null) continue;
            if (scriptItem.ItemModel !is mapItem.ItemModel) continue;
            if ((scriptItem.Position - mapItem.AbsolutePositionInMap).LengthSquared() < 0.01) return scriptItem;
        }
        return null;
    }

    Json::Value ApplyNamedMacroblockSkinsDirect(CGameEditorPluginMapMapType@ pmt, const string &in name, int blockBaseIndex, int itemBaseIndex) {
        Json::Value output = Json::Object();
        Json::Value applied = Json::Array();
        Json::Value errors = Json::Array();
        auto skins = GetNamedMacroblockSkins(name);
        if (pmt is null || pmt.Map is null || skins is null) {
            output["requested"] = 0;
            output["applied"] = applied;
            output["errors"] = errors;
            output["ok"] = false;
            return output;
        }

        for (uint i = 0; i < skins.Length; i++) {
            auto skin = skins[i];
            if (skin is null) continue;
            if (skin.isItem) {
                ApplyNamedMacroblockItemSkin(pmt, skin, itemBaseIndex, applied, errors);
            } else {
                ApplyNamedMacroblockBlockSkin(pmt, skin, blockBaseIndex, applied, errors);
            }
        }

        output["requested"] = int(skins.Length);
        output["applied"] = applied;
        output["errors"] = errors;
        output["ok"] = errors.Length == 0;
        return output;
    }

    void ApplyNamedMacroblockItemSkin(
        CGameEditorPluginMapMapType@ pmt,
        NamedMacroblockSkin@ skin,
        int itemBaseIndex,
        Json::Value &inout applied,
        Json::Value &inout errors
    ) {
        int itemMapIndex = itemBaseIndex + int(skin.itemIndex);
        if (itemMapIndex < 0 || itemMapIndex >= int(pmt.Map.AnchoredObjects.Length)) {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = "map item index out of range";
            err["mapIndex"] = itemMapIndex;
            err["nbMapItems"] = int(pmt.Map.AnchoredObjects.Length);
            errors.Add(err);
            return;
        }

        auto mapItem = pmt.Map.AnchoredObjects[itemMapIndex];
        if (mapItem is null) {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = "map item is null";
            err["mapIndex"] = itemMapIndex;
            errors.Add(err);
            return;
        }

        CSystemPackDesc@ bgPd = null;
        CSystemPackDesc@ fgPd = null;
        try {
            if (skin.bgSkin.Length > 0) @bgPd = Editor::GetPackDesc(skin.bgSkin);
            if (skin.fgSkin.Length > 0) @fgPd = Editor::GetPackDesc(skin.fgSkin);
            if ((skin.bgSkin.Length > 0 && bgPd is null) || (skin.fgSkin.Length > 0 && fgPd is null)) {
                Json::Value err = NamedMacroblockSkinToJson(skin);
                err["error"] = "failed to resolve skin URL(s) to pack desc";
                err["mapIndex"] = itemMapIndex;
                err["bgResolved"] = bgPd !is null;
                err["fgResolved"] = fgPd !is null;
                errors.Add(err);
            } else {
                Editor::SetItemSkinsRaw(mapItem, bgPd, fgPd);
                Json::Value ok = NamedMacroblockSkinToJson(skin);
                ok["mapIndex"] = itemMapIndex;
                ok["actualSkin"] = ItemSkinToJson(mapItem);
                if (!bool(ok["actualSkin"]["hasSkin"])) {
                    ok["error"] = "skin was not reflected on item after SetItemSkinsRaw";
                    errors.Add(ok);
                } else {
                    applied.Add(ok);
                }
            }
        } catch {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = getExceptionInfo();
            err["mapIndex"] = itemMapIndex;
            errors.Add(err);
        }
        if (bgPd !is null) bgPd.MwRelease();
        if (fgPd !is null) fgPd.MwRelease();
    }

    void ApplyNamedMacroblockBlockSkin(
        CGameEditorPluginMapMapType@ pmt,
        NamedMacroblockSkin@ skin,
        int blockBaseIndex,
        Json::Value &inout applied,
        Json::Value &inout errors
    ) {
        int mapIndex = blockBaseIndex + int(skin.blockIndex);
        if (mapIndex < 0 || mapIndex >= int(pmt.Map.Blocks.Length)) {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = "map block index out of range";
            err["mapIndex"] = mapIndex;
            errors.Add(err);
            return;
        }

        auto block = pmt.Map.Blocks[mapIndex];
        if (block is null) {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = "map block is null";
            err["mapIndex"] = mapIndex;
            errors.Add(err);
            return;
        }

        try {
            pmt.SetBlockSkins(block, skin.bgSkin, skin.fgSkin);
            Json::Value ok = NamedMacroblockSkinToJson(skin);
            ok["mapIndex"] = mapIndex;
            ok["actualSkin"] = BlockSkinToJson(block);
            if (block.Skin is null) {
                ok["error"] = "skin was not reflected on block after SetBlockSkins";
                errors.Add(ok);
            } else {
                applied.Add(ok);
            }
        } catch {
            Json::Value err = NamedMacroblockSkinToJson(skin);
            err["error"] = getExceptionInfo();
            err["mapIndex"] = mapIndex;
            errors.Add(err);
        }
    }
}
