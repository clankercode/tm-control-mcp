namespace TmMcp {
    // Pure helpers for ListManialinkPages / ViewManialinkPage: no game types, so
    // tests/test_manialink_view.py runs them in stock AngelScript. The game side
    // is ManialinkView.as.

    const uint ML_VIEW_TEXT_MAX = 60;

    // Short control type: "CGameManialinkLabel" -> "label".
    string MlShortType(const string &in className) {
        string prefix = "CGameManialink";
        string lower = MlLower(className.StartsWith(prefix) ? className.SubStr(prefix.Length) : className);
        return lower.Length > 0 ? lower : "?";
    }

    // Longest prefix / suffix of at most maxBytes that does not split a UTF-8
    // sequence (continuation bytes are 10xxxxxx).
    string MlUtf8Prefix(const string &in s, uint maxBytes) {
        if (uint(s.Length) <= maxBytes) return s;
        uint cut = maxBytes;
        while (cut > 0 && (s[cut] & 0xC0) == 0x80) cut--;
        return s.SubStr(0, cut);
    }

    string MlUtf8Suffix(const string &in s, uint maxBytes) {
        uint len = uint(s.Length);
        if (len <= maxBytes) return s;
        uint start = len - maxBytes;
        while (start < len && (s[start] & 0xC0) == 0x80) start++;
        return s.SubStr(start);
    }

    // One-line, quoted text capped at ML_VIEW_TEXT_MAX bytes of the raw value
    // (cut on a UTF-8 boundary before escaping, so an escape is never split).
    // keepTail keeps the end instead, for paths and URLs.
    string MlQuoteText(const string &in raw, bool keepTail = false) {
        string s = raw.Replace("\r", "").Replace("\t", " ");
        bool cut = uint(s.Length) > ML_VIEW_TEXT_MAX;
        if (cut) s = keepTail ? MlUtf8Suffix(s, ML_VIEW_TEXT_MAX) : MlUtf8Prefix(s, ML_VIEW_TEXT_MAX);
        s = s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
        return "\"" + (cut && keepTail ? "..." : "") + s + (cut && !keepTail ? "..." : "") + "\"";
    }

    // One tree line: "<indent>type#id .class1.class2 key=value ...".
    // Anonymous controls drop the "#id"; extras are pre-formatted tokens.
    string MlNodeLine(uint depth, const string &in shortType, const string &in id,
                      const array<string> &in classes, const array<string> &in extras) {
        string line = "";
        for (uint i = 0; i < depth; i++) line += "  ";
        line += shortType;
        if (id.Length > 0) line += "#" + id;
        if (classes.Length > 0) {
            line += " ";
            for (uint i = 0; i < classes.Length; i++) line += "." + classes[i];
        }
        for (uint i = 0; i < extras.Length; i++) {
            if (extras[i].Length > 0) line += " " + extras[i];
        }
        return line;
    }

    // An anonymous, visible, unfocused frame with exactly one shown child adds
    // a level but no information: print the child in its place.
    bool MlCollapseFrame(bool isFrame, const string &in id, uint classCount, uint shownChildren,
                         bool hidden, bool focused) {
        return isFrame && id.Length == 0 && classCount == 0 && shownChildren == 1 && !hidden && !focused;
    }

    // Nadeo menus mark clickable controls with a *navigation-item class
    // (component-navigation-item); the *-navigation-item-zone hitbox quads
    // inside them are not separate targets.
    bool MlIsClickable(const array<string> &in classes) {
        string suffix = "navigation-item";
        for (uint i = 0; i < classes.Length; i++) {
            uint len = uint(classes[i].Length);
            if (len >= uint(suffix.Length) && classes[i].SubStr(len - uint(suffix.Length)) == suffix) return true;
        }
        return false;
    }

    // Nadeo names clickable quads "button-..." without a navigation class
    // (the record list's button-toggle-ghost, button-spec-record).
    bool MlIdLooksClickable(const string &in id) {
        return id.StartsWith("button-") || id.StartsWith("button_");
    }

    // Brief view: keep text-bearing controls, clickables, the focus, and
    // frames that still hold something. Drops decoration (quads, empty
    // labels, empty frames).
    bool MlBriefKeep(bool isFrame, bool hasValue, uint keptChildren, bool focused, bool clickable) {
        if (focused || clickable) return true;
        return isFrame ? keptChildren > 0 : hasValue;
    }

    // Brief view: a single-child frame that is not itself a target or state
    // carrier is printed as its child (ids of layout wrappers are dropped).
    bool MlBriefCollapse(bool isFrame, bool clickable, uint keptChildren, uint cutChildren, bool hidden, bool focused) {
        return isFrame && !clickable && keptChildren == 1 && cutChildren == 0 && !hidden && !focused;
    }

    // Brief view: a clickable takes its single label child's text when that
    // child is a plain, visible, unfocused leaf label.
    bool MlBriefAbsorb(const string &in childType, uint childKids, bool childHidden, bool childFocused) {
        return childType == "label" && childKids == 0 && !childHidden && !childFocused;
    }

    // Case-insensitive (ASCII) substring test, for text filters.
    bool MlTextContains(const string &in haystack, const string &in needle) {
        return needle.Length == 0 || MlLower(haystack).IndexOf(MlLower(needle)) >= 0;
    }

    // WaitUntil caps for UI waits: the tool contract is a 5-minute ceiling.
    const int ML_WAIT_MAX_MS = 300000;
    const int ML_WAIT_DEFAULT_MS = 20000;

    int MlClampWaitMs(int requested) {
        if (requested < 0) return 0;
        return requested > ML_WAIT_MAX_MS ? ML_WAIT_MAX_MS : requested;
    }

    // "menu:12" style selectors name a ref; anything else is a manialink name.
    bool MlSelectorIsRef(const string &in selector) {
        return selector.IndexOf(":") >= 0;
    }

    // Page selector match: a ref exactly, or the name exactly, case-insensitively.
    bool MlPageMatches(const string &in selector, const string &in ref, const string &in nameLower) {
        if (selector.Length == 0) return false;
        if (MlSelectorIsRef(selector)) return selector == ref;
        return MlLower(selector) == nameLower;
    }

    string MlLower(const string &in s) {
        string lowered = s;
        for (uint i = 0; i < uint(lowered.Length); i++) {
            uint8 c = lowered[i];
            if (c >= 65 && c <= 90) lowered[i] = c + 32;
        }
        return lowered;
    }
}
