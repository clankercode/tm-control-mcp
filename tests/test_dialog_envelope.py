"""Every socket tool response carries a compact data.dialog; call.py surfaces it."""
import json
from pathlib import Path
import sys
from unittest import mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import call as client  # noqa: E402

PROTOCOL = (ROOT / "src" / "Protocol.as").read_text()
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def _body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


def test_dispatcher_adds_dialog_to_every_tool_response_last():
    body = _body(PROTOCOL, "Json::Value@ HandleCall(")
    assert body.count('data["dialog"] = CompactDialogState();') == 1
    # Sampled after the tool and after any one-frame dialogAfter observation.
    assert body.index("AttachDialogAfterTool(tool, result);") < body.index('data["dialog"]')
    assert body.index('data["result"] = result;') < body.index('data["dialog"]')


def test_compact_state_is_cheap_and_flat_when_clear():
    body = _body(MCP_TOOLS, "Json::Value CompactDialogState(")
    for costly in ("yield", "sleep", "BuildDialogSummary", "EditorInterfaceFramesSummary",
                   "_DlgFindChildRecursive", "ActiveMenusFramesSummary"):
        assert costly not in body, costly
    # Clear state is a single flag: return right after o["up"].
    clear = body.index('if (kind == "none") return o;')
    assert body.index('o["up"] = kind != "none";') < clear < body.index('o["kind"] = kind;')
    for key in ("kind", "blocking", "frame", "text", "hint"):
        assert f'o["{key}"]' in body


def _run_call(tool, payload, response, capsys):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock
    sock.recv.return_value = (json.dumps(response) + "\n").encode()
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", tool, json.dumps(payload)]), \
         mock.patch.object(client.socket, "create_connection", return_value=sock):
        assert client.main() == 0
    return capsys.readouterr()


SAVE_PROMPT = {"up": True, "kind": "askYesNo", "blocking": True, "frame": "FrameAskYesNo",
               "hint": "Answer with RespondDialog {action:yes|no|cancel}."}


def test_call_prints_one_dialog_line_on_stderr_and_keeps_stdout_json(capsys):
    response = {"ok": True, "error": "", "route": "call",
                "data": {"tool": "GetMode", "result": {"success": True, "output": {"mode": "MapEditor"}},
                         "dialog": SAVE_PROMPT}}
    out = _run_call("GetMode", {}, response, capsys)
    assert json.loads(out.out) == response
    lines = [l for l in out.err.splitlines() if "dialog up" in l]
    assert lines == ["[tm-control-mcp] dialog up: kind=askYesNo blocking=true frame=FrameAskYesNo "
                     "hint=Answer with RespondDialog {action:yes|no|cancel}."]


@pytest.mark.parametrize("dialog", [{"up": False}, None, "garbage", {"up": "true"}])
def test_call_is_silent_without_a_reported_dialog(dialog, capsys):
    data = {"tool": "GetMode", "result": {"success": True, "output": {}}}
    if dialog is not None:
        data["dialog"] = dialog
    out = _run_call("GetMode", {}, {"ok": True, "error": "", "data": data}, capsys)
    assert "dialog up" not in out.err
