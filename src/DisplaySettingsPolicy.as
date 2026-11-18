namespace TmMcp {
    // Pure display-setting policy: no game types, so
    // tests/test_display_settings_tools.py runs it in stock AngelScript. The
    // live side is src/DisplaySettingsTools.as.
    //
    // Only bloom (CSystemConfigDisplay.FxBloomHdr / the script wrapper's
    // FxBloomHdr) for now. Both enums are None, Medium, High in that order, so
    // the index is the shared language between them.
    //
    // A display setting is the user's: the game saves it to its config
    // (Documents/Trackmania/Config/Default.json). Every write is treated as
    // persistent. The prior value goes to a restore record on disk BEFORE the
    // write, and the record keeps the OLDEST prior: a second Set must not
    // overwrite the user's real value with the tool's own earlier write.

    const string DISPLAY_RESTORE_FILE = "display-restore.json";

    // "" = not a bloom value.
    string NormalizeBloom(const string &in raw) {
        string s = raw.Trim();
        if (s == "none" || s == "None" || s == "NONE" || s == "off" || s == "Off") return "none";
        if (s == "medium" || s == "Medium" || s == "MEDIUM") return "medium";
        if (s == "high" || s == "High" || s == "HIGH") return "high";
        return "";
    }

    // -1 = not a bloom value.
    int BloomIndex(const string &in name) {
        string n = NormalizeBloom(name);
        if (n == "none") return 0;
        if (n == "medium") return 1;
        if (n == "high") return 2;
        return -1;
    }

    // "" for an index outside the enum.
    string BloomName(int index) {
        if (index == 0) return "none";
        if (index == 1) return "medium";
        if (index == 2) return "high";
        return "";
    }

    // Keep the oldest prior: only write a record when none exists.
    bool ShouldWriteRestoreRecord(bool recordExists) {
        return !recordExists;
    }

    // What a restore does:
    //  "none"  no record (nothing to restore)
    //  "apply" write the recorded value back, then delete the record
    //  "clear" the setting already has the recorded value: just delete
    //  "bad"   the record is unreadable: keep it, report, touch nothing
    string RestoreAction(bool recordExists, const string &in recorded, const string &in current) {
        if (!recordExists) return "none";
        if (NormalizeBloom(recorded).Length == 0) return "bad";
        if (NormalizeBloom(recorded) == NormalizeBloom(current)) return "clear";
        return "apply";
    }

    // Which write path to use. The script wrapper (what the game's settings
    // page uses) first; a direct CSystemConfigDisplay write only when the
    // wrapper is missing or its write did not read back.
    string ChooseBloomMechanism(bool wrapperAvailable, bool wrapperFailed) {
        if (wrapperAvailable && !wrapperFailed) return "wrapper";
        return "systemConfig";
    }

    // A write is verified only when every readable source reports the wanted
    // value. sourcesRead counts the readable ones; sourcesMatching those equal
    // to the wanted index.
    bool BloomWriteVerified(uint sourcesRead, uint sourcesMatching) {
        return sourcesRead > 0 && sourcesMatching == sourcesRead;
    }

    // Applying the wrapper applies the WHOLE wrapper, so window/mode changes
    // are watched (R2). Returns a comma-separated list of what changed.
    string DisplaySideEffects(uint dirtyBefore, uint dirtyAfter, int modeBefore, int modeAfter,
                              int winXBefore, int winYBefore, int winXAfter, int winYAfter) {
        string s = "";
        if (dirtyBefore != dirtyAfter) s += "dirtyCounter,";
        if (modeBefore != modeAfter) s += "displayMode,";
        if (winXBefore != winXAfter || winYBefore != winYAfter) s += "windowSize,";
        if (s.Length > 0) s = s.SubStr(0, s.Length - 1);
        return s;
    }
}
