namespace TmMcp {
    // Get/Set/RestoreDisplaySetting orchestration with no game types: every
    // setting read/write, wrapper call and file operation goes through
    // DisplayHost. src/DisplaySettingsTools.as is the live host;
    // tests/test_display_settings_tools.py runs this file in stock
    // AngelScript against a fake game and a fake disk.
    //
    // Two places hold bloom, both enum None/Medium/High (index 0/1/2):
    //   wrapper       app.ManiaPlanetScriptAPI.DisplaySettings, after
    //                 DisplaySettings_LoadCurrent(); written with
    //                 DisplaySettings_Apply(), released with _Unload(). The
    //                 script API the game's settings page is built on.
    //   systemConfig  Viewport.SystemConfig.Display (DisplaySafe in safe mode).
    //
    // The agent stays in control: SetDisplaySetting records the prior and
    // writes; RestoreDisplaySetting, called by the agent, puts it back.
    // Nothing restores on its own (not on plugin start, disable or unload).
    //
    //  - One record slot (bloom-restore.txt), never overwritten: while any
    //    record exists, valid or not, Set refuses and changes nothing.
    //  - Set, Restore and Get each run as ONE section with no yield, under a
    //    module-level busy flag they share, so no other call can run between
    //    reading the record, writing it and writing bloom.
    //  - Set order: no record; read the prior from every source (they must
    //    agree); write the record and read it back exactly; write bloom by
    //    one mechanism chosen up front; read every source back.
    //  - A wrapper someone else loaded is never applied; Set refuses
    //    WRAPPER_BUSY. A wrapper this tool loads is released on every path,
    //    and the tool keeps its claim on it until the release is confirmed.
    //
    // UNPROVEN live (2026-11-18): that None removes bloom at once with no
    // restart (Q2), or whether Apply resets the window/device, lands later,
    // or saves Default.json (Q3). Persistence is therefore "assumed".

    class DisplayWatch {
        bool ok = false;
        uint dirty = 0;
        int mode = -1;
        int winX = 0;
        int winY = 0;
    }

    interface DisplayHost {
        // Never called by Set, Restore or Get: each is one non-yielding
        // section. Declared so a test fake can prove that (a reentry hook
        // fires here if a yield is ever added).
        void Yield();
        string Now();                       // setAt text
        // false + why when it cannot be established (Set then refuses).
        bool InstallIdentity(string &out identity, string &out why);
        Json::Value@ IdentityJson();        // what the identity is made of (no raw paths)
        bool SafeMode();
        // -1 when unavailable.
        int ReadSystemConfig();
        bool WriteSystemConfig(int index, string &out err);
        bool ScriptApiAvailable();
        // DISPLAY_WRAPPER_NONE / _OURS / _OTHER (DisplayWrapperOwner).
        int WrapperOwner();
        // Load a wrapper (only when none is loaded). After a true or false
        // return the caller always calls WrapperRelease.
        bool WrapperLoad(string &out err);
        // The loaded wrapper's bloom (ours or someone else's), -1 if unreadable.
        int WrapperRead();
        // Set bloom on the wrapper THIS tool loaded and Apply it.
        bool WrapperWriteApply(int index, string &out err);
        // Release the wrapper this tool loaded. true only once it is seen
        // gone; otherwise the claim is kept and the next call retries.
        bool WrapperRelease(string &out err);
        // DirtyCounter / DisplayMode / WindowSize of the wrapper this tool has loaded.
        DisplayWatch@ WrapperWatch();
        bool FileExists(const string &in name);
        bool FileRead(const string &in name, string &out text, string &out err);
        // Write, Flush and Close.
        bool FileWrite(const string &in name, const string &in text, string &out err);
        bool FileDelete(const string &in name, string &out err);
        string FilePath(const string &in name);
        void Log(const string &in message);
    }

    // Shared by Set, Restore and Get. They never yield, so in the game this
    // only matters if that ever changes; the tests reenter through the host.
    bool g_displayBusy = false;

    // null for an unreadable source, else "none"|"medium"|"high".
    Json::Value _BloomJson(int index) {
        Json::Value v;
        if (BloomName(index).Length == 0) return v;
        v = BloomName(index);
        return v;
    }

    string _WrapperOwnerName(int owner) {
        if (owner == DISPLAY_WRAPPER_OURS) return "tool (release not confirmed)";
        if (owner == DISPLAY_WRAPPER_OTHER) return "other";
        return "none";
    }

    // Every source as read now, in one non-yielding pass.
    class BloomSources {
        bool apiAvailable = false;
        int owner = DISPLAY_WRAPPER_NONE;
        int wrapper = -1;
        int systemConfig = -1;
        // A wrapper exists that might hold another value but could not be
        // read: someone else's that does not read, or this tool's own whose
        // release is not confirmed (its copy is stale).
        bool wrapperUnreadableKnown = false;
        bool releasePending = false;
        // This tool loaded a wrapper, read it and released it with no yield:
        // the wrapper path is usable in this call.
        bool wrapperLoaded = false;
        string wrapperError = "";
        DisplayWatch@ watch = null;

        uint Readable() { return (wrapper >= 0 ? 1 : 0) + (systemConfig >= 0 ? 1 : 0); }
        bool AllAre(int index) {
            return index >= 0 && Readable() > 0 && !wrapperUnreadableKnown
                && (wrapper < 0 || wrapper == index) && (systemConfig < 0 || systemConfig == index);
        }
        bool Agree() { return wrapper < 0 || systemConfig < 0 || wrapper == systemConfig; }
        // The value reported as "the" setting: the live one first.
        int Current() { return systemConfig >= 0 ? systemConfig : wrapper; }
        Json::Value@ ToJson() {
            Json::Value o = Json::Object();
            o["wrapper"] = _BloomJson(wrapper);
            o["systemConfig"] = _BloomJson(systemConfig);
            o["wrapperLoadedBy"] = _WrapperOwnerName(owner);
            if (wrapperUnreadableKnown) o["wrapperUnreadable"] = true;
            if (releasePending) o["wrapperReleasePending"] = true;
            if (wrapperError.Length > 0) o["wrapperError"] = wrapperError;
            return o;
        }
    }

    BloomSources@ DisplayReadSources(DisplayHost@ host) {
        auto s = BloomSources();
        s.apiAvailable = host.ScriptApiAvailable();
        s.owner = s.apiAvailable ? host.WrapperOwner() : DISPLAY_WRAPPER_NONE;
        if (s.owner == DISPLAY_WRAPPER_OTHER) {
            // Someone else's (maybe edited) wrapper: read as it is, never applied.
            s.wrapper = host.WrapperRead();
            s.wrapperUnreadableKnown = s.wrapper < 0;
        } else if (s.owner == DISPLAY_WRAPPER_OURS) {
            // This tool's own wrapper from a release that did not complete.
            s.wrapperUnreadableKnown = true;
            s.releasePending = true;
        } else if (s.apiAvailable) {
            string err;
            bool loaded = host.WrapperLoad(err);
            if (loaded) {
                s.wrapper = host.WrapperRead();
                s.wrapperUnreadableKnown = s.wrapper < 0;
                @s.watch = host.WrapperWatch();
            } else {
                s.wrapperError = err;
            }
            string rerr;
            if (!host.WrapperRelease(rerr)) {
                s.releasePending = true;
                s.wrapperUnreadableKnown = true;
                s.wrapperError = "release not confirmed: " + rerr;
            } else {
                s.wrapperLoaded = loaded && s.wrapper >= 0;
            }
        }
        s.systemConfig = host.ReadSystemConfig();
        return s;
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

    // --- Records on disk -----------------------------------------------------------

    // "missing" | "valid" | "invalid" (reason says why).
    string DisplayLoadRecord(DisplayHost@ host, DisplayRecord@ &out rec, string &out reason) {
        @rec = null;
        reason = "";
        if (!host.FileExists(DISPLAY_RESTORE_FILE)) return "missing";
        string text, err;
        if (!host.FileRead(DISPLAY_RESTORE_FILE, text, err)) { reason = "unreadable: " + err; return "invalid"; }
        @rec = ParseDisplayRecord(text, reason);
        return rec is null ? "invalid" : "valid";
    }

    // Older builds' record files, reported and never applied. null if none.
    Json::Value@ DisplayLegacyJson(DisplayHost@ host) {
        auto names = DisplayLegacyRecordFiles();
        Json::Value o = Json::Object();
        Json::Value others = Json::Array();
        bool found = false;
        for (uint i = 0; i < names.Length; i++) {
            if (!host.FileExists(names[i])) continue;
            if (found) { others.Add(host.FilePath(names[i])); continue; }
            found = true;
            o["path"] = host.FilePath(names[i]);
            string text, err;
            if (host.FileRead(names[i], text, err)) {
                string bloom = LegacyRecordBloom(names[i], text);
                if (bloom.Length > 0) o["bloom"] = bloom;
            } else {
                o["unreadable"] = err;
            }
        }
        if (!found) return null;
        if (others.Length > 0) o["alsoPresent"] = others;
        o["note"] = "Written by an older build. Never applied or migrated. To recover by hand: check which"
            + " instance it came from, keep a copy, set bloom in Settings > Graphics if this value is the one to"
            + " restore, then delete the file. SetDisplaySetting refuses until it is gone.";
        return o;
    }

    // The record belongs here: same install identity (known) and the same
    // display config (Display / DisplaySafe) as is in effect now.
    bool DisplayRecordMatches(DisplayHost@ host, DisplayRecord@ rec, bool identityKnown, const string &in identity) {
        return rec !is null && identityKnown && rec.identity == identity
            && rec.config == DisplayConfigName(host.SafeMode());
    }

    Json::Value@ DisplayRecordJson(DisplayHost@ host, const string &in state, DisplayRecord@ rec,
                                   const string &in reason, bool identityKnown, const string &in identity) {
        Json::Value r = Json::Object();
        r["state"] = state;
        r["path"] = host.FilePath(DISPLAY_RESTORE_FILE);
        if (state == "invalid") r["invalidReason"] = reason;
        if (rec !is null) {
            r["prior"] = rec.prior;
            r["target"] = rec.target;
            r["config"] = rec.config;
            r["setAt"] = rec.setAt;
            r["identityMatches"] = identityKnown && rec.identity == identity;
            r["configMatches"] = rec.config == DisplayConfigName(host.SafeMode());
        }
        return r;
    }

    // Write the record, then read it back: it must parse to exactly `rec`.
    // On any failure the file is deleted again (if that fails too, the
    // leftover never parses as this record, so Set keeps refusing).
    bool DisplayStoreRecord(DisplayHost@ host, DisplayRecord@ rec, string &out err) {
        err = "";
        string back, why, ignored;
        bool ok = host.FileWrite(DISPLAY_RESTORE_FILE, DisplayRecordText(rec), err);
        if (ok && !host.FileRead(DISPLAY_RESTORE_FILE, back, err)) { err = "read-back failed: " + err; ok = false; }
        if (ok && !DisplayRecordsEqual(ParseDisplayRecord(back, why), rec)) {
            err = "read-back did not match (" + why + ")";
            ok = false;
        }
        if (!ok && host.FileExists(DISPLAY_RESTORE_FILE) && !host.FileDelete(DISPLAY_RESTORE_FILE, ignored)) {
            err += "; the bad record could not be deleted (" + ignored + ")";
        }
        return ok;
    }

    // --- Writes ---------------------------------------------------------------------

    // One write by the mechanism chosen up front. No yield, no fallback.
    bool DisplayWriteBloom(DisplayHost@ host, const string &in mechanism, int index, string &out err,
                           bool &out releasePending) {
        err = "";
        releasePending = false;
        if (BloomName(index).Length == 0) { err = "not a bloom index: " + index; return false; }
        if (mechanism != "wrapper") return host.WriteSystemConfig(index, err);
        bool ok = false;
        if (host.WrapperLoad(err)) {
            try {
                ok = host.WrapperWriteApply(index, err);
            } catch {
                err = "wrapper write threw: " + getExceptionInfo();
                ok = false;
            }
        }
        string rerr;
        if (!host.WrapperRelease(rerr)) {
            releasePending = true;
            err += (err.Length > 0 ? "; " : "") + "wrapper release not confirmed: " + rerr;
        }
        return ok;
    }

    Json::Value@ _DisplayErr(const string &in message, const string &in code, bool retryable, const string &in hint,
                             Json::Value &in output) {
        auto err = MakeError(message, code, retryable, "", hint);
        err["output"] = output;
        return err;
    }

    Json::Value@ _DisplayBusy(const string &in tool) {
        return MakeError(tool + " refused: another display-setting call is running; nothing was done",
            "DISPLAY_BUSY", true, "", "Call it again.");
    }

    // A claim on this tool's own wrapper left by an earlier call: release it
    // now or fail closed. "" = no wrapper is loaded by anyone.
    string _DisplayWrapperGate(DisplayHost@ host) {
        if (!host.ScriptApiAvailable()) return "";
        int owner = host.WrapperOwner();
        if (owner == DISPLAY_WRAPPER_OURS) {
            string err;
            if (!host.WrapperRelease(err)) return "the DisplaySettings wrapper this tool loaded earlier could not be released (" + err + ")";
            owner = host.WrapperOwner();
        }
        if (owner == DISPLAY_WRAPPER_OTHER) return "the game's DisplaySettings are loaded by someone else (the settings page or another plugin)";
        if (owner == DISPLAY_WRAPPER_OURS) return "the DisplaySettings wrapper this tool loaded is still loaded";
        return "";
    }

    // --- Tools ------------------------------------------------------------------------

    Json::Value@ GetDisplaySettingCore(DisplayHost@ host) {
        if (g_displayBusy) return _DisplayBusy("GetDisplaySetting");
        g_displayBusy = true;
        Json::Value@ r;
        string bodyError;
        try {
            @r = _DisplayGet(host);
        } catch {
            bodyError = getExceptionInfo();
        }
        return _DisplayCompleteCall(host, r, "GetDisplaySetting", bodyError);
    }

    Json::Value@ _DisplayGet(DisplayHost@ host) {
        Json::Value o = Json::Object();
        auto src = DisplayReadSources(host);
        o["sources"] = src.ToJson();
        o["bloom"] = _BloomJson(src.Current());
        o["sourcesAgree"] = src.Agree();
        bool safe = host.SafeMode();
        o["isSafeMode"] = safe;
        o["config"] = DisplayConfigName(safe);
        o["install"] = host.IdentityJson();
        string identity, why;
        bool known = host.InstallIdentity(identity, why);
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason);
        if (state == "missing") {
            o["restoreRecord"] = Json::Value();
        } else {
            auto r = DisplayRecordJson(host, state, rec, reason, known, identity);
            if (rec !is null) {
                if (!DisplayRecordMatches(host, rec, known, identity)) {
                    r["restoreWouldDo"] = "conflict";
                    r["conflict"] = known ? "written on another install, profile or display config"
                                          : "this install's identity is unknown (" + why + ")";
                } else {
                    r["restoreWouldDo"] = RestoreDecision(src.Readable(), src.AllAre(BloomIndex(rec.prior)),
                        src.AllAre(BloomIndex(rec.target)), src.wrapperUnreadableKnown, false);
                }
            }
            o["restoreRecord"] = r;
        }
        auto legacy = DisplayLegacyJson(host);
        if (legacy is null) o["legacyRecord"] = Json::Value();
        else o["legacyRecord"] = legacy;
        o["note"] = "Bloom persistence to the user's config is assumed, not verified. After SetDisplaySetting call"
            + " RestoreDisplaySetting; it keeps the record until explicit retirement.";
        return MakeSuccess(o);
    }

    Json::Value@ SetDisplaySettingCore(DisplayHost@ host, Json::Value &in input) {
        if (g_displayBusy) return _DisplayBusy("SetDisplaySetting");
        g_displayBusy = true;
        Json::Value@ r;
        string bodyError;
        try {
            @r = _DisplaySet(host, input);
        } catch {
            bodyError = getExceptionInfo();
        }
        return _DisplayCompleteCall(host, r, "SetDisplaySetting", bodyError);
    }

    // Finally-equivalent exit: hold the lock through the release attempt, then
    // clear it before constructing fallback results or logging. A release
    // that threw has not proved the wrapper gone and must not drop the claim.
    Json::Value@ _DisplayCompleteCall(DisplayHost@ host, Json::Value@ r, const string &in tool,
                                      const string &in bodyError) {
        string releaseError;
        bool released = false;
        try {
            released = !host.ScriptApiAvailable() || host.WrapperRelease(releaseError);
        } catch {
            releaseError = getExceptionInfo();
        }
        g_displayBusy = false;

        if (r is null) @r = MakeError(tool + " threw: " + bodyError, "tool_exception", true);
        if (!released) {
            if (!r.HasKey("output")) r["output"] = Json::Object();
            r["output"]["wrapperReleasePending"] = true;
            try { host.Log("TM Control MCP: DisplaySettings wrapper release not confirmed: " + releaseError); } catch {}
        }
        return r;
    }

    Json::Value@ _DisplaySet(DisplayHost@ host, Json::Value &in input) {
        if (!input.HasKey("bloom") || input["bloom"].GetType() != Json::Type::String) {
            return MakeError("bloom is required: none, medium or high", "INVALID_INPUT");
        }
        string wanted = string(input["bloom"]);
        int index = BloomIndex(wanted);
        if (index < 0) return MakeError("bloom must be exactly none, medium or high", "INVALID_INPUT");

        Json::Value output = Json::Object();
        output["requested"] = wanted;
        output["changed"] = false;

        // (1) No record of any kind, and nothing else holding the wrapper.
        auto legacy = DisplayLegacyJson(host);
        if (legacy !is null) {
            output["legacyRecord"] = legacy;
            return _DisplayErr("a restore record from an older build is present; nothing was changed",
                "LEGACY_RECORD_PRESENT", false, string(legacy["note"]), output);
        }
        string identity, why;
        bool known = host.InstallIdentity(identity, why);
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason);
        if (state != "missing") {
            output["restoreRecord"] = DisplayRecordJson(host, state, rec, reason, known, identity);
            if (state == "invalid") {
                return _DisplayErr("the restore record is invalid (" + reason + "); nothing was changed", "RESTORE_RECORD_INVALID",
                    false, "A person should inspect " + host.FilePath(DISPLAY_RESTORE_FILE) + "; see GetDisplaySetting.", output);
            }
            if (!DisplayRecordMatches(host, rec, known, identity)) {
                return _DisplayErr("a restore record from another install, profile or display config is pending here;"
                    + " nothing was changed", "RESTORE_CONFLICT", false,
                    "GetDisplaySetting shows it; it is never applied here automatically.", output);
            }
            return _DisplayErr("a restore is pending (prior " + rec.prior + ", set " + rec.target + " at " + rec.setAt
                + "); nothing was changed", "RESTORE_PENDING", false,
                "Call RestoreDisplaySetting, then retire the record only after confirming the prior stuck. GetDisplaySetting shows it.", output);
        }
        if (!known) {
            output["install"] = host.IdentityJson();
            return _DisplayErr("this install's identity is unknown (" + why + "), so a restore record could not be"
                + " bound to it; nothing was changed", "IDENTITY_UNKNOWN", false,
                "SetDisplaySetting requires a valid port.override prefix marker (not a lease check).", output);
        }
        string gate = _DisplayWrapperGate(host);
        if (gate.Length > 0) {
            output["wrapperLoadedBy"] = _WrapperOwnerName(host.WrapperOwner());
            return _DisplayErr(gate + "; nothing was written", "WRAPPER_BUSY", true,
                "Close the graphics settings page, then call SetDisplaySetting again.", output);
        }

        // (2) The prior, from every readable source; they must agree.
        auto before = DisplayReadSources(host);
        output["sources"] = before.ToJson();
        if (before.releasePending) {
            return _DisplayErr("the DisplaySettings wrapper this tool loaded to read bloom was not released; nothing was"
                + " written", "WRAPPER_BUSY", true, "Call SetDisplaySetting again.", output);
        }
        if (before.Readable() == 0) {
            return _DisplayErr("no display config available (no viewport / script API)", "NOT_AVAILABLE", true, "", output);
        }
        if (!before.Agree()) {
            return _DisplayErr("the bloom sources disagree (wrapper " + BloomName(before.wrapper) + ", systemConfig "
                + BloomName(before.systemConfig) + "); nothing was written", "SOURCES_DISAGREE", true,
                "GetDisplaySetting shows both; try again once they agree.", output);
        }
        int current = before.Current();
        output["prior"] = BloomName(current);
        if (current == index) {
            output["now"] = wanted;
            output["mechanism"] = "none";
            output["restoreRecord"] = "none needed";
            return MakeSuccess(output);
        }

        // (3) The record, read back exactly, before any write.
        bool safe = host.SafeMode();
        auto next = DisplayRecord();
        next.prior = BloomName(current);
        next.target = wanted;
        next.config = DisplayConfigName(safe);
        next.identity = identity;
        next.setAt = host.Now();
        string err;
        if (!DisplayStoreRecord(host, next, err)) {
            return _DisplayErr("could not write the restore record (" + err + "); nothing was changed",
                "RESTORE_RECORD_FAILED", true, "", output);
        }
        output["restoreRecord"] = "written";
        output["restoreTo"] = next.prior;
        output["config"] = next.config;

        // (4) One write, by a mechanism chosen now, then read every source back.
        string mechanism = ChooseBloomMechanism(before.wrapperLoaded, before.owner != DISPLAY_WRAPPER_NONE);
        output["mechanism"] = mechanism;
        bool releasePending;
        bool wrote = DisplayWriteBloom(host, mechanism, index, err, releasePending);
        output["wrote"] = wrote;
        if (err.Length > 0) output["writeError"] = err;
        auto after = DisplayReadSources(host);
        output["sourcesAfter"] = after.ToJson();
        output["now"] = _BloomJson(after.Current());
        output["changed"] = after.Current() >= 0 && after.Current() != current;
        output["persisted"] = "assumed";
        output["restoreWith"] = "RestoreDisplaySetting";
        output["displayBefore"] = _DisplayWatchJson(before.watch);
        output["displayAfter"] = _DisplayWatchJson(after.watch);
        output["sideEffects"] = (before.watch !is null && before.watch.ok && after.watch !is null && after.watch.ok)
            ? DisplaySideEffects(before.watch.dirty, after.watch.dirty, before.watch.mode, after.watch.mode,
                                 before.watch.winX, before.watch.winY, after.watch.winX, after.watch.winY)
            : "unknown";
        output["sideEffectsNote"] = "Only fields observed in the same frame; does not rule out window or device resets.";
        output["runtimeEffect"] = "UNPROVEN: whether the renderer drops bloom at once is not verified; compare screenshots.";
        if (!wrote || !after.AllAre(index)) {
            return _DisplayErr("the bloom write did not read back as " + wanted + " from every source (read back in"
                + " the same frame: an Apply that lands on a later frame shows here as unverified)", "APPLY_UNVERIFIED", true,
                "The restore record is kept. GetDisplaySetting shows the settled value; RestoreDisplaySetting puts the prior back.",
                output);
        }
        return MakeSuccess(output);
    }

    Json::Value@ RestoreDisplaySettingTool(DisplayHost@ host, Json::Value &in input) {
        if (g_displayBusy) return _DisplayBusy("RestoreDisplaySetting");
        g_displayBusy = true;
        Json::Value@ r;
        string bodyError;
        try {
            @r = _DisplayRestore(host, input);
        } catch {
            bodyError = getExceptionInfo();
        }
        return _DisplayCompleteCall(host, r, "RestoreDisplaySetting", bodyError);
    }

    Json::Value@ _DisplayRestore(DisplayHost@ host, Json::Value &in input) {
        if ((input.HasKey("force") && input["force"].GetType() != Json::Type::Boolean)
                || (input.HasKey("retire") && input["retire"].GetType() != Json::Type::Boolean)) {
            return MakeError("force and retire must be booleans", "INVALID_INPUT");
        }
        bool force = input.HasKey("force") && bool(input["force"]);
        bool retire = input.HasKey("retire") && bool(input["retire"]);
        if (force && retire) return MakeError("force and retire are mutually exclusive", "INVALID_INPUT");

        Json::Value output = Json::Object();
        output["forced"] = force;
        output["restored"] = false;
        auto legacy = DisplayLegacyJson(host);
        if (legacy !is null) output["legacyRecord"] = legacy;
        string identity, why;
        bool known = host.InstallIdentity(identity, why);
        DisplayRecord@ rec;
        string reason;
        string state = DisplayLoadRecord(host, rec, reason);
        if (state == "missing") {
            output["action"] = "none";
            output["reason"] = legacy is null ? "no record" : "no record (an older build's record is present; it is never applied)";
            return MakeSuccess(output);
        }
        output["recordKept"] = true;
        output["record"] = DisplayRecordJson(host, state, rec, reason, known, identity);
        if (state == "invalid") {
            output["action"] = "invalid";
            return _DisplayErr("the restore record is invalid (" + reason + "); kept for a person to inspect: "
                + host.FilePath(DISPLAY_RESTORE_FILE), "RESTORE_RECORD_INVALID", false, "", output);
        }
        if (!DisplayRecordMatches(host, rec, known, identity)) {
            output["action"] = "conflict";
            return _DisplayErr(known ? "the record was written on another install, profile or display config; nothing"
                    + " applied, record kept" : "this install's identity is unknown (" + why + "); nothing applied, record kept",
                "RESTORE_CONFLICT", false, "force does not apply here: recover by hand (see the pause-bloom guide).", output);
        }
        int prior = BloomIndex(rec.prior);
        int target = BloomIndex(rec.target);
        // A claim on this tool's own wrapper from an earlier call: release it
        // first, or stop (its copy would make every source unknown).
        if (host.ScriptApiAvailable() && host.WrapperOwner() == DISPLAY_WRAPPER_OURS) {
            string rerr;
            if (!host.WrapperRelease(rerr)) {
                output["action"] = "none";
                return _DisplayErr("the DisplaySettings wrapper this tool loaded earlier could not be released (" + rerr
                    + "); nothing written, record kept", "RESTORE_FAILED", true, "Call RestoreDisplaySetting again.", output);
            }
        }
        auto src = DisplayReadSources(host);
        output["sourcesBefore"] = src.ToJson();
        string err;
        if (retire) {
            output["action"] = "retire";
            if (!src.AllAre(prior)) {
                return _DisplayErr("cannot retire: need a readable prior and no disagreeing or known unreadable source; record kept",
                    "RESTORE_CONFLICT", false, "Restore the prior first; confirm it stuck before retiring the record.", output);
            }
            if (!host.FileDelete(DISPLAY_RESTORE_FILE, err)) {
                return _DisplayErr("could not retire the record: " + err, "RESTORE_FAILED", true, "", output);
            }
            output["retired"] = true;
            output["recordKept"] = false;
            output["now"] = rec.prior;
            return MakeSuccess(output);
        }
        string action = RestoreDecision(src.Readable(), src.AllAre(prior), src.AllAre(target),
                                        src.wrapperUnreadableKnown, force);
        output["action"] = action;
        if (action == "unavailable") {
            return _DisplayErr("no display config readable now; record kept", "RESTORE_FAILED", true, "", output);
        }
        if (action == "conflict") {
            return _DisplayErr("bloom is neither the recorded target (" + rec.target + ") nor the prior (" + rec.prior
                + ") on every source, or a known source cannot be read; nothing written, record kept",
                "RESTORE_CONFLICT", false,
                "GetDisplaySetting shows the sources. RestoreDisplaySetting {force:true} writes the prior anyway,"
                + " overwriting the user's current value.", output);
        }
        if (action == "alreadyPrior") {
            output["now"] = rec.prior;
            output["reason"] = "already at prior";
            output["retireWith"] = "RestoreDisplaySetting {retire:true}";
            return MakeSuccess(output);
        }
        // "apply": one write by a mechanism chosen now; a wrapper someone
        // else holds (or ours, not yet released) is never applied.
        string mechanism = ChooseBloomMechanism(src.wrapperLoaded, src.owner != DISPLAY_WRAPPER_NONE || src.releasePending);
        output["mechanism"] = mechanism;
        bool releasePending;
        bool wrote = DisplayWriteBloom(host, mechanism, prior, err, releasePending);
        output["wrote"] = wrote;
        if (err.Length > 0) output["writeError"] = err;
        auto after = DisplayReadSources(host);
        output["sources"] = after.ToJson();
        output["now"] = _BloomJson(after.Current());
        output["persisted"] = "assumed";
        if (!after.AllAre(prior)) {
            return _DisplayErr("the prior did not read back from every source; record kept", "RESTORE_UNVERIFIED", true,
                after.wrapperUnreadableKnown ? "A DisplaySettings wrapper is still loaded; close the settings page and restore again."
                                             : "GetDisplaySetting shows the sources; restore again.", output);
        }
        output["restored"] = true;
        output["retireWith"] = "RestoreDisplaySetting {retire:true}";
        return MakeSuccess(output);
    }

    // Plugin start / disable / unload: callbacks, no yield. Never restores,
    // never deletes: releases a wrapper this tool still holds and reports a
    // pending record in the log. Returns what it did.
    string DisplayLifecycleCore(DisplayHost@ host, const string &in when) {
        string done = "";
        if (host.ScriptApiAvailable()) {
            bool ours = host.WrapperOwner() == DISPLAY_WRAPPER_OURS;
            string err;
            if (!host.WrapperRelease(err)) done = "wrapper release not confirmed: " + err;
            else if (ours) done = "wrapper released";
        }
        if (host.FileExists(DISPLAY_RESTORE_FILE)) {
            host.Log("TM Control MCP (" + when + "): a bloom restore record is pending at " + host.FilePath(DISPLAY_RESTORE_FILE)
                + "; GetDisplaySetting shows it. To recover the prior, call RestoreDisplaySetting explicitly.");
            done += (done.Length > 0 ? "; " : "") + "record pending";
        }
        if (DisplayLegacyJson(host) !is null) {
            host.Log("TM Control MCP (" + when + "): an older build's bloom restore record is present; never applied."
                + " See GetDisplaySetting and the pause-bloom guide for manual recovery.");
            done += (done.Length > 0 ? "; " : "") + "legacy record present";
        }
        return done;
    }
}
