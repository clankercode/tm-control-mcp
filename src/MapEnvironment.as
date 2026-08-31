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
        auto map = GetChallenge();
        if (map is null) return NeedMap();

        Json::Value output = Json::Object();
        output["map"] = MapSummary(map);
        output["challenge"] = ChallengeEnvironmentToJson(map);
        output["mapInfo"] = MapInfoEnvironmentToJson(map.MapInfo);
        output["challengeParameters"] = ChallengeParametersEnvironmentToJson(map.ChallengeParameters);
        auto editor = GetEditor();
        if (editor !is null) {
            output["mood"] = EditorMoodToJson(editor);
            output["pluginMapType"] = PluginMapTypeEnvironmentToJson(editor.PluginMapType);
            output["validation"] = ValidationToJson(editor.PluginMapType);
        }
        output["readOnly"] = true;
        return MakeSuccess(output);
    }

    const string SHADOWS_QUALITY_HINT = "NotComputed|VeryFast|Fast|Default|High|Ultra or 0..5";

    string ShadowsQualityName(CGameEditorPluginMap::EShadowsQuality quality) {
        return tostring(quality);
    }

    // Accepts omitted (default Default), int 0..5, or enum name (case-insensitive;
    // hyphens/underscores/spaces ignored). Used by ComputeShadows.
    bool ParseShadowsQuality(Json::Value &in input, CGameEditorPluginMap::EShadowsQuality &out quality, string &out err) {
        quality = CGameEditorPluginMap::EShadowsQuality::Default;
        err = "";
        if (!input.HasKey("quality")) return true;

        Json::Value@ q = input["quality"];
        if (q is null || q.GetType() == Json::Type::Null) return true;

        if (q.GetType() == Json::Type::Number) {
            int n = int(q);
            if (n < 0 || n > 5) {
                err = "quality int must be 0..5 (" + SHADOWS_QUALITY_HINT + ")";
                return false;
            }
            quality = CGameEditorPluginMap::EShadowsQuality(n);
            return true;
        }

        if (q.GetType() != Json::Type::String) {
            err = "quality must be a string or int (" + SHADOWS_QUALITY_HINT + ")";
            return false;
        }

        string raw = string(q);
        string s = raw.ToLower().Replace("_", "").Replace("-", "").Replace(" ", "");
        if (s.Length == 0) {
            err = "quality is empty (" + SHADOWS_QUALITY_HINT + ")";
            return false;
        }
        if (s == "notcomputed" || s == "0") {
            quality = CGameEditorPluginMap::EShadowsQuality::NotComputed;
        } else if (s == "veryfast" || s == "vfast" || s == "1") {
            quality = CGameEditorPluginMap::EShadowsQuality::VeryFast;
        } else if (s == "fast" || s == "2") {
            quality = CGameEditorPluginMap::EShadowsQuality::Fast;
        } else if (s == "default" || s == "3") {
            quality = CGameEditorPluginMap::EShadowsQuality::Default;
        } else if (s == "high" || s == "4") {
            quality = CGameEditorPluginMap::EShadowsQuality::High;
        } else if (s == "ultra" || s == "5") {
            quality = CGameEditorPluginMap::EShadowsQuality::Ultra;
        } else {
            err = "unknown quality: " + raw + " (" + SHADOWS_QUALITY_HINT + ")";
            return false;
        }
        return true;
    }

    Json::Value@ SetMoodTimeOfDay(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null) {
            return MakeError("not in map editor", "NOT_IN_EDITOR", true, "Editor",
                "Need CGameCtnEditorFree. Use GetMode / WaitUntil equals=MapEditor.");
        }
        if (!input.HasKey("timeOfDay01")) {
            return MakeError("missing timeOfDay01", "INVALID_INPUT", false, "",
                "timeOfDay01: float 0..1 (0 = midnight, 0.5 = noon)");
        }
        if (input["timeOfDay01"].GetType() != Json::Type::Number) {
            return MakeError("timeOfDay01 must be a number 0..1", "INVALID_INPUT", false, "",
                "timeOfDay01: float 0..1");
        }
        float tod = float(input["timeOfDay01"]);
        if (tod < 0.0 || tod > 1.0) {
            return MakeError("timeOfDay01 must be 0..1, got " + Text::Format("%f", tod), "INVALID_INPUT", false, "",
                "0 = midnight, 0.5 = noon, 1 = next midnight");
        }

        Json::Value prev = Json::Object();
        prev["timeOfDay01"] = editor.MoodTimeOfDay01;
        prev["timeOfDayStr"] = editor.MoodTimeOfDayStr;
        prev["isDynamicTime"] = editor.MoodIsDynamicTime;

        editor.MoodTimeOfDay01 = tod;
        if (input.HasKey("dynamic")) {
            editor.MoodIsDynamicTime = bool(input["dynamic"]);
        }

        Json::Value nxt = Json::Object();
        nxt["timeOfDay01"] = editor.MoodTimeOfDay01;
        nxt["timeOfDayStr"] = editor.MoodTimeOfDayStr;
        nxt["isDynamicTime"] = editor.MoodIsDynamicTime;

        Json::Value output = Json::Object();
        output["previous"] = prev;
        output["new"] = nxt;
        output["timeOfDay01"] = editor.MoodTimeOfDay01;
        output["timeOfDayStr"] = editor.MoodTimeOfDayStr;
        return MakeSuccess(output);
    }

    // Decoration mood stores HmsLightMap as a fid more often than a live nod.
    // Campaign / env-mod maps often have fid.Nod == null; walk the loaded HmsPack.
    CHmsLightMap@ GetMapLightMap(CGameCtnChallenge@ map) {
        if (map is null || map.Decoration is null) return null;
        auto mood = map.Decoration.DecoMood;
        if (mood is null || mood.HmsLightMap is null) return null;
        CSystemFidFile@ lmFid = cast<CSystemFidFile>(mood.HmsLightMap);
        if (lmFid is null) return mood.HmsLightMap;
        if (lmFid.Nod is null) {
            auto lmFolder = Fids::GetGameFolder("GameData/LightMap/HmsPackLightMap");
            if (lmFolder !is null) {
                for (uint i = 0; i < lmFolder.Leaves.Length; i++) {
                    auto lm = cast<CHmsLightMap>(lmFolder.Leaves[i].Nod);
                    if (lm !is null) return lm;
                }
            }
        }
        return cast<CHmsLightMap>(lmFid.Nod);
    }

    CHmsLightMapCache@ GetMapLightMapCache(CGameCtnEditorFree@ editor) {
        CGameCtnChallenge@ map = null;
        if (editor !is null) @map = editor.Challenge;
        if (map is null) @map = GetChallenge();
        auto lm = GetMapLightMap(map);
        if (lm is null || lm.m_PImp is null) return null;
        return lm.m_PImp.Cache;
    }

    Json::Value@ ComputeShadows(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null) {
            return MakeError("not in map editor", "NOT_IN_EDITOR", true, "Editor",
                "Need CGameCtnEditorFree. Use GetMode / WaitUntil equals=MapEditor.");
        }
        if (editor.PluginMapType is null) {
            return MakeError("editor PluginMapType not available", "NOT_IN_EDITOR", true, "Editor",
                "Need editor.PluginMapType.ComputeShadows1.");
        }

        CGameEditorPluginMap::EShadowsQuality quality;
        string qerr;
        if (!ParseShadowsQuality(input, quality, qerr)) {
            return MakeError(qerr, "INVALID_INPUT", false, "", SHADOWS_QUALITY_HINT);
        }

        bool bustCache = true;
        if (input.HasKey("bustCache")) bustCache = bool(input["bustCache"]);

        if (bustCache) {
            auto cache = GetMapLightMapCache(editor);
            if (cache is null) {
                return MakeError(
                    "lightmap cache not available",
                    "NO_LM_CACHE",
                    true,
                    "Editor",
                    "bustCache zeros CHmsLightMapCache.m_Quality; need map.Decoration.DecoMood.HmsLightMap.m_PImp.Cache. Retry after the map finishes loading, or pass bustCache=false."
                );
            }
            auto cacheTy = Reflection::GetType("CHmsLightMapCache");
            auto qualityMem = cacheTy !is null ? cacheTy.GetMember("m_Quality") : null;
            if (qualityMem is null || qualityMem.Offset == 0xFFFF) {
                return MakeError(
                    "CHmsLightMapCache.m_Quality offset unavailable",
                    "NO_LM_CACHE",
                    true,
                    "Editor",
                    "bustCache needs Reflection::GetType(CHmsLightMapCache).GetMember(m_Quality)."
                );
            }
            Dev::SetOffset(cache, qualityMem.Offset, int(0));
        }

        try {
            editor.PluginMapType.ComputeShadows1(quality);
        } catch {
            return MakeError(
                "ComputeShadows1 failed: " + getExceptionInfo(),
                "COMPUTE_SHADOWS_FAILED",
                true,
                "Editor",
                "Change time of day with SetMoodTimeOfDay and retry; the game refuses a second bake when shadows are already cached for that mood."
            );
        }

        Json::Value output = Json::Object();
        output["started"] = true;
        output["quality"] = ShadowsQualityName(quality);
        output["qualityInt"] = int(quality);
        output["bustCache"] = bustCache;
        output["lightmapCompute"] = LightmapComputeSnapshot();
        return MakeSuccess(output);
    }
}
