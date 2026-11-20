"""call.py tells the caller what to call instead of a guessed tool name."""
import json
from pathlib import Path
import sys
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import call as client  # noqa: E402


def _run(argv, capsys, response=None):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock
    sock.recv.return_value = (json.dumps(response) + "\n").encode()
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", *argv]), \
         mock.patch.object(client.socket, "create_connection", return_value=sock):
        code = client.main()
    return code, capsys.readouterr()


def test_plugin_suggestions_reach_stderr(capsys):
    result = {"success": False, "error": "unknown tool 'ReloadPlugin'; did you mean ControlPlugin?",
              "code": "unknown_tool", "tool": "ReloadPlugin", "hint": "… {\"route\":\"catalog\"} …",
              "suggestions": ["ControlPlugin", "GetPlugin"]}
    response = {"ok": True, "error": "", "route": "call",
                "data": {"tool": "ReloadPlugin", "result": result, "dialog": {"up": False}}}
    code, out = _run(["ReloadPlugin", "{}"], capsys, response)
    assert code == 0 and json.loads(out.out) == response
    assert "[tm-control-mcp] did you mean: ControlPlugin, GetPlugin" in out.err.splitlines()
    assert "code=unknown_tool" in out.err and "catalog" in out.err


def test_no_suggestion_line_without_suggestions(capsys):
    response = {"ok": True, "error": "", "route": "call",
                "data": {"tool": "X", "result": {"success": False, "code": "unknown_tool", "suggestions": []}}}
    _, out = _run(["X", "{}"], capsys, response)
    assert "did you mean" not in out.err


def test_strict_unknown_tool_suggests_close_names(capsys, monkeypatch):
    monkeypatch.setattr(client, "load_schemas", lambda *a: {"ControlPlugin": {}, "GetPlugin": {}, "GetMode": {}})
    code, out = _run(["--strict", "ControlPlugins", "{}"], capsys)
    assert code == 8
    payload = json.loads(out.out)
    assert payload["suggestions"][0] == "ControlPlugin"
    assert "tools/call.py catalog" in payload["hint"]
