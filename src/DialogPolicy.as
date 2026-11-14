namespace TmMcp {
    // Pure dialog policy: no game types, so tests/test_dialog_policy.py runs it
    // in stock AngelScript. See docs/dialogs.md.
    //
    // BasicDialogs.Dialog (CGameDialogs::EDialog) only has None(0), Message(1)
    // and WaitMessage(2). The unsaved-changes prompt and the SaveAs dialog are
    // frames on BasicDialogs.Dialogs.CurrentFrame (FrameAskYesNo /
    // FrameDialogSaveAs) while Dialog stays None, so the enum alone reports
    // them as "none". Classify from the enum, that frame, and modal frames on
    // app.ActiveMenus (e.g. the map-saved challenge card).

    bool IsModalDialogFrameName(const string &in id) {
        return id == "FrameAskYesNo" || id.StartsWith("FrameDialog");
    }

    // basicFrame: BasicDialogs.Dialogs.CurrentFrame.IdName ("" when none).
    // That menu hosts only dialogs, so any frame there counts as one.
    // menuFrame: first modal-looking app.ActiveMenus[i].CurrentFrame.IdName.
    string ClassifyDialogKind(int basicDialog, const string &in basicFrame, const string &in menuFrame) {
        if (basicFrame == "FrameAskYesNo") return "askYesNo";
        if (basicFrame == "FrameDialogSaveAs") return "saveAs";
        if (basicDialog == 1) return "message";
        if (basicDialog == 2) return "wait";
        if (basicFrame.Length > 0) return "frameDialog";
        if (IsModalDialogFrameName(menuFrame)) return "menuDialog";
        return "none";
    }

    // Needs an answer before the game can leave the map or start a test. A
    // wait message (loading, saving, shadows) resolves itself: reported, not
    // blocking.
    bool DialogKindBlocks(const string &in kind) {
        return kind != "none" && kind != "wait" && kind != "unavailable" && kind.Length > 0;
    }

    // Tools that leave the map, change module, or start a test. They refuse
    // while a blocking dialog is up instead of queueing behind it.
    bool ToolNeedsDialogClear(const string &in name, const string &in action) {
        if (name == "EditNewMap" || name == "OpenMapInEditor" || name == "PlayMap"
            || name == "BackToMainMenu" || name == "CreateMapViaMenu") return true;
        if (name == "ControlValidation") {
            return action == "validate" || action == "requestEnterPlayground"
                || action == "testFromStart" || action == "testFromCoord";
        }
        return false;
    }

    string DialogNextCallHint(const string &in kind) {
        if (kind == "askYesNo") return "Answer with RespondDialog {action:yes|no|cancel}. For the unsaved-changes prompt: SaveMapFlow {name} saves, SaveMapFlow {save:false} discards.";
        if (kind == "saveAs") return "SaveAs dialog: RespondDialog {action:saveas-setname,name} then {action:validate}, or {action:saveas-cancel}. SaveMapFlow drives the whole chain.";
        if (kind == "message") return "Acknowledge with RespondDialog {action:ok}.";
        if (kind == "wait") return "Wait message (loading/saving): WaitUntil {condition:dialogClear}.";
        if (kind == "menuDialog") return "Menu modal (e.g. map-saved card): RespondDialog {action:frame-ok} or {action:frame-cancel}.";
        if (kind == "frameDialog") return "Unknown dialog frame: inspect GetDialog, then RespondDialog.";
        return "";
    }
}
