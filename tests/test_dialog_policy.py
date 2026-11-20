"""Dialog classification and refusal policy, run in stock AngelScript.

Live case (2026-11-15): with the "save changes?" prompt up, GetDialog said
dialogKind "none" with frameIdName FrameAskYesNo, because the kind came from
the BasicDialogs enum alone (None/Message/WaitMessage).
"""
from pathlib import Path
import subprocess

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "DialogPolicy.as"
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def run_policy(runner, tmp_path, body):
    case = tmp_path / "dialog_policy_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_frames_the_enum_calls_none_are_classified(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    // The save prompt: enum None, frame FrameAskYesNo. Must never be "none".
    Check(ClassifyDialogKind(0, "FrameAskYesNo", "") == "askYesNo", "save prompt");
    Check(ClassifyDialogKind(0, "FrameDialogSaveAs", "") == "saveAs", "save as");
    Check(ClassifyDialogKind(0, "FrameSomethingNew", "") == "frameDialog", "any BasicDialogs frame is a dialog");
    Check(ClassifyDialogKind(0, "", "FrameDialogEditorChallengeCard") == "menuDialog", "menu modal");
    Check(ClassifyDialogKind(0, "", "FrameAskYesNo") == "menuDialog", "menu AskYesNo");
    Check(ClassifyDialogKind(0, "", "") == "none", "idle");
    Check(ClassifyDialogKind(0, "", "FrameMainMenu") == "none", "ordinary menu page is not a dialog");
    Check(ClassifyDialogKind(1, "", "") == "message", "message enum");
    Check(ClassifyDialogKind(2, "", "") == "wait", "wait enum");
    Check(ClassifyDialogKind(2, "FrameWaitMessage", "") == "wait", "enum wins over its own frame");
    Check(ClassifyDialogKind(1, "FrameAskYesNo", "") == "askYesNo", "AskYesNo frame wins");
    Check(ClassifyDialogKind(0, "FrameAskYesNo", "FrameDialogEditorChallengeCard") == "askYesNo", "BasicDialogs before menus");
    ''')


def test_blocking_means_needs_an_answer(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    string[] blocking = {"askYesNo", "saveAs", "message", "frameDialog", "menuDialog"};
    for (uint i = 0; i < blocking.Length; i++) {
        Check(DialogKindBlocks(blocking[i]), "blocks: " + blocking[i]);
        Check(DialogNextCallHint(blocking[i]).Length > 0, "hint: " + blocking[i]);
    }
    string[] clear = {"none", "wait", "unavailable", ""};
    for (uint i = 0; i < clear.Length; i++) Check(!DialogKindBlocks(clear[i]), "not blocking: " + clear[i]);
    Check(DialogNextCallHint("askYesNo").IndexOf("SaveMapFlow {save:false}") >= 0, "save prompt names the discard call");
    Check(DialogNextCallHint("askYesNo").IndexOf("RespondDialog") >= 0, "save prompt names RespondDialog");
    Check(DialogNextCallHint("none") == "", "no hint when idle");
    ''')


def test_join_card_hint_names_its_buttons(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    string join = DialogNextCallHint("menuDialog", "FrameDialogJoin");
    Check(join.IndexOf("ClickClassicMenuControl {id:ButtonJoin}") >= 0, "join card names its button");
    Check(join.IndexOf("JoinServer {link}") >= 0, "one-call alternative");
    Check(DialogNextCallHint("menuDialog", "FrameDialogEditorChallengeCard") == DialogNextCallHint("menuDialog"), "other menu modals keep the generic hint");
    Check(DialogNextCallHint("askYesNo", "FrameDialogJoin") == DialogNextCallHint("askYesNo"), "frame refines menu modals only");
    ''')


def test_only_map_module_and_test_starts_need_a_clear_dialog(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    string[] guarded = {"EditNewMap", "OpenMapInEditor", "PlayMap", "BackToMainMenu", "CreateMapViaMenu"};
    for (uint i = 0; i < guarded.Length; i++) Check(ToolNeedsDialogClear(guarded[i], ""), "guarded: " + guarded[i]);
    string[] starts = {"validate", "requestEnterPlayground", "testFromStart", "testFromCoord"};
    for (uint i = 0; i < starts.Length; i++) Check(ToolNeedsDialogClear("ControlValidation", starts[i]), "start: " + starts[i]);
    Check(!ToolNeedsDialogClear("ControlValidation", "status"), "status reads");
    Check(!ToolNeedsDialogClear("ControlValidation", "requestLeavePlayground"), "leaving stays allowed");
    // The pause menu and display writes refuse behind a dialog (review 1 F9).
    Check(ToolNeedsDialogClear("ControlPause", "pause"), "pause");
    Check(ToolNeedsDialogClear("ControlPause", "resume"), "resume");
    Check(ToolNeedsDialogClear("SetDisplaySetting", ""), "set bloom");
    // Answering, inspecting and recovery must never be refused.
    string[] free = {"GetDialog", "RespondDialog", "SaveMapFlow", "GetMode", "WaitUntil", "ClickMenuButton", "TriggerControlOnAction",
                     "RestoreDisplaySetting", "GetDisplaySetting", "GetPauseState"};
    for (uint i = 0; i < free.Length; i++) Check(!ToolNeedsDialogClear(free[i], ""), "free: " + free[i]);
    ''')


def test_editor_mutations_are_refused_behind_a_dialog(as_runner, tmp_path):
    # Live 2026-11-19: a script kept placing blocks behind "save changes?" after its
    # OpenMapInEditor was refused. Map edits behind a dialog land on a map being left.
    run_policy(as_runner, tmp_path, r'''
    string[] mutating = {"PlaceBlock", "RemoveBlock", "ClearBlocks", "ClearItems", "ClearMapContent",
        "Undo", "Redo", "UndoRedo", "CopyPasteSelection", "SetMoodTimeOfDay",
        "PlaceBlockViaEditorPlusPlus", "PlaceItemViaEditorPlusPlus", "PlaceNamedMacroblock",
        "AddBlocksToNamedMacroblock", "AddItemsToNamedMacroblock",
        "RemoveRecentItems", "RemoveItemsByIndex", "RemoveByTag"};
    for (uint i = 0; i < mutating.Length; i++) Check(ToolMutatesEditor(mutating[i]), "mutates: " + mutating[i]);
    // Answering, saving, reading and camera moves stay allowed.
    string[] free = {"GetDialog", "RespondDialog", "SaveMapFlow", "SaveMapAs", "GetMode", "WaitUntil",
        "GetBlocks", "GetMapInfo", "ControlCamera", "ControlPlayCamera", "GetVehicleState", "TakeScreenshot"};
    for (uint i = 0; i < free.Length; i++) Check(!ToolMutatesEditor(free[i]), "free: " + free[i]);
    ''')


def _body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


def test_summary_classifies_with_the_policy_and_keeps_the_raw_enum():
    body = _body(MCP_TOOLS, "Json::Value BasicDialogSummary(")
    assert "ClassifyDialogKind(int(bd.Dialog)" in body
    assert 'output["dialog"] = int(bd.Dialog);' in body
    assert 'output["dialogKind"] = kind;' in body
    assert 'output["blocking"] = DialogKindBlocks(kind);' in body
    assert "_ModalMenuFrameName(app)" in body
    # The old enum-only mapping is gone everywhere.
    for name in ("McpTools.as", "Readiness.as"):
        text = (ROOT / "src" / name).read_text()
        assert 'Message ? "message" : "none"' not in text
        assert '? "none"\n' not in text
