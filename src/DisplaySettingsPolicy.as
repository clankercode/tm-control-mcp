namespace TmMcp {
    // Pure display-setting policy: no game types, so
    // tests/test_display_settings_tools.py runs it in stock AngelScript. The
    // orchestration is in DisplaySettingsCore.as and the live game side in
    // DisplaySettingsTools.as.
    //
    // Only bloom (CSystemConfigDisplay.FxBloomHdr / the script wrapper's
    // FxBloomHdr) for now. Both enums are None, Medium, High in that order, so
    // the index 0/1/2 is the shared language between them.
    //
    // Bloom is the user's own setting and the game saves it to its config
    // (Documents/Trackmania/Config/Default.json). Every write is treated as
    // persistent; whether and when the game saves it is unproven (Q3), so the
    // tools report persisted:"assumed". SetDisplaySetting writes ONE restore
    // record before it changes anything and never overwrites it: while any
    // record exists, Set refuses. Only RestoreDisplaySetting {retire:true}
    // removes a valid record. Nothing restores automatically.

    const string DISPLAY_RESTORE_FILE = "bloom-restore.txt";
    const string DISPLAY_RECORD_SCHEMA = "3";
    const uint DISPLAY_RECORD_MAX_BYTES = 4096;

    // Record files earlier builds wrote: schema 1 (JSON) and schema 2 (with a
    // side file). They carry no usable identity, so they are never applied or
    // migrated. GetDisplaySetting reports them; Set refuses while one exists.
    array<string> DisplayLegacyRecordFiles() {
        array<string> names = {"display-restore.json", "display-restore.txt", "display-restore.next.txt"};
        return names;
    }

    // -1 unless name is exactly "none", "medium" or "high".
    int BloomIndex(const string &in name) {
        if (name == "none") return 0;
        if (name == "medium") return 1;
        if (name == "high") return 2;
        return -1;
    }

    // "" for an index outside the enum.
    string BloomName(int index) {
        if (index == 0) return "none";
        if (index == 1) return "medium";
        if (index == 2) return "high";
        return "";
    }

    // The CSystemConfig display block in effect: Display, or DisplaySafe
    // when the game runs in safe mode (IsSafeMode).
    string DisplayConfigName(bool safeMode) {
        return safeMode ? "safe" : "display";
    }

    // --- The restore record --------------------------------------------------
    // Exactly these lines, in this order, each ending in "\n":
    //   schema=3
    //   setting=bloom
    //   prior=high               the value before SetDisplaySetting
    //   target=none              the value SetDisplaySetting then wrote
    //   config=display           display | safe: the config block written
    //   identity=<hex>           the install it belongs to (a SHA-256)
    //   setAt=2026-11-18 23:30:00
    //   end=ok
    class DisplayRecord {
        string prior;
        string target;
        string config;
        string identity;
        string setAt;
    }

    // Lower-case hex, 16..128 chars (the live host uses a SHA-256).
    bool IsDisplayIdentity(const string &in s) {
        if (s.Length < 16 || s.Length > 128) return false;
        for (uint i = 0; i < uint(s.Length); i++) {
            uint8 c = s[i];
            if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
        }
        return true;
    }

    string DisplayRecordText(DisplayRecord@ r) {
        return "schema=" + DISPLAY_RECORD_SCHEMA + "\n"
            + "setting=bloom\n"
            + "prior=" + r.prior + "\n"
            + "target=" + r.target + "\n"
            + "config=" + r.config + "\n"
            + "identity=" + r.identity + "\n"
            + "setAt=" + r.setAt + "\n"
            + "end=ok\n";
    }

    bool _IsDisplayRecordKey(const string &in k) {
        return k == "schema" || k == "setting" || k == "prior" || k == "target" || k == "config"
            || k == "identity" || k == "setAt";
    }

    // null + reason unless the text is a complete schema-3 record in exactly
    // the form DisplayRecordText writes: canonical tokens, nothing missing,
    // nothing extra, and prior != target.
    DisplayRecord@ ParseDisplayRecord(const string &in text, string &out reason) {
        reason = "";
        if (text.Length == 0) { reason = "empty"; return null; }
        if (uint(text.Length) > DISPLAY_RECORD_MAX_BYTES) { reason = "too large"; return null; }
        auto lines = text.Split("\n");
        array<string> keys;
        array<string> values;
        bool ended = false;
        for (uint i = 0; i < lines.Length; i++) {
            string line = lines[i];
            if (ended) {
                // "end=ok\n" leaves one empty piece after the split.
                if (i == lines.Length - 1 && line.Length == 0) break;
                reason = "content after end=ok";
                return null;
            }
            int eq = line.IndexOf("=");
            if (eq <= 0) { reason = (line.Length == 0 ? "blank line " : "malformed line ") + (i + 1); return null; }
            string k = line.SubStr(0, eq);
            string v = line.SubStr(eq + 1);
            if (k == "end") {
                if (v != "ok") { reason = "bad end marker"; return null; }
                ended = true;
                continue;
            }
            if (!_IsDisplayRecordKey(k)) { reason = "unknown key " + k; return null; }
            if (keys.Find(k) >= 0) { reason = "duplicate key " + k; return null; }
            keys.InsertLast(k);
            values.InsertLast(v);
        }
        if (!ended) { reason = "truncated (no end=ok)"; return null; }
        int iSchema = keys.Find("schema"), iSetting = keys.Find("setting"), iPrior = keys.Find("prior");
        int iTarget = keys.Find("target"), iConfig = keys.Find("config"), iIdentity = keys.Find("identity");
        int iSetAt = keys.Find("setAt");
        if (iSchema < 0 || iSetting < 0 || iPrior < 0 || iTarget < 0 || iConfig < 0 || iIdentity < 0 || iSetAt < 0) {
            reason = "missing key";
            return null;
        }
        if (values[iSchema] != DISPLAY_RECORD_SCHEMA) { reason = "unknown schema " + values[iSchema]; return null; }
        if (values[iSetting] != "bloom") { reason = "unknown setting " + values[iSetting]; return null; }
        auto r = DisplayRecord();
        r.prior = values[iPrior];
        r.target = values[iTarget];
        r.config = values[iConfig];
        r.identity = values[iIdentity];
        r.setAt = values[iSetAt];
        // Canonical spelling only: BloomIndex accepts nothing else, so an
        // empty or misspelt token never maps to an index.
        if (BloomIndex(r.prior) < 0) { reason = "prior is not none|medium|high"; return null; }
        if (BloomIndex(r.target) < 0) { reason = "target is not none|medium|high"; return null; }
        if (r.prior == r.target) { reason = "prior and target are the same"; return null; }
        if (r.config != "display" && r.config != "safe") { reason = "config is not display|safe"; return null; }
        if (!IsDisplayIdentity(r.identity)) { reason = "identity is not a hex fingerprint"; return null; }
        if (r.setAt.Length == 0) { reason = "setAt is empty"; return null; }
        // Same bytes as this build writes: order, line ends, no stray spaces.
        if (DisplayRecordText(r) != text) { reason = "not in canonical form"; return null; }
        return r;
    }

    bool DisplayRecordsEqual(DisplayRecord@ a, DisplayRecord@ b) {
        if (a is null || b is null) return false;
        return a.prior == b.prior && a.target == b.target && a.config == b.config
            && a.identity == b.identity && a.setAt == b.setAt;
    }

    // The bloom an older record names, "" if none can be read. Reported only.
    //   display-restore.json (schema 1)           {"bloom":"high","setAt":...}
    //   display-restore(.next).txt (schema 2)     a prior=high line
    string LegacyRecordBloom(const string &in name, const string &in text) {
        if (name == "display-restore.json") {
            int k = text.IndexOf("\"bloom\"");
            if (k < 0) return "";
            string rest = text.SubStr(k + 7);
            uint i = 0;
            bool colon = false;
            while (i < uint(rest.Length)) {
                uint8 c = rest[i];
                if (c == 32 || c == 9 || c == 10 || c == 13) { i++; continue; }
                if (c == 58 && !colon) { colon = true; i++; continue; }
                break;
            }
            if (!colon || i >= uint(rest.Length) || rest[i] != 34) return "";
            string tail = rest.SubStr(int(i) + 1);
            int q = tail.IndexOf("\"");
            if (q < 0) return "";
            string v = tail.SubStr(0, q);
            return BloomIndex(v) >= 0 ? v : "";
        }
        auto lines = text.Split("\n");
        for (uint i = 0; i < lines.Length; i++) {
            string l = lines[i].Trim();
            if (l.StartsWith("prior=")) {
                string v = l.SubStr(6);
                return BloomIndex(v) >= 0 ? v : "";
            }
        }
        return "";
    }

    // What an explicit RestoreDisplaySetting does with a valid record whose
    // identity and config match. readable: sources read now; allPrior /
    // allTarget: every readable source holds that value; unreadableKnown: a
    // source known to exist could not be read (a wrapper someone else loaded).
    //  "unavailable"  nothing readable: keep the record
    //  "alreadyPrior" already at the prior: keep the record, write nothing
    //  "apply"        every source holds the target: write the prior back
    //  "conflict"     anything else: keep the record, write nothing
    // force (explicit request only) turns "conflict" into "apply", which
    // overwrites whatever the user has now.
    string RestoreDecision(uint readable, bool allPrior, bool allTarget, bool unreadableKnown, bool force) {
        if (readable == 0) return "unavailable";
        if (!unreadableKnown && allPrior) return "alreadyPrior";
        if (!unreadableKnown && allTarget) return "apply";
        return force ? "apply" : "conflict";
    }

    // Who has the game's DisplaySettings wrapper loaded right now.
    const int DISPLAY_WRAPPER_NONE = 0;
    const int DISPLAY_WRAPPER_OURS = 1;   // this tool loaded it and its release is not confirmed yet
    const int DISPLAY_WRAPPER_OTHER = 2;  // the settings page or another plugin
    // apiLoaded: api.DisplaySettings !is null. ownClaim: this tool loaded a
    // wrapper and has not seen it released. sameObject: the loaded wrapper is
    // the very one this tool loaded (handle comparison). A different wrapper
    // is someone else's, whatever this tool loaded before.
    int DisplayWrapperOwner(bool apiLoaded, bool ownClaim, bool sameObject) {
        if (!apiLoaded) return DISPLAY_WRAPPER_NONE;
        if (ownClaim && sameObject) return DISPLAY_WRAPPER_OURS;
        return DISPLAY_WRAPPER_OTHER;
    }

    // One write path per call, chosen before the write and never switched:
    // the script wrapper (what the settings page uses) when this call just
    // loaded, read and released one with no yield and nobody else has it
    // loaded; else the direct CSystemConfigDisplay write. A wrapper that
    // would need a frame to load is never waited for. Neither path yields.
    string ChooseBloomMechanism(bool wrapperLoadedWithoutYield, bool wrapperBusy) {
        if (wrapperLoadedWithoutYield && !wrapperBusy) return "wrapper";
        return "systemConfig";
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
