namespace TmMcp {
    // Native debugger log rows are not exposed by Openplanet reflection. Do not
    // substitute DialogEditScript_TempText (the source editor) for an error log.
    bool IsManiaScriptCrashMessage(const string &in message) {
        string lower = message.ToLower();
        return (lower.Contains("script") || lower.Contains("maptype")) && (lower.Contains("crashed")
            || lower.Contains("compilation failed") || lower.Contains("script error"));
    }

    // Visibility of SystemOverlay.ScriptDebugger; blocking per BlockingScreensPolicy.
    Json::Value ScriptDebuggerSnapshot() {
        Json::Value o = Json::Object();
        o["available"] = false;
        o["visibility"] = 0;
        o["visibilityName"] = ScriptDebuggerVisibilityName(0);
        o["visible"] = false;
        o["blocking"] = false;
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.SystemOverlay is null || app.SystemOverlay.ScriptDebugger is null) return o;
        int v = int(app.SystemOverlay.ScriptDebugger.Visibility);
        o["available"] = true;
        o["visibility"] = v;
        o["visibilityName"] = ScriptDebuggerVisibilityName(v);
        o["visible"] = v != 0;
        o["blocking"] = ScriptDebuggerBlocks(v);
        return o;
    }

    Json::Value ManiaScriptDiagnostics() {
        Json::Value output = Json::Object();
        output["logAvailable"] = false;
        output["logUnavailableReason"] = "Native Script debugger log rows are not exposed by Openplanet. To read them, call DismissManiaScriptDebugger {visibility:'LogsFull'} (shows the full log without OS input), then take a window capture (scripts/capture-instance-window.sh on tmc hosts). TakeScreenshot is native viewport only; Openplanet/plugin UI requires a window/compositor capture (see the screenshots guide); DialogEditScript_TempText is source, not the log.";
        output["crashDialogDetected"] = false;
        output["debuggerAvailable"] = false;
        Json::Value messages = Json::Array();
        auto app = cast<CTrackMania>(GetApp());
        if (app !is null) {
            if (app.SystemOverlay !is null && app.SystemOverlay.ScriptDebugger !is null) {
                output["debuggerAvailable"] = true;
                output["debuggerVisible"] = app.SystemOverlay.ScriptDebugger.Visibility;
                output["scriptDebugger"] = ScriptDebuggerSnapshot();
            }
            for (uint i = 0; i < app.ActiveMenus.Length; i++) {
                auto menu = app.ActiveMenus[i];
                if (menu is null || menu.CurrentFrame is null) continue;
                auto frame = menu.CurrentFrame;
                if (frame.IdName != "FrameAskYesNo") continue;
                auto label = cast<CControlLabel>(_DlgFindChildRecursive(frame, "LabelMessage", 0));
                if (label is null) continue;
                auto dialogs = cast<CGameDialogs>(label.Nod);
                string message = dialogs is null ? string(label.Label) : string(dialogs.String);
                Json::Value row = Json::Object();
                row["menuIndex"] = int(i);
                row["message"] = message;
                row["scriptCrash"] = IsManiaScriptCrashMessage(message);
                if (bool(row["scriptCrash"])) output["crashDialogDetected"] = true;
                messages.Add(row);
            }
        }
        output["messages"] = messages;
        output["healthConfirmed"] = false;
        output["note"] = "No crash dialog does not prove script health: the prompt may have been dismissed. Preserve the debugger error before restarting. Shift+Scroll Lock is the game's advertised script restart shortcut; verify the failed script becomes green. A game mode script that failed to load stays loaded for the life of the game process (observed 2026-11-22: fixing the file on disk did not recompile it); recovery needs a fresh game process. DismissManiaScriptDebugger hides the overlay.";
        return output;
    }

    Json::Value@ DismissManiaScriptDebugger(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.SystemOverlay is null || app.SystemOverlay.ScriptDebugger is null) {
            return MakeError("Script debugger unavailable", "debugger_unavailable");
        }
        // Only views that hide the editor; opening the editor would block input.
        string targetName = input.HasKey("visibility") ? string(input["visibility"]) : "Hidden";
        int target = ScriptDebuggerVisibilityFromName(targetName);
        if (target != 0 && target != 3 && target != 4) {
            return MakeError("visibility must be one of: Hidden, LogsFull, LogsReduced", "INVALID_INPUT", false, "",
                "LogsFull shows the native log for a window capture; Hidden hides the overlay.");
        }
        auto debugger = app.SystemOverlay.ScriptDebugger;
        // Capture prompts first: hiding the overlay can dismiss crash text.
        Json::Value before = ManiaScriptDiagnostics();
        int beforeVisibility = int(debugger.Visibility);
        debugger.Visibility = CGameScriptDebugger::EVisibility(target);
        // Let the overlay frame update before reading back.
        yield();
        yield();
        int after = int(debugger.Visibility);
        Json::Value output = Json::Object();
        output["before"] = beforeVisibility;
        output["beforeName"] = ScriptDebuggerVisibilityName(beforeVisibility);
        output["after"] = after;
        output["afterName"] = ScriptDebuggerVisibilityName(after);
        output["dismissed"] = after == 0;
        output["applied"] = after == target;
        output["messages"] = before["messages"];
        output["note"] = target == 0
            ? "Hides the native ManiaScript debugger overlay. Does not restart scripts; Shift+Scroll Lock remains the game's script-restart shortcut."
            : "Debugger log view shown; read it in a window capture, then call again with visibility Hidden. Does not restart scripts.";
        return MakeSuccess(output);
    }

    Json::Value@ GetManiaScriptDiagnostics(Json::Value &in input) {
        auto output = ManiaScriptDiagnostics();
#if DEV
        output["detectorTests"] = RunManiaScriptDiagnosticsTests();
        if (!bool(output["detectorTests"]["passed"])) {
            auto error = MakeError("ManiaScript crash detector regression tests failed", "SELF_TEST_FAILED");
            error["output"] = output;
            return error;
        }
#endif
        return MakeSuccess(output);
    }
}
