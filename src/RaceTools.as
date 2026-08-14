namespace TmMcp {
    // Race data tools ported from tm-mcptm (issue #2).
    // Depend on MLFeed::GetRaceData_V4 (plugin dependency "MLFeedRaceData").

    Json::Value@ GetRaceData(Json::Value &in input) {
        auto rd = MLFeed::GetRaceData_V4();
        if (rd is null) {
            return MakeError("race data not available", "no_race_data", false, "Race", "Requires MLFeedRaceData and an active playground");
        }

        Json::Value output = Json::Object();
        output["map"] = rd.Map;
        output["cpCount"] = rd.CPCount;
        output["lapCount"] = rd.LapCount;
        output["players"] = Json::Array();

        auto players = rd.SortedPlayers_Race;
        for (uint i = 0; i < players.Length; i++) {
            auto p = players[i];
            Json::Value playerObj = Json::Object();
            playerObj["name"] = p.Name;
            playerObj["cpCount"] = p.CpCount;
            playerObj["lastCpTime"] = p.LastCpTime;
            playerObj["bestTime"] = p.BestTime;
            playerObj["spawnStatus"] = int(p.SpawnStatus);
            playerObj["raceRank"] = p.RaceRank;
            playerObj["taRank"] = p.TaRank;
            output["players"].Add(playerObj);
        }

        return MakeSuccess(output);
    }

    Json::Value@ GetPlayers(Json::Value &in input) {
        auto rd = MLFeed::GetRaceData_V4();
        if (rd is null) {
            return MakeError("race data not available", "no_race_data", false, "Race", "Requires MLFeedRaceData and an active playground");
        }

        Json::Value output = Json::Object();
        Json::Value players = Json::Array();

        auto sortedPlayers = rd.SortedPlayers_Race;
        for (uint i = 0; i < sortedPlayers.Length; i++) {
            auto p = sortedPlayers[i];
            auto p4 = rd.GetPlayer_V4(p.Name);
            Json::Value playerObj = Json::Object();
            playerObj["name"] = p.Name;
            playerObj["cpCount"] = p.CpCount;
            playerObj["lastCpTime"] = p.LastCpTime;
            playerObj["finishTime"] = p.FinishTime;
            playerObj["bestTime"] = p.BestTime;
            playerObj["spawnStatus"] = int(p.SpawnStatus);
            playerObj["raceRank"] = p.RaceRank;
            playerObj["taRank"] = p.TaRank;
            playerObj["raceRespawnRank"] = p.RaceRespawnRank;
            if (p4 is null) {
                playerObj["login"] = Json::Value();
                playerObj["currentLap"] = 0;
                playerObj["teamNum"] = -1;
                playerObj["isMVP"] = false;
            } else {
                playerObj["login"] = p4.Login;
                playerObj["currentLap"] = p4.CurrentLap;
                playerObj["teamNum"] = p4.TeamNum;
                playerObj["isMVP"] = p4.IsMVP;
            }
            players.Add(playerObj);
        }

        output["players"] = players;
        output["count"] = int(players.Length);
        output["cpCount"] = rd.CPCount;
        output["map"] = rd.Map;
        return MakeSuccess(output);
    }

    Json::Value@ GetServerInfo(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.Network is null) {
            return MakeError("network not available", "no_network", false, "", "");
        }
        auto network = cast<CTrackManiaNetwork>(app.Network);
        auto serverInfo = network is null ? null : cast<CGameCtnNetServerInfo>(network.ServerInfo);

        Json::Value output = Json::Object();
        output["serverName"] = serverInfo is null ? "" : string(serverInfo.ServerName);
        output["connected"] = serverInfo !is null && serverInfo.ServerLogin.Length > 0;
        int playerCount = 0;
        if (network !is null && network.PlayerInfos.Length > 0) {
            playerCount = int(network.PlayerInfos.Length);
            if (playerCount > 0) playerCount -= 1;
        }
        output["playerCount"] = playerCount;
        output["maxPlayers"] = serverInfo is null ? 0 : int(serverInfo.MaxPlayerCount);

        return MakeSuccess(output);
    }
}
