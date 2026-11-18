namespace TmMcp {
    // Get/Set/RestoreDisplaySetting orchestration with no game types: every
    // setting read/write, wrapper call, file operation and yield goes through
    // DisplayHost. src/DisplaySettingsTools.as is the live host;
    // tests/test_display_settings_tools.py runs this file in stock
    // AngelScript against a fake game and a fake disk.
    //
    // Two places hold bloom, both enum None/Medium/High (index 0/1/2):
    //   wrapper       app.ManiaPlanetScriptAPI.DisplaySettings, after
    //                 DisplaySettings_LoadCurrent(); written with
    //                 DisplaySettings_Apply(), released with _Unload(). The
    //                 script API the game's settings page is built on.
    //   systemConfig  Viewport.SystemConfig.Display(Safe).FxBloomHdr.
    //
    // Rules (review 1):
    //  F1  an existing record is parsed and validated before any write; an
    //      invalid one refuses RESTORE_RECORD_INVALID and nothing changes. A
    //      new record is written to a side file, read back and validated
    //      (the exact prior), and only then moved into place, read back again
    //      and the bloom written.
    //  F2  the record holds the schema, the prior, every applied value and
    //      the install identity. Automatic restore (plugin start / disable /
    //      unload) applies only on the same install and only while every
    //      readable source holds the prior or a value the tool applied.
    //      Anything else is a conflict: record kept, nothing applied.
    //  F3  a wrapper someone else loaded is never applied: Set refuses
    //      WRAPPER_BUSY before writing, Restore uses the direct systemConfig
    //      write. A wrapper the tool loaded is unloaded on every path.
    //  F4  the record is deleted only when EVERY readable source reads the
    //      prior back.
    //
    // UNPROVEN live (2026-11-18): that None removes bloom at once with no
    // restart (Q2), and that Apply neither resets the window/device nor saves
    // Default.json at once (Q3).

    class DisplayWatch {
        bool ok = false;
        uint dirty = 0;
        int mode = -1;
        int winX = 0;
        int winY = 0;
    }

    interface DisplayHost {
        void Yield();
        string Now();                       // setAt text
        string InstallIdentity();           // "" when it cannot be read
        Json::Value@ IdentityJson();        // what the identity is made of (no raw paths)
        bool SafeMode();
        // -1 when unavailable.
        int ReadSystemConfig();
        bool WriteSystemConfig(int index, string &out err);
        bool ScriptApiAvailable();
        // Someone else (the settings page, another plugin) has the wrapper loaded.
        bool WrapperLoadedByOther();
        // Load / read / write+Apply / unload a wrapper THIS tool loads.
        bool WrapperLoad(string &out err);
        int WrapperRead();
        bool WrapperWriteApply(int index, string &out err);
        void WrapperUnload();
        DisplayWatch@ WrapperWatch();
        // The record file. Read: false when missing; text may be anything.
        bool FileExists(const string &in name);
        bool FileRead(const string &in name, string &out text, string &out err);
        // Write, flush and close.
        bool FileWrite(const string &in name, const string &in text, string &out err);
        bool FileMove(const string &in from, const string &in to, string &out err);
        bool FileDelete(const string &in name, string &out err);
        string FilePath(const string &in name);
        void Log(const string &in message);
    }

    // null for an unreadable source, else "none"|"medium"|"high".
    Json::Value _BloomJson(int index) {
        Json::Value v;
        if (index < 0 || BloomName(index).Length == 0) return v;
        v = BloomName(index);
        return v;
    }

    // Read-only wrapper read. A wrapper someone else loaded is read as it is
    // (it may hold their unsaved edits, so it is reported, never applied); a
    // wrapper this tool loads is unloaded straight after.
    int DisplayReadWrapper(DisplayHost@ host, bool &out busy) {
        busy = false;
        if (!host.ScriptApiAvailable()) return -1;
        if (host.WrapperLoadedByOther()) {
            busy = true;
            return host.WrapperRead();
        }
        string err;
        if (!host.WrapperLoad(err)) return -1;
        int v = -1;
        try { v = host.WrapperRead(); } catch { v = -1; }
        host.WrapperUnload();
        return v;
    }

    // Every source as read now.
    class BloomSources {
        int wrapper = -1;
        int systemConfig = -1;
        bool wrapperBusy = false;

        array<string> Names() {
            array<string> a;
            a.InsertLast(BloomName(wrapper));
            a.InsertLast(BloomName(systemConfig));
            return a;
        }
        // The value reported as "the" setting: the live one first.
        int Current() { return systemConfig >= 0 ? systemConfig : wrapper; }
        uint Readable() { return (wrapper >= 0 ? 1 : 0) + (systemConfig >= 0 ? 1 : 0); }
        bool AllAre(int index) {
            return Readable() > 0 && (wrapper < 0 || wrapper == index) && (systemConfig < 0 || systemConfig == index);
        }
        Json::Value@ ToJson() {
            Json::Value o = Json::Object();
            o["wrapper"] = _BloomJson(wrapper);
            o["systemConfig"] = _BloomJson(systemConfig);
            if (wrapperBusy) o["wrapperLoadedByOther"] = true;
            return o;
        }
    }

    BloomSources@ DisplayReadSources(DisplayHost@ host) {
        auto s = BloomSources();
        s.wrapper = DisplayReadWrapper(host, s.wrapperBusy);
        s.systemConfig = host.ReadSystemConfig();
        return s;
    }

    // --- The record on disk ------------------------------------------------------

    // A record (or a checked side file left by a crash mid-replace) exists.
    bool DisplayRecordPresent(DisplayHost@ host) {
        return host.FileExists(DISPLAY_RESTORE_FILE) || host.FileExists(DISPLAY_RESTORE_NEXT_FILE);
    }

    // "missing" | "valid" | "invalid" (reason says why).
    // adopt=false (GetDisplaySetting) reports a checked side file without moving it.
    string DisplayLoadRecord(DisplayHost@ host, DisplayRecord@ &out rec, string &out reason, bool adopt = true) {
        @rec = null;
        reason = "";
        string text, err;
        if (!host.FileExists(DISPLAY_RESTORE_FILE)) {
            // DisplayStoreRecord replaces a record by delete + move. A crash
            // between the two leaves only the side file, which was read back
            // and checked before the delete: adopt it so recovery is not lost.
            // A side file that does not validate was never committed (the
            // bloom write only follows a commit): ignore it.
            if (!host.FileExists(DISPLAY_RESTORE_NEXT_FILE)) return "missing";
            if (!host.FileRead(DISPLAY_RESTORE_NEXT_FILE, text, err)) return "missing";
            string why;
            auto side = ParseDisplayRecord(text, why);
            if (side is null) return "missing";
            if (adopt && !host.FileMove(DISPLAY_RESTORE_NEXT_FILE, DISPLAY_RESTORE_FILE, err)) {
                host.Log("TM Control MCP: could not adopt " + DISPLAY_RESTORE_NEXT_FILE + ": " + err);
            }
            @rec = side;
            return "valid";
        }
        if (!host.FileRead(DISPLAY_RESTORE_FILE, text, err)) { reason = "unreadable: " + err; return "invalid"; }
        @rec = ParseDisplayRecord(text, reason);
        return rec is null ? "invalid" : "valid";
    }

    // Delete the record and any side file. false + err if either remains.
    bool DisplayDeleteRecord(DisplayHost@ host, string &out err) {
        err = "";
        bool ok = true;
        string e1, e2;
        if (host.FileExists(DISPLAY_RESTORE_NEXT_FILE) && !host.FileDelete(DISPLAY_RESTORE_NEXT_FILE, e1)) ok = false;
        if (host.FileExists(DISPLAY_RESTORE_FILE) && !host.FileDelete(DISPLAY_RESTORE_FILE, e2)) ok = false;
        if (!ok) err = e1 + (e1.Length > 0 && e2.Length > 0 ? "; " : "") + e2;
        return ok;
    }

    // Write `rec` so that, on success, the file on disk parses back to it
    // exactly. It goes to the side file first and is checked there, so a
    // failed write never leaves a half record where restore looks; on any
    // failure the side file is removed again.
    bool DisplayStoreRecord(DisplayHost@ host, DisplayRecord@ rec, string &out err) {
        err = "";
        string text = DisplayRecordText(rec);
        string back, why, ignored;
        bool ok = host.FileWrite(DISPLAY_RESTORE_NEXT_FILE, text, err);
        if (ok && !host.FileRead(DISPLAY_RESTORE_NEXT_FILE, back, err)) { err = "read-back failed: " + err; ok = false; }
        if (ok && !DisplayRecordsEqual(ParseDisplayRecord(back, why), rec)) { err = "read-back did not match (" + why + ")"; ok = false; }
        if (ok && host.FileExists(DISPLAY_RESTORE_FILE) && !host.FileDelete(DISPLAY_RESTORE_FILE, err)) {
            err = "could not replace the record: " + err;
            ok = false;
        }
        if (!ok) {
            host.FileDelete(DISPLAY_RESTORE_NEXT_FILE, ignored);
            return false;
        }
        // From here the checked side file is the record (DisplayLoadRecord
        // adopts it if the move does not happen).
        if (!host.FileMove(DISPLAY_RESTORE_NEXT_FILE, DISPLAY_RESTORE_FILE, err)) return false;
        if (!host.FileRead(DISPLAY_RESTORE_FILE, back, err)) { err = "final read-back failed: " + err; return false; }
        if (!DisplayRecordsEqual(ParseDisplayRecord(back, why), rec)) { err = "final read-back did not match (" + why + ")"; return false; }
        return true;
    }

    Json::Value@ DisplayRecordJson(DisplayHost@ host, const string &in state, DisplayRecord@ rec,
                                   const string &in reason, const string &in identity) {
        Json::Value r = Json::Object();
        r["state"] = state;
        r["path"] = host.FilePath(DISPLAY_RESTORE_FILE);
        if (state == "invalid") r["invalidReason"] = reason;
        if (rec !is null) {
            r["prior"] = rec.prior;
            Json::Value a = Json::Array();
            for (uint i = 0; i < rec.applied.Length; i++) a.Add(rec.applied[i]);
            r["applied"] = a;
            r["setAt"] = rec.setAt;
            r["identityMatches"] = identity.Length > 0 && rec.identity == identity;
        }
        return r;
    }

    // --- Writes ---------------------------------------------------------------------

    // Wrapper (only one this tool loads) first, systemConfig fallback; a
    // wrapper loaded by someone else is never applied (F3).
    bool DisplayApplyBloom(DisplayHost@ host, int index, string &out mechanism, Json::Value &inout output,
                           bool canYield) {
        Json::Value attempts = Json::Array();
        bool available = host.ScriptApiAvailable();
        bool busy = available && host.WrapperLoadedByOther();
        bool failed = false;
        BloomSources@ after = null;
        if (ChooseBloomMechanism(available, busy, false) == "wrapper") {
            Json::Value a = Json::Object();
            a["mechanism"] = "wrapper";
            string err;
            bool wrote = false;
            if (host.WrapperLoad(err)) {
                try {
                    wrote = host.WrapperWriteApply(index, err);
                } catch {
                    err = "wrapper write threw";
                    wrote = false;
                }
                host.WrapperUnload(); // every path, errors included
            }
            a["wrote"] = wrote;
            if (err.Length > 0) a["error"] = err;
            if (canYield) host.Yield(); // let the apply land before reading back
            @after = DisplayReadSources(host);
            a["verified"] = wrote && after.AllAre(index);
            attempts.Add(a);
            failed = !bool(a["verified"]);
        }
        mechanism = ChooseBloomMechanism(available, busy, failed);
        if (mechanism == "systemConfig") {
            Json::Value a = Json::Object();
            a["mechanism"] = "systemConfig";
            if (busy) a["why"] = "the DisplaySettings wrapper is loaded by someone else; it is never applied by this tool";
            string err;
            bool wrote = host.WriteSystemConfig(index, err);
            a["wrote"] = wrote;
            if (err.Length > 0) a["error"] = err;
            if (canYield) host.Yield();
            @after = DisplayReadSources(host);
            // A busy wrapper still holds its own copy: every readable source
            // must agree before this counts (F4).
            a["verified"] = wrote && after.AllAre(index);
            attempts.Add(a);
        }
        output["attempts"] = attempts;
        output["sources"] = after.ToJson();
        return bool(attempts[attempts.Length - 1]["verified"]);
    }

    // --- Tools ------------------------------------------------------------------------

    Json::Value@ GetDisplaySettingCore(DisplayHost@ host) {
        Json::Value o = Json::Object();
        auto src = DisplayReadSources(host);
        o["sources"] = src.ToJson();
        o["bloom"] = _BloomJson(src.Current());
        o["sourcesAgree"] = src.wrapper < 0 || src.systemConfig < 0 || src.wrapper == src.systemConfig;
        o["isSafeMode"] = host.SafeMode();
        o["install"] = host.IdentityJson();
        string identity = host.InstallIdentity();
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason, false);
        if (state == "missing") {
            o["pendingRestore"] = Json::Value();
        } else {
            auto r = DisplayRecordJson(host, state, rec, reason, identity);
            if (rec !is null) {
                string d = RestoreDecision(identity.Length > 0 && rec.identity == identity, src.Names(), rec.prior, rec.applied, false);
                r["restoreWouldDo"] = d;
                if (d.StartsWith("conflict")) {
                    r["conflict"] = d == "conflict-identity"
                        ? "written on another install or profile; it is never applied automatically here"
                        : "the setting was changed by someone else since; it is never overwritten automatically";
                }
            }
            o["pendingRestore"] = r;
        }
        o["note"] = "Display settings are saved to the user's config. After SetDisplaySetting always call RestoreDisplaySetting.";
        return MakeSuccess(o);
    }

    Json::Value@ _DisplayErr(const string &in message, const string &in code, bool retryable, const string &in hint,
                             Json::Value &in output) {
        auto err = MakeError(message, code, retryable, "", hint);
        err["output"] = output;
        return err;
    }

    Json::Value@ SetDisplaySettingCore(DisplayHost@ host, Json::Value &in input) {
        if (!input.HasKey("bloom") || input["bloom"].GetType() != Json::Type::String) {
            return MakeError("bloom is required: none, medium or high", "INVALID_INPUT");
        }
        string wanted = NormalizeBloom(string(input["bloom"]));
        if (wanted.Length == 0) return MakeError("bloom must be none, medium or high", "INVALID_INPUT");
        int index = BloomIndex(wanted);

        Json::Value output = Json::Object();
        output["requested"] = wanted;
        // F3: someone else's wrapper (possibly with unsaved edits) is never
        // applied, and nothing is written while it is loaded.
        if (host.ScriptApiAvailable() && host.WrapperLoadedByOther()) {
            output["changed"] = false;
            return _DisplayErr("the game's DisplaySettings are loaded by someone else (the settings page or another"
                + " plugin); nothing was written", "WRAPPER_BUSY", true,
                "Close the graphics settings page, then call SetDisplaySetting again.", output);
        }
        auto src = DisplayReadSources(host);
        int current = src.Current();
        output["sources"] = src.ToJson();
        if (current < 0) {
            output["changed"] = false;
            return _DisplayErr("no display config available (no viewport / script API)", "NOT_AVAILABLE", true, "", output);
        }
        string currentName = BloomName(current);
        output["prior"] = currentName;
        string identity = host.InstallIdentity();
        if (identity.Length == 0) {
            output["changed"] = false;
            return _DisplayErr("the install identity could not be read, so a restore record could not be bound to"
                + " this install; nothing was written", "RESTORE_RECORD_FAILED", true, "", output);
        }

        // F1: read and validate any record BEFORE any write.
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason);
        if (state == "invalid") {
            output["changed"] = false;
            output["restoreRecord"] = DisplayRecordJson(host, state, null, reason, identity);
            return _DisplayErr("the existing restore record is invalid (" + reason + "); nothing was changed so the"
                + " original value is not lost", "RESTORE_RECORD_INVALID", false,
                "A person should inspect " + host.FilePath(DISPLAY_RESTORE_FILE) + " and fix or delete it.", output);
        }
        if (state == "valid") {
            string conflict = SetRecordConflict(rec.identity == identity, currentName, rec.prior, rec.applied);
            if (conflict.Length > 0) {
                output["changed"] = false;
                output["restoreRecord"] = DisplayRecordJson(host, state, rec, "", identity);
                return _DisplayErr(conflict == "identity"
                    ? "a restore record from another install or profile is pending here; nothing was changed"
                    : "bloom was changed by someone else since the pending record was written (" + currentName
                        + " is not a value this tool set); nothing was changed",
                    "RESTORE_CONFLICT", false,
                    "GetDisplaySetting shows the record; RestoreDisplaySetting {force:true} applies it anyway.", output);
            }
        }

        if (current == index && state == "missing") {
            output["now"] = wanted;
            output["changed"] = false;
            output["mechanism"] = "none";
            output["restoreRecord"] = "none needed";
            return MakeSuccess(output);
        }

        // Keep the oldest prior; add this value to the applied list.
        auto next = DisplayRecord();
        if (rec !is null) {
            next.prior = rec.prior;
            next.applied = rec.applied;
            next.identity = rec.identity;
            next.setAt = rec.setAt;
        } else {
            next.prior = currentName;
            next.identity = identity;
            next.setAt = host.Now();
        }
        if (next.applied.Find(wanted) < 0) next.applied.InsertLast(wanted);
        if (rec is null || !DisplayRecordsEqual(rec, next)) {
            string err;
            if (!DisplayStoreRecord(host, next, err)) {
                output["changed"] = false;
                return _DisplayErr("could not write the restore record (" + err + "); nothing was changed",
                    "RESTORE_RECORD_FAILED", true, "", output);
            }
            output["restoreRecord"] = rec is null ? "written" : "updated";
        } else {
            output["restoreRecord"] = "kept";
        }
        output["restoreTo"] = next.prior;

        if (current == index) {
            output["now"] = wanted;
            output["changed"] = false;
            output["mechanism"] = "none";
            output["restoreWith"] = "RestoreDisplaySetting";
            return MakeSuccess(output);
        }

        auto watchBefore = host.WrapperWatch();
        string mechanism;
        bool ok = DisplayApplyBloom(host, index, mechanism, output, true);
        auto watchAfter = host.WrapperWatch();
        output["mechanism"] = mechanism;
        output["displayBefore"] = _DisplayWatchJson(watchBefore);
        output["displayAfter"] = _DisplayWatchJson(watchAfter);
        output["sideEffects"] = (watchBefore.ok && watchAfter.ok)
            ? DisplaySideEffects(watchBefore.dirty, watchAfter.dirty, watchBefore.mode, watchAfter.mode,
                                 watchBefore.winX, watchBefore.winY, watchAfter.winX, watchAfter.winY)
            : "unknown";
        output["persisted"] = "assumed";
        output["restoreWith"] = "RestoreDisplaySetting";
        int nowIdx = host.ReadSystemConfig();
        output["now"] = _BloomJson(nowIdx);
        output["changed"] = nowIdx >= 0 && nowIdx != current;
        output["runtimeEffect"] = "UNPROVEN: whether the renderer drops bloom immediately is not verified; compare screenshots.";
        if (!ok) {
            return _DisplayErr("bloom write did not read back as " + wanted + " from every source",
                "APPLY_UNVERIFIED", true, "The restore record is kept: RestoreDisplaySetting still puts the prior value back.", output);
        }
        return MakeSuccess(output);
    }

    Json::Value@ _DisplayWatchJson(DisplayWatch@ w) {
        Json::Value o = Json::Object();
        o["available"] = w !is null && w.ok;
        if (w !is null && w.ok) {
            o["dirtyCounter"] = double(w.dirty);
            o["displayMode"] = w.mode;
            Json::Value ws = Json::Array();
            ws.Add(w.winX);
            ws.Add(w.winY);
            o["windowSize"] = ws;
        }
        return o;
    }

    // Shared by the tool and by plugin start / disable / unload.
    // canYield=false for OnDisabled/OnDestroyed: callbacks, not coroutines.
    // force only from an explicit RestoreDisplaySetting {force:true}.
    // output.action: none | invalid | unavailable | conflict-identity |
    // conflict-value | clear | apply; restored says whether it is done.
    Json::Value@ RestoreDisplaySettingCore(DisplayHost@ host, bool canYield, bool force) {
        Json::Value output = Json::Object();
        string identity = host.InstallIdentity();
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason);
        output["record"] = state == "missing" ? Json::Value() : DisplayRecordJson(host, state, rec, reason, identity);
        if (state == "missing") {
            output["action"] = "none";
            output["restored"] = false;
            output["reason"] = "no record";
            return output;
        }
        if (state == "invalid") {
            output["action"] = "invalid";
            output["restored"] = false;
            output["reason"] = "the restore record is invalid (" + reason + "); kept for a person to inspect: "
                + host.FilePath(DISPLAY_RESTORE_FILE);
            return output;
        }
        output["prior"] = rec.prior;
        output["setAt"] = rec.setAt;
        auto src = DisplayReadSources(host);
        output["sourcesBefore"] = src.ToJson();
        string action = RestoreDecision(identity.Length > 0 && rec.identity == identity, src.Names(), rec.prior, rec.applied, force);
        output["action"] = action;
        output["forced"] = force;
        if (action == "unavailable") {
            output["restored"] = false;
            output["reason"] = "no display config available yet; record kept";
            return output;
        }
        if (action == "conflict-identity") {
            output["restored"] = false;
            output["reason"] = "the record was written on another install or profile; nothing applied, record kept."
                + " RestoreDisplaySetting {force:true} applies it here anyway.";
            return output;
        }
        if (action == "conflict-value") {
            output["restored"] = false;
            output["reason"] = "bloom was changed by someone else since the tool set it (" + BloomName(src.Current())
                + "); nothing overwritten, record kept. RestoreDisplaySetting {force:true} applies the prior anyway.";
            return output;
        }
        if (action == "clear") {
            // F4: every readable source already reads the prior.
            string err;
            if (!DisplayDeleteRecord(host, err)) {
                output["restored"] = false;
                output["reason"] = "the setting is back but the record could not be deleted: " + err;
                return output;
            }
            output["restored"] = true;
            output["changed"] = false;
            output["now"] = rec.prior;
            return output;
        }
        string mechanism;
        bool ok = DisplayApplyBloom(host, BloomIndex(rec.prior), mechanism, output, canYield);
        output["mechanism"] = mechanism;
        auto after = DisplayReadSources(host);
        output["sources"] = after.ToJson();
        output["now"] = _BloomJson(after.Current());
        // F4: the record goes only when every readable source has the prior.
        bool allBack = after.AllAre(BloomIndex(rec.prior));
        output["changed"] = ok || allBack;
        if (ok && allBack) {
            string err;
            if (!DisplayDeleteRecord(host, err)) {
                output["restored"] = false;
                output["reason"] = "the setting is back but the record could not be deleted: " + err;
                return output;
            }
            output["restored"] = true;
            return output;
        }
        output["restored"] = false;
        output["reason"] = after.wrapperBusy
            ? "the live setting may be back, but the DisplaySettings wrapper someone else loaded still holds another"
              + " value (their Apply could save it); record kept. Close the settings page and restore again."
            : "write did not read back from every source; record kept";
        return output;
    }

    Json::Value@ RestoreDisplaySettingTool(DisplayHost@ host, Json::Value &in input) {
        bool force = input.HasKey("force") && input["force"].GetType() == Json::Type::Boolean && bool(input["force"]);
        auto o = RestoreDisplaySettingCore(host, true, force);
        string action = string(o["action"]);
        if (action != "none" && !bool(o["restored"])) {
            string code = action == "invalid" ? "RESTORE_RECORD_INVALID"
                : (action.StartsWith("conflict") ? "RESTORE_CONFLICT" : "RESTORE_FAILED");
            auto err = MakeError("restore did not complete: " + string(o["reason"]), code, code == "RESTORE_FAILED");
            err["output"] = o;
            return err;
        }
        return MakeSuccess(o);
    }

    // Plugin lifecycle: never leave the user's bloom changed by this tool, and
    // never overwrite a value it did not set (no force here).
    Json::Value@ RestoreDisplaySettingOnLifecycleCore(DisplayHost@ host, const string &in when) {
        if (!DisplayRecordPresent(host)) return null;
        auto o = RestoreDisplaySettingCore(host, when == "start", false);
        host.Log("TM Control MCP: display restore on " + when + ": " + string(o["action"])
            + (bool(o["restored"]) ? " (restored)" : " (record kept)"));
        return o;
    }
}
