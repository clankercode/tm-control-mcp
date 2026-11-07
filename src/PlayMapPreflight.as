namespace TmMcp {
    bool PlayMapPathIsAbsolute(const string &in path) {
        return path.StartsWith("/") || path.StartsWith("\\")
            || (path.Length >= 3 && path[1] == 58 && (path[2] == 47 || path[2] == 92));
    }

    string ResolvePlayMapLocalPath(const string &in path) {
        if (PlayMapPathIsAbsolute(path)) return IO::FileExists(path) ? path : "";
        string relative = path.Replace("\\", "/");
        if (!relative.StartsWith("Maps/") && !relative.StartsWith("maps/")) relative = "Maps/" + relative;
        auto fid = Fids::GetUser(relative);
        if (fid !is null && fid.OSCheckIfExists()) {
            string full = string(fid.FullFileName);
            if (PlayMapPathIsAbsolute(full) && IO::FileExists(full)) return full;
        }
        string fallback = IO::FromUserGameFolder(relative);
        return PlayMapPathIsAbsolute(fallback) && IO::FileExists(fallback) ? fallback : "";
    }

    Json::Value PlayMapPreflight(const string &in path) {
        auto result = Json::Object();
        result["coverage"] = "envelope-only";
        result["embeddedContentVerified"] = false;
        result["state"] = "unresolved";
        result["warning"] = "Embedded map items are not validated. A plausible GBX envelope does not prevent native loader crashes; only load trusted content.";
        if (path.Contains("://")) { result["state"] = "remote_uninspected"; return result; }
        try {
            string resolved = ResolvePlayMapLocalPath(path);
            if (resolved.Length == 0) return result; // Engine paths may be virtual.
            IO::File f(resolved, IO::FileMode::Read);
            uint64 size = f.Size();
            string bytes = "";
            if (size >= 21) bytes = f.Read(21).ReadString(21);
            else if (size > 0) bytes = f.Read(size).ReadString(size);
            f.Close();
            result["fileBytes"] = int64(size);
            result["state"] = PlayMapEnvelopeState(bytes, size);
        } catch {
            result["state"] = "unreadable";
            result["reason"] = getExceptionInfo();
        }
        return result;
    }
}
