"""Map/module changes never act behind a dialog and never answer one.

Live case (2026-11-15): EditNewMap from a dirty editor raised the save prompt;
after "no", EditNewMap did nothing for the rest of the game run.
"""
import json
from pathlib import Path
import sys
from unittest import mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import call as client  # noqa: E402

MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def _body(signature):
    start = MCP_TOOLS.index(signature)
    brace = MCP_TOOLS.index("{", start)
    depth = 0
    for i in range(brace, len(MCP_TOOLS)):
        depth += {"{": 1, "}": -1}.get(MCP_TOOLS[i], 0)
        if depth == 0:
            return MCP_TOOLS[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


def test_dispatcher_refuses_before_any_tool_runs():
    body = _body("Json::Value@ DispatchTool(")
    refusal = body.index("RefuseWhileDialogBlocks(name, input)")
    assert refusal < body.index('if (name == "GetMode")')
    refuse = _body("Json::Value@ RefuseWhileDialogBlocks(")
    assert "ToolNeedsDialogClear(name, action)" in refuse
    assert 'bool(dialog["blocking"])' in refuse
    assert '"DIALOG_BLOCKING"' in refuse
    assert 'output["started"] = false;' in refuse
    assert "DialogNextCallHint(kind, frame)" in refuse


@pytest.mark.parametrize("tool,signature", [
    ("EditNewMap", "Json::Value@ EditNewMapTool("),
    ("OpenMapInEditor", "Json::Value@ OpenMapInEditor("),
    ("PlayMap", "Json::Value@ PlayMap("),
])
def test_map_switches_unwind_before_queueing(tool, signature):
    body = _body(signature)
    prepare = body.index(f'_PrepareModuleChange("{tool}"')
    assert prepare < body.index("startnew(")
    assert body.index("if (pre !is null) return pre;") < body.index("startnew(")


def test_unwind_reports_a_late_dialog_instead_of_menu():
    body = _body("string _UnwindToMenu(")
    loop = body[body.index("app.BackToMainMenu();"):]
    # The prompt can arrive frames after the request: check it every frame,
    # before the menu test, and only count the real main menu as success.
    assert loop.index("_DialogBlocksNow()") < loop.index("_AtMainMenu()") < loop.index("yield();")
    assert 'DetectGameModeName() == "Menu"' in _body("bool _AtMainMenu(")
    prepare = _body("Json::Value@ _PrepareModuleChange(")
    assert "if (_AtMainMenu()) return null;" in prepare
    assert '"DIALOG_BLOCKING"' in prepare and '"UNWIND_TIMEOUT"' in prepare
    assert 'unwind["started"] = false;' in prepare
    back = _body("Json::Value@ BackToMainMenu(")
    assert "_UnwindToMenu(output)" in back


def test_no_guard_or_unwind_path_answers_a_dialog():
    for signature in ("string _UnwindToMenu(", "Json::Value@ _PrepareModuleChange(",
                      "Json::Value@ RefuseWhileDialogBlocks(", "Json::Value@ BackToMainMenu(",
                      "Json::Value@ EditNewMapTool(", "Json::Value@ OpenMapInEditor(",
                      "Json::Value@ PlayMap("):
        body = _body(signature)
        for answer in ("AskYesNo_", "Message_Ok", "DialogSaveAs_", "HideDialogs"):
            assert answer not in body, (signature, answer)


@pytest.mark.parametrize("tool", ["EditNewMap", "OpenMapInEditor", "PlayMap", "BackToMainMenu", "ControlValidation"])
def test_call_waits_long_enough_for_an_unwind(tool, capsys):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock
    sock.recv.return_value = b'{"ok":true,"data":{"result":{"success":true,"output":{}}}}\n'
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", tool, "{}"]), \
         mock.patch.object(client.socket, "create_connection", return_value=sock) as connect:
        assert client.main() == 0
    assert connect.call_args.kwargs["timeout"] >= 60
    assert json.loads(capsys.readouterr().out)["ok"] is True
