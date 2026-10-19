// One worker owns all HTTP and persistence. API/UI paths only read this cache.
[Setting hidden]
bool S_TmMcpCheckUpdates = true;

namespace TmMcp {
    const string BRIDGE_UPDATE_URL = "https://clankercode.github.io/tm-control-mcp/latest-version.txt";
    const uint UPDATE_TIMEOUT_MS = 5000;
    const uint UPDATE_CACHE_FILE_LIMIT = 256 * 1024;
    array<PackUpdateEntry@> g_PackUpdates;
    bool g_UpdatesRunning = false;
    Net::HttpRequest@ g_UpdateRequest;
    bool g_UpdateStartedBefore = false;
    uint64 g_LastUpdateStart = 0;

    PackUpdateEntry@ FindPackUpdate(const string &in url) {
        for (uint i = 0; i < g_PackUpdates.Length; i++) {
            if (g_PackUpdates[i].url == url) return g_PackUpdates[i];
        }
        return null;
    }

    PackUpdateEntry@ EnsurePackUpdate(const string &in url, bool restoring = false) {
        if (PackUpdateUrlError(url).Length > 0) return null;
        auto e = FindPackUpdate(url);
        if (e !is null) return e;
        if (g_PackUpdates.Length >= UPDATE_CACHE_LIMIT) {
            // Historical disk records may fill free slots, but only a current
            // active URL may displace one. Never churn history during restore.
            if (restoring || !IsPackUpdateActive(url)) return null;
            array<bool> active;
            for (uint i = 0; i < g_PackUpdates.Length; i++) active.InsertLast(IsPackUpdateActive(g_PackUpdates[i].url));
            int victim = SelectInactivePackUpdate(g_PackUpdates, active);
            if (victim < 0) return null;
            g_PackUpdates.RemoveAt(uint(victim));
        }
        @e = PackUpdateEntry();
        e.url = url;
        g_PackUpdates.InsertLast(e);
        return e;
    }

    string UpdateCachePath() {
        return IO::FromStorageFolder("pack-updates-v1.json");
    }

    void SavePackUpdateCache() {
        try {
            auto data = Json::Array();
            for (uint i = 0; i < g_PackUpdates.Length; i++) {
                auto e = g_PackUpdates[i];
                auto o = Json::Object();
                o["url"] = e.url;
                o["latestVersion"] = e.latestVersion;
                o["error"] = e.error;
                o["lastAttemptAt"] = e.lastAttemptAt;
                o["lastSuccessAt"] = e.lastSuccessAt;
                o["nextAttemptAt"] = e.nextAttemptAt;
                data.Add(o);
            }
            Json::ToFile(UpdateCachePath(), data);
        } catch {
            warn("TM Control MCP could not save update cache: " + getExceptionInfo());
        }
    }

    void LoadPackUpdateCache() {
        try {
            string path = UpdateCachePath();
            if (!IO::FileExists(path) || IO::FileSize(path) > UPDATE_CACHE_FILE_LIMIT) return;
            auto data = Json::FromFile(path);
            if (data.GetType() != Json::Type::Array || data.Length > UPDATE_CACHE_LIMIT) return;
            int64 now = Time::Stamp;
            for (uint i = 0; i < data.Length; i++) {
                auto o = data[i];
                if (o.GetType() != Json::Type::Object || !o.HasKey("url") || !o.HasKey("latestVersion")
                    || !o.HasKey("error") || !o.HasKey("lastAttemptAt") || !o.HasKey("lastSuccessAt") || !o.HasKey("nextAttemptAt")) continue;
                if (o["url"].GetType() != Json::Type::String || o["latestVersion"].GetType() != Json::Type::String
                    || o["error"].GetType() != Json::Type::String || o["lastAttemptAt"].GetType() != Json::Type::Number
                    || o["lastSuccessAt"].GetType() != Json::Type::Number || o["nextAttemptAt"].GetType() != Json::Type::Number) continue;
                string url = string(o["url"]), latest = string(o["latestVersion"]);
                if (PackUpdateUrlError(url).Length > 0) continue;
                if (latest.Length > 0 && ParsePackVersion(latest) is null) continue;
                int64 attempted = int64(o["lastAttemptAt"]), succeeded = int64(o["lastSuccessAt"]), next = int64(o["nextAttemptAt"]);
                if (attempted < 0 || succeeded < 0 || next < 0 || attempted > now || succeeded > now || next > now + UPDATE_SUCCESS_TTL) continue;
                auto e = EnsurePackUpdate(url, true);
                if (e is null) continue;
                e.latestVersion = latest;
                e.error = string(o["error"]).SubStr(0, 256);
                e.lastAttemptAt = attempted;
                e.lastSuccessAt = succeeded;
                e.nextAttemptAt = next;
            }
        } catch {
            warn("TM Control MCP ignored unreadable update cache: " + getExceptionInfo());
        }
    }

    void StartPackUpdates() {
        if (g_UpdatesRunning) return;
        g_UpdatesRunning = true;
        startnew(CoroutineFunc(PackUpdatesLoop));
    }

    void StopPackUpdates() {
        g_UpdatesRunning = false;
        if (g_UpdateRequest !is null) {
            try { g_UpdateRequest.Cancel(); } catch {}
            @g_UpdateRequest = null;
        }
    }

    bool IsPackUpdateActive(const string &in url) {
        if (url == BRIDGE_UPDATE_URL) return true;
        for (uint p = 0; p < g_Packs.Length; p++) {
            if (g_Packs[p].latestReleaseUrl != url) continue;
            auto plugin = Meta::GetPluginFromID(g_Packs[p].pluginId);
            if (plugin !is null && plugin.Enabled) return true;
        }
        return false;
    }

    void FetchPackUpdate(PackUpdateEntry@ e) {
        // Global pacing in addition to URL TTLs; no burst when many packs register.
        // Short bounded sleeps keep stop/disable responsive during the gap.
        while (g_UpdatesRunning && S_TmMcpCheckUpdates) {
            uint64 delay = PackUpdateStartDelay(g_UpdateStartedBefore, g_LastUpdateStart, Time::Now);
            if (delay == 0) break;
            sleep(delay < 100 ? delay : 100);
        }
        if (!g_UpdatesRunning || !S_TmMcpCheckUpdates || !IsPackUpdateActive(e.url)) return;
        BeginPackUpdate(e, Time::Stamp);
        SavePackUpdateCache();
        string error = "", body = "";
        try {
            @g_UpdateRequest = Net::HttpRequest();
            g_UpdateRequest.Url = e.url;
            g_UpdateRequest.Method = Net::HttpMethod::Get;
            g_UpdateRequest.Redirect = false;
            // Ask cooperative servers for a bounded body, then enforce progress
            // and final size as well. Net has no hard receive-buffer-size option.
            g_UpdateRequest.Headers["Range"] = "bytes=0-1023";
            // Keep wire lengths comparable to the plain-text body length.
            g_UpdateRequest.Headers["Accept-Encoding"] = "identity";
            g_LastUpdateStart = Time::Now;
            g_UpdateStartedBefore = true;
            g_UpdateRequest.Start();
            uint64 started = Time::Now;
            while (g_UpdatesRunning && S_TmMcpCheckUpdates && !g_UpdateRequest.Finished()) {
                if (Time::Now - started >= UPDATE_TIMEOUT_MS) { error = "Update request timed out after 5 seconds."; break; }
                if (g_UpdateRequest.ProgressDownload() > int64(UPDATE_BODY_LIMIT)
                    || g_UpdateRequest.ProgressDownloadTotal() > int64(UPDATE_BODY_LIMIT)) {
                    error = "Version response exceeds 1024 bytes."; break;
                }
                sleep(25);
            }
            if (!g_UpdatesRunning) { e.checking = false; return; }
            if (!S_TmMcpCheckUpdates) error = "Update checks disabled during request.";
            if (error.Length == 0) {
                int code = g_UpdateRequest.ResponseCode();
                error = PackUpdateTransferError(g_UpdateRequest.Error(), code,
                    g_UpdateRequest.ProgressDownload(), g_UpdateRequest.ProgressDownloadTotal());
                if (error.Length == 0) {
                    body = g_UpdateRequest.String();
                    // A server can ignore Accept-Encoding: identity. Encoded
                    // Content-Length/Range apply to wire bytes, not String().
                    int64 encodedLength = g_UpdateRequest.ResponseHeader("Content-Encoding").Length > 0
                        ? g_UpdateRequest.ProgressDownload() : int64(-1);
                    error = PackUpdateBodyError(code, g_UpdateRequest.ResponseHeader("Content-Length"),
                        g_UpdateRequest.ResponseHeader("Content-Range"), body.Length, encodedLength);
                }
            }
            if (error.Length > 0) g_UpdateRequest.Cancel();
        } catch {
            error = "Version request failed: " + getExceptionInfo();
            if (g_UpdateRequest !is null) { try { g_UpdateRequest.Cancel(); } catch {} }
        }
        @g_UpdateRequest = null;
        if (!g_UpdatesRunning) { e.checking = false; return; }
        FinishPackUpdate(e, Time::Stamp, body, error);
        SavePackUpdateCache();
    }

    void PackUpdatesLoop() {
        if (!g_UpdatesRunning) return;
        // Reserve the bridge slot even when disk already contains 64 old packs.
        EnsurePackUpdate(BRIDGE_UPDATE_URL);
        LoadPackUpdateCache();
        while (g_UpdatesRunning) {
            if (S_TmMcpCheckUpdates) {
                EnsurePackUpdate(BRIDGE_UPDATE_URL);
                for (uint i = 0; i < g_Packs.Length; i++) EnsurePackUpdate(g_Packs[i].latestReleaseUrl);
                for (uint i = 0; i < g_PackUpdates.Length && g_UpdatesRunning && S_TmMcpCheckUpdates; i++) {
                    auto e = g_PackUpdates[i];
                    if (IsPackUpdateActive(e.url) && PackUpdateDue(e, Time::Stamp)) FetchPackUpdate(e);
                }
            }
            sleep(1000);
        }
    }

    // updateAvailable is always boolean; false also means unknown, disabled,
    // missing/invalid URL, or no cache. Inspect updateStatus before interpreting it.
    // A stale/checking cached success may still report true, with updateStale=true.
    void AppendPackUpdateStatus(Json::Value@ o, const string &in pluginId, const string &in url) {
        auto plugin = Meta::GetPluginFromID(pluginId);
        string installed = plugin is null ? "" : plugin.Version;
        auto e = FindPackUpdate(url);
        string urlError = PackUpdateUrlError(url);
        string status = PackUpdateStatus(url, installed, e, S_TmMcpCheckUpdates, Time::Stamp);
        if (status == "pending" && e is null && g_PackUpdates.Length >= UPDATE_CACHE_LIMIT) status = "cache_full";
        o["installedVersion"] = installed;
        o["latestReleaseUrl"] = url;
        o["latestVersion"] = e is null ? "" : e.latestVersion;
        o["updateAvailable"] = S_TmMcpCheckUpdates && urlError.Length == 0 && e !is null && PackUpdateAvailable(installed, e.latestVersion);
        o["updateStatus"] = status;
        o["updateError"] = urlError.Length > 0 ? urlError : (e is null ? "" : e.error);
        o["updateStale"] = e !is null && e.latestVersion.Length > 0 && (e.error.Length > 0 || Time::Stamp < e.lastSuccessAt || Time::Stamp >= e.lastSuccessAt + UPDATE_SUCCESS_TTL);
        o["lastCheckedAt"] = e is null ? int64(0) : e.lastAttemptAt;
        o["lastSuccessAt"] = e is null ? int64(0) : e.lastSuccessAt;
        o["nextCheckAt"] = e is null ? int64(0) : e.nextAttemptAt;
        auto warnings = Json::Array();
        if (urlError.Length > 0) warnings.Add(urlError);
        if (status == "cache_full") warnings.Add("Update cache limit of 64 URLs reached; this URL is not scheduled.");
        o["warnings"] = warnings;
    }

    Json::Value@ BridgeUpdateStatus() {
        auto o = Json::Object();
        auto self = SelfPlugin();
        string id = self is null ? "tm-control-mcp" : self.ID;
        o["id"] = id;
        o["plugin"] = id;
        AppendPackUpdateStatus(o, id, BRIDGE_UPDATE_URL);
        return o;
    }
}
