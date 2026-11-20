namespace TmMcp {
    string FidsExtractionState(bool apiSucceeded, bool exists, uint64 expected, uint64 actual) {
        if (!apiSucceeded) return "api_failed";
        if (!exists) return "missing";
        if (expected == 0) return "size_unknown";
        return expected == actual ? "verified" : "size_mismatch";
    }
}
