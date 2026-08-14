#if DEPENDENCY_EDITOR
namespace TmMcp {
    Json::Value@ RunComputeItemsDiagnostic(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) {
            return MakeError("editor not available");
        }
        auto pmt = editor.PluginMapType;

        if (!input.HasKey("mbPath")) return MakeError("missing mbPath");
        string mbPath = string(input["mbPath"]);
        if (mbPath.Length == 0) return MakeError("mbPath is empty");

        int x = input.HasKey("x") ? int(input["x"]) : 0;
        int y = input.HasKey("y") ? int(input["y"]) : 0;
        int z = input.HasKey("z") ? int(input["z"]) : 0;
        string dirStr = input.HasKey("dir") ? string(input["dir"]) : "North";
        auto dir = DirFromString(dirStr);
        auto color = CGameEditorPluginMap::EMapElemColor::Default;
        bool force = input.HasKey("force") ? bool(input["force"]) : false;

        auto model = pmt.GetMacroblockModelFromFilePath(mbPath);
        if (model is null) return MakeError("macroblock model not found: " + mbPath);

        Json::Value output = Json::Object();
        output["mbPath"] = mbPath;
        output["coord"] = Vec3ToJson(vec3(float(x), float(y), float(z)));
        output["dir"] = dirStr;
        output["modelName"] = model.Name;
        output["modelIdName"] = model.IdName;

        CGameEditorMapMacroBlockInstance@ inst;
        string instError = "";
        try {
            @inst = pmt.CreateMacroblockInstance(model, nat3(uint(x), uint(y), uint(z)), dir, color, force);
        } catch {
            instError = getExceptionInfo();
        }
        if (inst is null) {
            output["error"] = instError.Length > 0 ? instError : "CreateMacroblockInstance returned null";
            return MakeSuccess(output);
        }

        string computeError = "";
        try {
            pmt.ComputeItemsForMacroblockInstance(inst);
        } catch {
            computeError = getExceptionInfo();
        }
        if (computeError.Length > 0) {
            output["computeError"] = computeError;
            return MakeSuccess(output);
        }

        uint nbItems = pmt.MacroblockInstanceItemsResults.Length;
        output["nbComputedItems"] = int(nbItems);

        Json::Value computed = Json::Array();
        for (uint i = 0; i < nbItems; i++) {
            computed.Add(DescribeComputedItem(editor, pmt, i));
        }
        output["items"] = computed;

        if (input.HasKey("testSkin") && input["testSkin"].GetType() == Json::Type::Object) {
            output["skinTest"] = RunComputeSkinTest(editor, pmt, input["testSkin"], nbItems);
        }

        return MakeSuccess(output);
    }

    Json::Value DescribeComputedItem(CGameCtnEditorFree@ editor, CGameEditorPluginMapMapType@ pmt, uint i) {
        Json::Value cur = Json::Object();
        cur["index"] = int(i);
        auto scriptItem = pmt.MacroblockInstanceItemsResults[i];
        if (scriptItem is null) {
            cur["isNull"] = true;
            return cur;
        }

        CGameItemModel@ scriptModel;
        vec3 scriptPos;
        bool scriptReadOk = false;
        try {
            @scriptModel = scriptItem.ItemModel;
            scriptPos = scriptItem.Position;
            scriptReadOk = true;
        } catch {
            cur["readError"] = getExceptionInfo();
        }

        if (scriptReadOk) {
            cur["position"] = Vec3ToJson(scriptPos);
            cur["itemModelIdName"] = scriptModel !is null ? scriptModel.IdName : "";
            int matchIdx = FindLiveItemIndex(editor, scriptModel, scriptPos);
            if (matchIdx >= 0) {
                auto mapItem = editor.Challenge.AnchoredObjects[uint(matchIdx)];
                cur["mapItemIndex"] = matchIdx;
                cur["mapItemPosition"] = Vec3ToJson(mapItem.AbsolutePositionInMap);
                cur["mapItemSkin"] = ItemSkinToJson(mapItem);
            } else {
                cur["mapItemMatch"] = "none";
            }
        }
        return cur;
    }

    int FindLiveItemIndex(CGameCtnEditorFree@ editor, CGameItemModel@ scriptModel, const vec3 &in scriptPos) {
        if (scriptModel is null || editor.Challenge is null) return -1;
        auto anchored = editor.Challenge.AnchoredObjects;
        int bestIdx = -1;
        float bestDistSq = 0.01;
        for (uint j = 0; j < anchored.Length; j++) {
            auto mapItem = anchored[j];
            if (mapItem is null) continue;
            if (mapItem.ItemModel !is scriptModel) continue;
            float distSq = (mapItem.AbsolutePositionInMap - scriptPos).LengthSquared();
            if (distSq < bestDistSq) {
                bestDistSq = distSq;
                bestIdx = int(j);
            }
        }
        return bestIdx;
    }

    Json::Value RunComputeSkinTest(CGameCtnEditorFree@ editor, CGameEditorPluginMapMapType@ pmt, Json::Value &in testIn, uint nbItems) {
        Json::Value result = Json::Object();
        int itemIndex = testIn.HasKey("itemIndex") ? int(testIn["itemIndex"]) : 0;
        string bgSkin = testIn.HasKey("bgSkin") ? string(testIn["bgSkin"]) : "";
        string fgSkin = testIn.HasKey("fgSkin") ? string(testIn["fgSkin"]) : "";
        result["itemIndex"] = itemIndex;
        result["bgSkin"] = bgSkin;
        result["fgSkin"] = fgSkin;

        if (itemIndex < 0 || uint(itemIndex) >= nbItems) {
            result["error"] = "itemIndex out of range (nb=" + tostring(nbItems) + ")";
            return result;
        }

        auto scriptItem = pmt.MacroblockInstanceItemsResults[uint(itemIndex)];
        if (scriptItem is null) {
            result["error"] = "computed item is null";
            return result;
        }

        CGameItemModel@ scriptModel;
        vec3 scriptPos;
        try {
            @scriptModel = scriptItem.ItemModel;
            scriptPos = scriptItem.Position;
        } catch {
            result["error"] = "could not read scriptItem fields: " + getExceptionInfo();
            return result;
        }

        int matchIdx = FindLiveItemIndex(editor, scriptModel, scriptPos);
        if (matchIdx < 0) {
            result["error"] = "no live map item matched";
            return result;
        }
        auto liveMapItem = editor.Challenge.AnchoredObjects[uint(matchIdx)];
        result["mapItemIndex"] = matchIdx;
        result["preSkin"] = ItemSkinToJson(liveMapItem);

        try {
            if (fgSkin.Length > 0) {
                pmt.SetItemSkins(scriptItem, bgSkin, fgSkin);
            } else {
                pmt.SetItemSkin(scriptItem, bgSkin);
            }
            result["setCalled"] = true;
        } catch {
            result["setError"] = getExceptionInfo();
            result["setCalled"] = false;
        }

        result["postSkin"] = ItemSkinToJson(liveMapItem);
        bool persisted = false;
        if (bool(result["postSkin"]["hasSkin"])) {
            persisted = string(result["postSkin"]["bgSkin"]) != string(result["preSkin"]["bgSkin"])
                || string(result["postSkin"]["fgSkin"]) != string(result["preSkin"]["fgSkin"]);
        }
        result["persisted"] = persisted;
        return result;
    }
}
#endif
