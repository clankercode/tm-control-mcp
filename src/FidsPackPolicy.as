namespace TmMcp {
    const uint FIDS_PACK_OWNER_MAX = 8;
    const uint FIDS_PACK_PATH_MAX = 512;
    const uint FIDS_PACK_DEPTH_MAX = 16;
    const uint64 FIDS_PACK_COUNT_MAX = 1000000;

    bool FidsPackAsciiEquals(const string &in raw, const string &in upper) {
        if (raw.Length != upper.Length) return false;
        for (uint i = 0; i < uint(raw.Length); i++) {
            uint c = raw[i];
            if (c >= 97 && c <= 122) c -= 32;
            if (c != upper[i]) return false;
        }
        return true;
    }

    bool FidsPackReservedSegment(const string &in segment) {
        int dot = segment.IndexOf(".");
        string base = dot < 0 ? segment : segment.SubStr(0, uint(dot));
        // Windows also recognizes device basenames padded before an extension.
        // This is rejection analysis only; the caller's path is never changed.
        while (base.Length > 0 && base[base.Length - 1] == 32) base = base.SubStr(0, base.Length - 1);
        if (FidsPackAsciiEquals(base, "CON") || FidsPackAsciiEquals(base, "PRN")
            || FidsPackAsciiEquals(base, "AUX") || FidsPackAsciiEquals(base, "NUL")) return true;
        return base.Length == 4 && base[3] >= 48 && base[3] <= 57
            && (FidsPackAsciiEquals(base.SubStr(0, 3), "COM") || FidsPackAsciiEquals(base.SubStr(0, 3), "LPT"));
    }

    // Validate the original input. Never repair separators, trim, decode, or
    // remove traversal before this check; Windows aliases are refused too.
    bool IsFidsPackPath(const string &in raw) {
        if (raw.Length == 0 || uint(raw.Length) > FIDS_PACK_PATH_MAX || raw.IndexOf("..") >= 0) return false;
        for (uint i = 0; i < uint(raw.Length); i++) {
            uint c = raw[i];
            bool letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
            if (!letter && !(c >= 48 && c <= 57) && c != 45 && c != 95 && c != 46 && c != 32 && c != 47)
                return false;
        }
        auto parts = raw.Split("/");
        if (parts.Length > FIDS_PACK_DEPTH_MAX) return false;
        for (uint i = 0; i < parts.Length; i++) {
            string part = parts[i];
            if (part.Length == 0 || part.Length > 255 || part[0] == 32 || part[0] == 46
                || part[part.Length - 1] == 32 || part[part.Length - 1] == 46 || FidsPackReservedSegment(part)) return false;
        }
        return true;
    }

    void FidsPackSplitPath(const string &in path, string &out parentPath, string &out fileName) {
        auto parts = path.Split("/");
        fileName = parts[parts.Length - 1];
        parentPath = parts.Length == 1 ? "" : path.SubStr(0, path.Length - fileName.Length - 1);
    }

    int FidsPackBoundedCount(uint64 count) {
        return int(count > FIDS_PACK_COUNT_MAX ? FIDS_PACK_COUNT_MAX : count);
    }
}
