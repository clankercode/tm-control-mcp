// Pure update policy: no game, filesystem, HTTP, or wall-clock dependencies.
namespace TmMcp {
    const uint UPDATE_URL_LIMIT = 1024;
    const uint UPDATE_BODY_LIMIT = 1024;
    const uint UPDATE_VERSION_LIMIT = 256;
    const uint UPDATE_CACHE_LIMIT = 64;
    const uint64 UPDATE_START_SPACING_MS = 2000;
    const int64 UPDATE_SUCCESS_TTL = 6 * 60 * 60;
    const int64 UPDATE_RETRY_TTL = 30 * 60;

    class PackVersion {
        array<string> core;
        array<string> pre;
        string text;
    }

    bool VersionDigits(const string &in s) {
        if (s.Length == 0) return false;
        for (uint i = 0; i < uint(s.Length); i++) {
            if (s[i] < 48 || s[i] > 57) return false;
        }
        return true;
    }

    bool VersionIdentifiers(const string &in s, bool prerelease) {
        auto parts = s.Split(".");
        for (uint i = 0; i < parts.Length; i++) {
            string p = parts[i];
            if (p.Length == 0) return false;
            for (uint j = 0; j < uint(p.Length); j++) {
                uint8 c = p[j];
                if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 90)
                    || (c >= 97 && c <= 122) || c == 45)) return false;
            }
            if (prerelease && VersionDigits(p) && p.Length > 1 && p[0] == 48) return false;
        }
        return true;
    }

    PackVersion@ ParsePackVersion(const string &in raw) {
        if (uint(raw.Length) > UPDATE_BODY_LIMIT) return null;
        string s = raw.Trim();
        if (s.Length == 0 || uint(s.Length) > UPDATE_VERSION_LIMIT) return null;
        if (s.StartsWith("v")) s = s.SubStr(1);
        auto v = PackVersion();
        v.text = s;
        int plus = s.IndexOf("+");
        if (plus >= 0) {
            if (!VersionIdentifiers(s.SubStr(uint(plus) + 1), false)) return null;
            s = s.SubStr(0, uint(plus));
        }
        int dash = s.IndexOf("-");
        if (dash >= 0) {
            string pre = s.SubStr(uint(dash) + 1);
            if (!VersionIdentifiers(pre, true)) return null;
            v.pre = pre.Split(".");
            s = s.SubStr(0, uint(dash));
        }
        v.core = s.Split(".");
        if (v.core.Length != 3) return null;
        for (uint i = 0; i < 3; i++) {
            if (!VersionDigits(v.core[i]) || (v.core[i].Length > 1 && v.core[i][0] == 48)) return null;
        }
        return v;
    }

    // Decimal strings avoid overflow, including for arbitrarily large identifiers.
    int CompareVersionNumber(const string &in a, const string &in b) {
        if (a.Length != b.Length) return a.Length < b.Length ? -1 : 1;
        if (a == b) return 0;
        return a < b ? -1 : 1;
    }

    int ComparePackVersions(PackVersion@ a, PackVersion@ b) {
        for (uint i = 0; i < 3; i++) {
            int cmp = CompareVersionNumber(a.core[i], b.core[i]);
            if (cmp != 0) return cmp;
        }
        if (a.pre.Length == 0 && b.pre.Length == 0) return 0;
        if (a.pre.Length == 0) return 1;
        if (b.pre.Length == 0) return -1;
        uint count = a.pre.Length < b.pre.Length ? a.pre.Length : b.pre.Length;
        for (uint i = 0; i < count; i++) {
            string ap = a.pre[i], bp = b.pre[i];
            if (ap == bp) continue;
            bool an = VersionDigits(ap), bn = VersionDigits(bp);
            if (an && bn) return CompareVersionNumber(ap, bp);
            if (an != bn) return an ? -1 : 1;
            return ap < bp ? -1 : 1;
        }
        if (a.pre.Length == b.pre.Length) return 0;
        return a.pre.Length < b.pre.Length ? -1 : 1;
    }

    bool PackUpdateAvailable(const string &in installed, const string &in latest) {
        auto a = ParsePackVersion(installed);
        auto b = ParsePackVersion(latest);
        return a !is null && b !is null && ComparePackVersions(b, a) > 0;
    }

    // Canonical HTTPS URLs only: DNS host (no credentials/port/IP), explicit path,
    // no fragment, query, escaping or whitespace. Redirects are never followed.
    string PackUpdateUrlError(const string &in url) {
        if (url.Length == 0) return "No latestReleaseUrl; use SetLatestReleaseUrl with an HTTPS version-file URL.";
        if (uint(url.Length) > UPDATE_URL_LIMIT) return "latestReleaseUrl exceeds 1024 bytes.";
        if (!url.StartsWith("https://")) return "latestReleaseUrl must use https://.";
        int slash = url.SubStr(8).IndexOf("/");
        if (slash >= 0) slash += 8;
        if (slash < 0 || uint(slash) + 1 >= url.Length) return "latestReleaseUrl must include a DNS host and file path.";
        string host = url.SubStr(8, uint(slash) - 8);
        auto labels = host.Split(".");
        if (labels.Length < 2 || VersionDigits(labels[labels.Length - 1])) return "latestReleaseUrl requires a DNS host.";
        for (uint i = 0; i < labels.Length; i++) {
            string label = labels[i];
            if (label.Length == 0 || label.Length > 63 || label[0] == 45 || label[label.Length - 1] == 45)
                return "latestReleaseUrl has an invalid DNS host.";
            for (uint j = 0; j < uint(label.Length); j++) {
                uint8 c = label[j];
                if (!((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45))
                    return "latestReleaseUrl requires a lowercase DNS host without credentials or port.";
            }
        }
        string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-._~";
        for (uint i = uint(slash); i < uint(url.Length); i++) {
            if (allowed.IndexOf(url.SubStr(i, 1)) < 0) return "latestReleaseUrl path must be plain URL characters without query or fragment.";
        }
        return "";
    }

    class PackUpdateEntry {
        string url;
        string latestVersion;
        string error;
        int64 lastAttemptAt = 0;
        int64 lastSuccessAt = 0;
        int64 nextAttemptAt = 0;
        bool checking = false;
    }

    uint64 PackUpdateStartDelay(bool startedBefore, uint64 lastStart, uint64 now) {
        if (!startedBefore) return 0;
        if (now < lastStart) return UPDATE_START_SPACING_MS;
        uint64 elapsed = now - lastStart;
        return elapsed >= UPDATE_START_SPACING_MS ? 0 : UPDATE_START_SPACING_MS - elapsed;
    }

    bool PackUpdateDue(PackUpdateEntry@ e, int64 now) {
        return e !is null && !e.checking && (e.nextAttemptAt <= now || e.nextAttemptAt > now + UPDATE_SUCCESS_TTL);
    }

    void BeginPackUpdate(PackUpdateEntry@ e, int64 now) {
        e.checking = true;
        e.lastAttemptAt = now;
        // Persist before HTTP so reload during a failed/incomplete request backs off.
        e.nextAttemptAt = now + UPDATE_RETRY_TTL;
    }

    void FinishPackUpdate(PackUpdateEntry@ e, int64 now, const string &in body, const string &in error) {
        e.checking = false;
        auto version = ParsePackVersion(body);
        if (error.Length == 0 && version !is null) {
            e.latestVersion = version.text;
            e.lastSuccessAt = now;
            e.nextAttemptAt = now + UPDATE_SUCCESS_TTL;
            e.error = "";
        } else {
            e.error = error.Length > 0 ? error.SubStr(0, 256) : "Version file is not a valid semantic version.";
            e.nextAttemptAt = now + UPDATE_RETRY_TTL;
        }
    }

    string PackUpdateStatus(const string &in url, const string &in installed, PackUpdateEntry@ e, bool enabled, int64 now) {
        if (url.Length == 0) return "missing_url";
        if (PackUpdateUrlError(url).Length > 0) return "invalid_url";
        if (!enabled) return "disabled";
        if (e is null) return "pending";
        if (e.checking) return "checking";
        if (e.latestVersion.Length == 0) return e.error.Length > 0 ? "error" : "pending";
        if (e.error.Length > 0 || now < e.lastSuccessAt || now >= e.lastSuccessAt + UPDATE_SUCCESS_TTL) return "stale";
        if (ParsePackVersion(installed) is null) return "installed_version_unknown";
        return PackUpdateAvailable(installed, e.latestVersion) ? "update_available" : "up_to_date";
    }
    // Accept a ranged response only when it is the entire representation.
    bool CompleteVersionRange(const string &in range, uint length) {
        return length > 0 && range == "bytes 0-" + (length - 1) + "/" + length;
    }

}
