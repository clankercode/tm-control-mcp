namespace TmMcp {
    uint PlayMapReadLE32(const string &in bytes, uint offset) {
        return uint(bytes[offset]) | (uint(bytes[offset + 1]) << 8)
            | (uint(bytes[offset + 2]) << 16) | (uint(bytes[offset + 3]) << 24);
    }

    string PlayMapEnvelopeState(const string &in bytes, uint64 fileSize) {
        if (fileSize < 17 || bytes.Length < 17 || bytes.SubStr(0, 3) != "GBX") return "invalid";
        if (bytes[3] != 6 || bytes[4] != 0 || bytes[5] != 66 || bytes[6] != 85) return "unknown_version";
        if (PlayMapReadLE32(bytes, 9) != 0x03043000) return "invalid";
        uint64 headerSize = PlayMapReadLE32(bytes, 13);
        if (headerSize > fileSize - 17) return "invalid";
        if (headerSize > 0) {
            if (headerSize < 4 || bytes.Length < 21) return "invalid";
            uint64 chunks = PlayMapReadLE32(bytes, 17);
            if (chunks > (headerSize - 4) / 8) return "invalid";
        }
        return "envelope_only";
    }
}
