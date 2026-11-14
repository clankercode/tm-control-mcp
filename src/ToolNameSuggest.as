namespace TmMcp {
    // Help for unknown tool names. Pure (no game types): ToolNameSuggest_Test.as
    // runs in Openplanet's [Test] runner and, through tests/test_tool_name_suggest.py,
    // in stock AngelScript.

    const uint UNKNOWN_TOOL_MAX_SUGGESTIONS = 5;
    // Longer input is not a mistyped tool name: it is neither echoed nor matched.
    const uint UNKNOWN_TOOL_MAX_NAME = 64;
    const string UNKNOWN_TOOL_HINT = "Tool names are case-sensitive. The tool list is a socket route, not a tool: {\"route\":\"catalog\"} (python3 tools/call.py catalog; names at data.tools[].name).";

    bool _IsUpperAscii(uint8 c) { return c >= 65 && c <= 90; }
    bool _IsLowerAscii(uint8 c) { return c >= 97 && c <= 122; }
    bool _IsDigitAscii(uint8 c) { return c >= 48 && c <= 57; }

    // The caller's own name goes back in the error only when it looks like a tool
    // name: letters, digits, '.', '_', '-'. Never spaces, newlines or long payloads.
    bool IsEchoableToolName(const string &in name) {
        uint n = uint(name.Length);
        if (n == 0 || n > UNKNOWN_TOOL_MAX_NAME) return false;
        for (uint i = 0; i < n; i++) {
            uint8 c = name[i];
            if (!_IsUpperAscii(c) && !_IsLowerAscii(c) && !_IsDigitAscii(c) && c != 46 && c != 95 && c != 45) return false;
        }
        return true;
    }

    string AsciiLower(const string &in s) {
        string lower = s;
        for (uint i = 0; i < uint(lower.Length); i++) {
            uint8 c = lower[i];
            if (_IsUpperAscii(c)) lower[i] = uint8(c + 32);
        }
        return lower;
    }

    // Verbs agents reach for that the catalog spells Control* (ReloadPlugin ->
    // ControlPlugin), and plurals (ListPlugins / ControlPlugin share "plugin").
    string _CanonicalToolWord(const string &in word) {
        if (word == "reload" || word == "unload" || word == "enable" || word == "disable"
            || word == "toggle" || word == "restart") return "control";
        uint n = uint(word.Length);
        if (n > 3 && word[n - 1] == 115) return word.SubStr(0, n - 1);
        return word;
    }

    bool _IsFillerToolWord(const string &in word) {
        return word == "get" || word == "set" || word == "list" || word == "to" || word == "by";
    }

    // "CarControl.GetStatus" -> car, control, get, statu; "GetUILayers" -> get, ui, layer.
    array<string> ToolNameWords(const string &in name) {
        array<string> words;
        uint n = uint(name.Length);
        int start = -1;
        for (uint i = 0; i <= n; i++) {
            uint8 c = 0;
            if (i < n) c = name[i];
            bool alnum = _IsUpperAscii(c) || _IsLowerAscii(c) || _IsDigitAscii(c);
            bool split = !alnum;
            if (alnum && start >= 0 && _IsUpperAscii(c)) {
                bool nextLower = i + 1 < n && _IsLowerAscii(name[i + 1]);
                split = !_IsUpperAscii(name[i - 1]) || nextLower;
            }
            if (split && start >= 0) {
                words.InsertLast(_CanonicalToolWord(AsciiLower(name.SubStr(start, int(i) - start))));
                start = -1;
            }
            if (alnum && start < 0) start = int(i);
        }
        return words;
    }

    uint SharedToolWords(const array<string> &in asked, const array<string> &in known) {
        uint count = 0;
        for (uint i = 0; i < asked.Length; i++) {
            if (_IsFillerToolWord(asked[i]) || known.Find(asked[i]) < 0) continue;
            bool repeat = false;
            for (uint k = 0; k < i; k++) if (asked[k] == asked[i]) repeat = true;
            if (!repeat) count++;
        }
        return count;
    }

    uint ToolNameEditDistance(const string &in a, const string &in b) {
        uint n = uint(a.Length);
        uint m = uint(b.Length);
        array<uint> prev;
        array<uint> cur;
        for (uint j = 0; j <= m; j++) { prev.InsertLast(j); cur.InsertLast(0); }
        for (uint i = 1; i <= n; i++) {
            cur[0] = i;
            for (uint j = 1; j <= m; j++) {
                uint cost = a[i - 1] == b[j - 1] ? 0 : 1;
                uint best = prev[j] + 1;
                if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1;
                if (prev[j - 1] + cost < best) best = prev[j - 1] + cost;
                cur[j] = best;
            }
            for (uint j = 0; j <= m; j++) prev[j] = cur[j];
        }
        return prev[m];
    }

    // The closest real names, best first: same name in another case, then most
    // shared words, then containment, then edit distance; ties by name.
    array<string> SuggestToolNames(const string &in asked, const array<string> &in known) {
        array<string> picks;
        uint n = uint(asked.Length);
        if (n == 0 || n > UNKNOWN_TOOL_MAX_NAME) return picks;
        string askedLower = AsciiLower(asked);
        array<string> askedWords = ToolNameWords(asked);
        uint tolerance = n / 4;
        if (tolerance < 2) tolerance = 2;
        array<string> names;
        array<uint> scores;
        for (uint i = 0; i < known.Length; i++) {
            string name = known[i];
            if (name.Length == 0 || name == asked || uint(name.Length) > 4 * UNKNOWN_TOOL_MAX_NAME) continue;
            string lower = AsciiLower(name);
            uint score = 0;
            if (lower == askedLower) score += 1000000;
            score += 10000 * SharedToolWords(askedWords, ToolNameWords(name));
            if (n >= 4 && (lower.IndexOf(askedLower) >= 0 || askedLower.IndexOf(lower) >= 0)) score += 1000;
            uint distance = ToolNameEditDistance(askedLower, lower);
            if (score == 0 && distance > tolerance) continue;
            if (distance < 999) score += 999 - distance;
            names.InsertLast(name);
            scores.InsertLast(score);
        }
        while (picks.Length < UNKNOWN_TOOL_MAX_SUGGESTIONS && names.Length > 0) {
            uint best = 0;
            for (uint i = 1; i < names.Length; i++) {
                if (scores[i] > scores[best] || (scores[i] == scores[best] && names[i] < names[best])) best = i;
            }
            picks.InsertLast(names[best]);
            names.RemoveAt(best);
            scores.RemoveAt(best);
        }
        return picks;
    }
}
