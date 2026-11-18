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
    //
    // The record (schema 2, review 1 F1/F2) also holds every value the tool
    // applied under it and the install identity it was written on. It is
    // restored automatically only on the same install and only while the
    // setting still holds a value the tool applied; anything else is a
    // conflict that is reported and left alone.

    const string DISPLAY_RESTORE_FILE = "display-restore.txt";
    // A new record is written here, read back, then moved over the record.
    const string DISPLAY_RESTORE_NEXT_FILE = "display-restore.next.txt";
    const string DISPLAY_RECORD_SCHEMA = "2";
    const uint DISPLAY_RECORD_MAX_BYTES = 4096;

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

    // --- The restore record --------------------------------------------------
    // Plain key=value lines so this file can parse and check it with no JSON
    // library; the last line must be end=ok, so a truncated file never parses.
    //   schema=2
    //   setting=bloom
    //   prior=high               the user's value before the first Set
    //   applied=none,medium      every value the tool wrote under this record
    //   identity=<hex>           the install it was written on
    //   setAt=2026-11-18 19:50:00
    //   end=ok
    class DisplayRecord {
        string prior;
        array<string> applied;
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
        string applied = "";
        for (uint i = 0; i < r.applied.Length; i++) applied += (i == 0 ? "" : ",") + r.applied[i];
        return "# tm-control-mcp: the user's bloom before SetDisplaySetting. RestoreDisplaySetting puts it back.\n"
            + "schema=" + DISPLAY_RECORD_SCHEMA + "\n"
            + "setting=bloom\n"
            + "prior=" + r.prior + "\n"
            + "applied=" + applied + "\n"
            + "identity=" + r.identity + "\n"
            + "setAt=" + r.setAt + "\n"
            + "end=ok\n";
    }

    // null + reason when the text is not a complete, valid schema-2 record.
    DisplayRecord@ ParseDisplayRecord(const string &in text, string &out reason) {
        reason = "";
        if (text.Length == 0) { reason = "empty"; return null; }
        if (uint(text.Length) > DISPLAY_RECORD_MAX_BYTES) { reason = "too large"; return null; }
        auto lines = text.Split("\n");
        array<string> keys;
        array<string> values;
        bool ended = false;
        for (uint i = 0; i < lines.Length; i++) {
            string line = lines[i].Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            if (ended) { reason = "content after end=ok"; return null; }
            int eq = line.IndexOf("=");
            if (eq <= 0) { reason = "malformed line " + (i + 1); return null; }
            string k = line.SubStr(0, eq);
            string v = line.SubStr(eq + 1);
            if (keys.Find(k) >= 0) { reason = "duplicate key " + k; return null; }
            if (k == "end") {
                if (v != "ok") { reason = "bad end marker"; return null; }
                ended = true;
                continue;
            }
            if (k != "schema" && k != "setting" && k != "prior" && k != "applied" && k != "identity" && k != "setAt") {
                reason = "unknown key " + k;
                return null;
            }
            keys.InsertLast(k);
            values.InsertLast(v);
        }
        if (!ended) { reason = "truncated (no end=ok)"; return null; }
        int iSchema = keys.Find("schema"), iSetting = keys.Find("setting"), iPrior = keys.Find("prior");
        int iApplied = keys.Find("applied"), iIdentity = keys.Find("identity"), iSetAt = keys.Find("setAt");
        if (iSchema < 0 || iSetting < 0 || iPrior < 0 || iApplied < 0 || iIdentity < 0 || iSetAt < 0) {
            reason = "missing key";
            return null;
        }
        if (values[iSchema] != DISPLAY_RECORD_SCHEMA) { reason = "unknown schema " + values[iSchema]; return null; }
        if (values[iSetting] != "bloom") { reason = "unknown setting " + values[iSetting]; return null; }
        auto r = DisplayRecord();
        r.prior = values[iPrior];
        if (BloomName(BloomIndex(r.prior)) != r.prior) { reason = "prior is not none|medium|high"; return null; }
        if (values[iApplied].Length == 0) { reason = "applied is empty"; return null; }
        auto parts = values[iApplied].Split(",");
        for (uint i = 0; i < parts.Length; i++) {
            if (BloomName(BloomIndex(parts[i])) != parts[i]) { reason = "applied holds a value that is not none|medium|high"; return null; }
            if (r.applied.Find(parts[i]) >= 0) { reason = "applied repeats " + parts[i]; return null; }
            r.applied.InsertLast(parts[i]);
        }
        if (r.applied.Length == 0) { reason = "applied is empty"; return null; }
        r.identity = values[iIdentity];
        if (!IsDisplayIdentity(r.identity)) { reason = "identity is not a hex fingerprint"; return null; }
        r.setAt = values[iSetAt];
        return r;
    }

    bool DisplayRecordsEqual(DisplayRecord@ a, DisplayRecord@ b) {
        if (a is null || b is null) return false;
        if (a.prior != b.prior || a.identity != b.identity || a.setAt != b.setAt) return false;
        if (a.applied.Length != b.applied.Length) return false;
        for (uint i = 0; i < a.applied.Length; i++) if (a.applied[i] != b.applied[i]) return false;
        return true;
    }

    // What a restore does. sources: the value each source reads now, "" for
    // an unreadable one (wrapper, systemConfig).
    //  "unavailable"        nothing readable: keep the record
    //  "conflict-identity"  written on another install / profile: keep it, apply nothing
    //  "clear"              every readable source has the recorded prior: delete
    //  "apply"              every other value is one the tool applied: write the prior back
    //  "conflict-value"     a source holds a value the tool never applied (someone
    //                       changed it since): keep it, apply nothing
    // force (explicit RestoreDisplaySetting only) overrides both conflicts.
    string RestoreDecision(bool identityMatches, const array<string> &in sources, const string &in prior,
                           const array<string> &in applied, bool force) {
        uint readable = 0;
        bool allPrior = true;
        bool foreign = false;
        for (uint i = 0; i < sources.Length; i++) {
            if (BloomIndex(sources[i]) < 0) continue;
            readable++;
            if (sources[i] == prior) continue;
            allPrior = false;
            if (applied.Find(sources[i]) < 0) foreign = true;
        }
        if (readable == 0) return "unavailable";
        if (!identityMatches && !force) return "conflict-identity";
        if (allPrior) return "clear";
        if (foreign && !force) return "conflict-value";
        return "apply";
    }

    // SetDisplaySetting with a valid record already on disk: "" = go on
    // (keep the oldest prior, add the new value), else the conflict.
    string SetRecordConflict(bool identityMatches, const string &in current, const string &in prior,
                             const array<string> &in applied) {
        if (!identityMatches) return "identity";
        if (current != prior && applied.Find(current) < 0) return "value";
        return "";
    }

    // Which write path to use. The script wrapper (what the game's settings
    // page uses) first; a direct CSystemConfigDisplay write when the wrapper
    // is missing, its write did not read back, or someone else has it loaded
    // (F3: the tool never applies a wrapper it did not load).
    string ChooseBloomMechanism(bool wrapperAvailable, bool wrapperBusy, bool wrapperFailed) {
        if (wrapperAvailable && !wrapperBusy && !wrapperFailed) return "wrapper";
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
