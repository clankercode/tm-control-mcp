namespace TmMcp {
    // Pure call-overlay helpers: no game types, so tests/test_call_overlay.py
    // runs them in stock AngelScript. The game side is CallOverlay.as.

    // "Present.Events, Present.Heartbeat," -> {"Present.Events", "Present.Heartbeat"}.
    // Names are trimmed; empty entries are dropped. Tool names are
    // case-sensitive, so matching is exact.
    array<string> CallOverlayParseHideList(const string &in raw) {
        array<string> names;
        auto parts = raw.Split(",");
        for (uint i = 0; i < parts.Length; i++) {
            string name = parts[i].Trim();
            if (name.Length > 0 && names.Find(name) < 0) names.InsertLast(name);
        }
        return names;
    }

    // "MCP tools: 766 (512 hidden)", or "MCP tools: 766" when none are hidden.
    string CallOverlayHeaderText(uint64 calls, uint64 hidden) {
        string header = "MCP tools: " + calls;
        if (hidden > 0) header += " (" + hidden + " hidden)";
        return header;
    }
}
