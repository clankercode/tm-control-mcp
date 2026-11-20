namespace TmMcp {
    // Native debugger log rows are not exposed by Openplanet reflection. Do not
    // substitute DialogEditScript_TempText (the source editor) for an error log.
    bool IsManiaScriptCrashMessage(const string &in message) {
        string lower = message.ToLower();
        return (lower.Contains("script") || lower.Contains("maptype")) && (lower.Contains("crashed")
            || lower.Contains("compilation failed") || lower.Contains("script error"));
    }

    Json::Value ManiaScriptDiagnostics() {
        Json::Value output = Json::Object();
        output["logAvailable"] = false;
        output["logUnavailableReason"] = "Native Script debugger log rows are not exposed by Openplanet. Read the visible debugger log in a verified capture. TakeScreenshot is native viewport only; Openplanet/plugin UI requires a window/compositor capture (see the screenshots guide); DialogEditScript_TempText is source, not the log.";
        output["crashDialogDetected"] = false;
        output["debuggerAvailable"] = false;
        Json::Value messages = Json::Array();
        auto app = cast<CTrackMania>(GetApp());
        if (app !is null) {
            if (app.SystemOverlay !is null && app.SystemOverlay.ScriptDebugger !is null) {
                output["debuggerAvailable"] = true;
                output["debuggerVisible"] = app.SystemOverlay.ScriptDebugger.Visibility;
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
        output["note"] = "No crash dialog does not prove script health: the prompt may have been dismissed. Preserve the debugger error before restarting. Shift+Scroll Lock is the game's advertised script restart shortcut; verify the failed script becomes green. DismissManiaScriptDebugger hides the overlay.";
        return output;
    }

    Json::Value@ DismissManiaScriptDebugger(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.SystemOverlay is null || app.SystemOverlay.ScriptDebugger is null) {
            return MakeError("Script debugger unavailable", "debugger_unavailable");
        }
        auto debugger = app.SystemOverlay.ScriptDebugger;
        // Capture prompts first: hiding the overlay can dismiss crash text.
        Json::Value before = ManiaScriptDiagnostics();
        int beforeVisibility = int(debugger.Visibility);
        debugger.Visibility = CGameScriptDebugger::EVisibility::Hidden;
        // Let the overlay frame update before reading back.
        yield();
        yield();
        Json::Value output = Json::Object();
        output["before"] = beforeVisibility;
        output["after"] = int(debugger.Visibility);
        output["dismissed"] = int(debugger.Visibility) == int(CGameScriptDebugger::EVisibility::Hidden);
        output["messages"] = before["messages"];
        output["note"] = "Hides the native ManiaScript debugger overlay. Does not restart scripts; Shift+Scroll Lock remains the game's script-restart shortcut.";
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
