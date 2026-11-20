namespace TmMcp {
    // Pure input-binding helpers: no game types, so tests/test_input_bindings.py
    // runs them in stock AngelScript. The game side is InputBindings.as.

    // Action names are ManiaScript translation strings with a context prefix,
    // e.g. "|Input|Give up". Strips leading |context| groups; an unterminated
    // leading "|" is kept.
    string BindingActionName(const string &in name) {
        string s = name;
        while (s.Length > 1 && s.SubStr(0, 1) == "|") {
            int close = s.SubStr(1).IndexOf("|");
            if (close < 0) break;
            s = s.SubStr(close + 2);
        }
        return s;
    }

    // filterLower matches the action name or either form of its binding, so
    // "delete" finds every action bound to Delete. All inputs are lower-cased.
    bool BindingRowKept(const string &in actionLower, const string &in displayLower, const string &in rawLower,
                        const string &in filterLower, bool boundOnly) {
        if (boundOnly && displayLower.Length == 0 && rawLower.Length == 0) return false;
        if (filterLower.Length == 0) return true;
        return actionLower.IndexOf(filterLower) >= 0 || displayLower.IndexOf(filterLower) >= 0
            || rawLower.IndexOf(filterLower) >= 0;
    }

    // Content identity of the shared InputBindings_BindingsRaw list, used to
    // put back the list another reader left there. The count keeps one row
    // holding a newline apart from two rows.
    string BindingListSignature(const array<string> &in raws) {
        string sig = "" + raws.Length;
        for (uint i = 0; i < raws.Length; i++) sig += "\n" + raws[i];
        return sig;
    }
}
