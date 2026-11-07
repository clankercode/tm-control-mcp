"""Exercise the CLI's actual socket budget without waiting on a live game."""
import json
from pathlib import Path
import sys
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import call as client


@pytest.mark.parametrize("tool,payload,minimum", [
    ("RespondDialog", {"action": "no"}, 30),
    ("RespondDialog", {"action": "validate"}, 30),
    ("OpenMapInEditor", {"path": "Example.Map.Gbx", "waitMs": 10000}, 30),
    ("PlayMap", {"path": "Example.Map.Gbx", "waitMs": 10000}, 30),
    ("BackToMainMenu", {}, 30),
    ("ControlValidation", {"action": "requestLeavePlayground"}, 30),
    ("GetMode", {}, 5),
])
def test_cli_allows_normal_editor_teardown(tool, payload, minimum, capsys):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock

    def recv(_):
        # Simulate a successful 7.2s teardown: the old five-second budget fails.
        if minimum > 5 and sock.settimeout.call_args.args[0] < 7.203:
            raise TimeoutError("timed out during successful editor teardown")
        return b'{"ok":true,"data":{"result":{"success":true,"output":{}}}}\n'

    sock.recv.side_effect = recv
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", tool, json.dumps(payload)]), \
         mock.patch.object(client.socket, "create_connection", return_value=sock) as connect:
        assert client.main() == 0
    assert connect.call_args.kwargs["timeout"] >= minimum
    assert json.loads(capsys.readouterr().out)["ok"] is True


def test_long_explicit_timeout_is_preserved(capsys):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock
    sock.recv.return_value = b'{"ok":true}\n'
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "--timeout", "90", "RespondDialog", '{"action":"no"}']), \
         mock.patch.object(client.socket, "create_connection", return_value=sock) as connect:
        assert client.main() == 0
    assert connect.call_args.kwargs["timeout"] == 90
