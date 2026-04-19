namespace TmMcp {
    Json::Value PluginMapTypeEnvironmentToJson(CGameEditorPluginMapMapType@ pluginMapType) {
        Json::Value output = Json::Object();
        if (pluginMapType is null) return output;

        output["mapType"] = pluginMapType.GetMapType();
        output["mapStyle"] = pluginMapType.GetMapStyle();
        output["collectionSquareSize"] = pluginMapType.CollectionSquareSize;
        output["collectionSquareHeight"] = pluginMapType.CollectionSquareHeight;
        output["collectionGroundY"] = int(pluginMapType.CollectionGroundY);
        return output;
    }

    Json::Value ChallengeEnvironmentToJson(CGameCtnChallenge@ map) {
        Json::Value output = Json::Object();
        if (map is null) return output;

        output["mapName"] = map.MapName;
        output["comments"] = map.Comments;
        output["collectionName"] = map.CollectionName;
        output["decorationName"] = map.DecorationName;
        output["mapType"] = map.MapType;
        output["mapStyle"] = map.MapStyle;
        output["mapTypeOrLegacyMode"] = map.MapTypeOrLegacyMode;
        output["authorLogin"] = map.AuthorLogin;
        output["authorNickName"] = map.AuthorNickName;
        output["authorZonePath"] = map.AuthorZonePath;
        output["hasCustomIntro"] = map.HasCustomIntro;
        output["hasCustomMusic"] = map.HasCustomMusic;
        output["copperPrice"] = int(map.CopperPrice);
        output["tmObjectiveAuthorTime"] = int(map.TMObjective_AuthorTime);
        output["tmObjectiveGoldTime"] = int(map.TMObjective_GoldTime);
        output["tmObjectiveSilverTime"] = int(map.TMObjective_SilverTime);
        output["tmObjectiveBronzeTime"] = int(map.TMObjective_BronzeTime);
        output["tmObjectiveNbLaps"] = int(map.TMObjective_NbLaps);
        output["tmObjectiveIsLapRace"] = map.TMObjective_IsLapRace;
        output["vehicleCollectionText"] = map.VehicleCollection_Text;
        output["decoBaseHeightOffset"] = int(map.DecoBaseHeightOffset);
        output["size"] = CoordToJson(map.Size);
        output["bounds"] = MapBoundsToJson(map.Size);
        return output;
    }

    Json::Value MapInfoEnvironmentToJson(CGameCtnChallengeInfo@ info) {
        Json::Value output = Json::Object();
        if (info is null) return output;

        output["mapUid"] = info.MapUid;
        output["nameForUi"] = info.NameForUi;
        output["comments"] = info.Comments;
        output["collectionName"] = info.CollectionName;
        output["mapType"] = info.MapType;
        output["mapStyle"] = info.MapStyle;
        output["isPlayable"] = info.IsPlayable;
        output["createdWithSimpleEditor"] = info.CreatedWithSimpleEditor;
        output["createdWithPartyEditor"] = info.CreatedWithPartyEditor;
        output["createdWithGamepadEditor"] = info.CreatedWithGamepadEditor;
        output["lapRace"] = info.LapRace;
        output["tmObjectiveAuthorTime"] = int(info.TMObjective_AuthorTime);
        output["tmObjectiveGoldTime"] = int(info.TMObjective_GoldTime);
        output["tmObjectiveSilverTime"] = int(info.TMObjective_SilverTime);
        output["tmObjectiveBronzeTime"] = int(info.TMObjective_BronzeTime);
        output["tmObjectiveNbLaps"] = int(info.TMObjective_NbLaps);
        output["tmObjectiveIsLapRace"] = info.TMObjective_IsLapRace;
        output["tmObjectiveNbClones"] = int(info.TMObjective_NbClones);
        output["mapCoordOrigin"] = Vec2ToJson(info.MapCoordOrigin);
        output["mapCoordTarget"] = Vec2ToJson(info.MapCoordTarget);
        return output;
    }

    Json::Value ChallengeParametersEnvironmentToJson(CGameCtnChallengeParameters@ challengeParams) {
        Json::Value output = Json::Object();
        if (challengeParams is null) return output;

        output["authorScore"] = int(challengeParams.AuthorScore);
        output["authorTime"] = int(challengeParams.AuthorTime);
        output["goldTime"] = int(challengeParams.GoldTime);
        output["silverTime"] = int(challengeParams.SilverTime);
        output["bronzeTime"] = int(challengeParams.BronzeTime);
        output["mapType"] = challengeParams.MapType;
        output["mapStyle"] = challengeParams.MapStyle;
        output["type"] = challengeParams.Type;
        output["style"] = challengeParams.Style;
        output["tip"] = challengeParams.Tip;
        output["isValidatedForScriptModes"] = challengeParams.IsValidatedForScriptModes;
        return output;
    }

    Json::Value EditorMoodToJson(CGameCtnEditorFree@ editor) {
        Json::Value output = Json::Object();
        if (editor is null) return output;

        output["isDynamicTime"] = editor.MoodIsDynamicTime;
        output["timeOfDay01"] = editor.MoodTimeOfDay01;
        output["timeOfDayStr"] = editor.MoodTimeOfDayStr;
        output["dayDurationStr"] = editor.MoodDayDurationStr;
        return output;
    }

    Json::Value@ GetMapEnvironment(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");

        Json::Value output = Json::Object();
        output["map"] = MapSummary(editor);
        output["challenge"] = ChallengeEnvironmentToJson(editor.Challenge);
        output["mapInfo"] = MapInfoEnvironmentToJson(editor.Challenge.MapInfo);
        output["challengeParameters"] = ChallengeParametersEnvironmentToJson(editor.Challenge.ChallengeParameters);
        output["mood"] = EditorMoodToJson(editor);
        output["pluginMapType"] = PluginMapTypeEnvironmentToJson(editor.PluginMapType);
        output["validation"] = ValidationToJson(editor.PluginMapType);
        output["readOnly"] = true;
        return MakeSuccess(output);
    }
}
