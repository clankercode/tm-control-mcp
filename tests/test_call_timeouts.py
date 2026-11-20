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


PAUSE_POLICY = (Path(__file__).resolve().parents[1] / "src" / "PausePolicy.as").read_text()


def _as_const(name):
    import re
    return int(re.search(rf"const int {name} = (\d+);", PAUSE_POLICY).group(1))


def test_control_pause_clamps_match_the_plugin():
    assert client.PAUSE_HOLD_MS == (_as_const("PAUSE_HOLD_MS_DEFAULT"), _as_const("PAUSE_HOLD_MS_MIN"),
                                    _as_const("PAUSE_HOLD_MS_MAX"))
    assert client.PAUSE_TIMEOUT_MS == (_as_const("PAUSE_TIMEOUT_MS_DEFAULT"), _as_const("PAUSE_TIMEOUT_MS_MIN"),
                                       _as_const("PAUSE_TIMEOUT_MS_MAX"))
    assert client.PAUSE_CLEANUP_RESERVE_MS == _as_const("PAUSE_CLEANUP_RESERVE_MS")
    assert "return 3 * holdMs + timeoutMs + uint(PAUSE_CLEANUP_RESERVE_MS);" in PAUSE_POLICY


@pytest.mark.parametrize("payload,budget_s", [
    ({"action": "pause"}, 3 * 0.3 + 3.0 + 2.0),
    ({"action": "pause", "holdMs": 2000, "timeoutMs": 10000}, 3 * 2.0 + 10.0 + 2.0),
    ({"action": "pause", "holdMs": 99999, "timeoutMs": 99999}, 3 * 2.0 + 10.0 + 2.0),
    ({"action": "resume", "holdMs": 1, "timeoutMs": 1}, 3 * 0.1 + 0.1 + 2.0),
])
def test_control_pause_socket_outlives_the_plugin_budget(payload, budget_s, capsys):
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock

    def recv(_):
        # The plugin answers right at the end of its own budget.
        if sock.settimeout.call_args.args[0] <= budget_s:
            raise TimeoutError("socket gave up before the plugin's deadline")
        return b'{"ok":true,"data":{"result":{"success":true,"output":{}}}}\n'

    sock.recv.side_effect = recv
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "ControlPause", json.dumps(payload)]), \
         mock.patch.object(client.socket, "create_connection", return_value=sock) as connect:
        assert client.main() == 0
    assert connect.call_args.kwargs["timeout"] >= budget_s + 5.0
    assert json.loads(capsys.readouterr().out)["ok"] is True


def test_control_pause_long_explicit_timeout_is_kept(capsys):
    """Review 2 F10 survivor: --timeout 90 must survive the ControlPause expansion."""
    sock = mock.MagicMock()
    sock.__enter__.return_value = sock
    sock.recv.return_value = b'{"ok":true,"data":{"result":{"success":true,"output":{}}}}\n'
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "--timeout", "90", "ControlPause",
                                         '{"action":"pause"}']), \
         mock.patch.object(client.socket, "create_connection", return_value=sock) as connect:
        assert client.main() == 0
    assert connect.call_args.kwargs["timeout"] == 90
    assert sock.settimeout.call_args.args[0] == 90
    assert json.loads(capsys.readouterr().out)["ok"] is True


@pytest.mark.parametrize("payload", [
    '{"action":"pause","holdMs":1e309}',
    '{"action":"pause","timeoutMs":-1e309}',
    '{"action":"pause","holdMs":NaN}',
    '{"action":"pause","holdMs":Infinity}',
    '{"action":"pause","holdMs":250.5}',
    '{"action":"pause","timeoutMs":"3000"}',
    '{"action":"pause","holdMs":true}',
])
def test_control_pause_rejects_nonfinite_or_noninteger_input(payload, capsys):
    """Review 2 P3: 1e309 decodes to inf and int() raised OverflowError before any request."""
    with mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "ControlPause", payload]), \
         mock.patch.object(client.socket, "create_connection",
                           side_effect=AssertionError("must not connect")) as connect:
        assert client.main() == 2
    connect.assert_not_called()
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] is False and out["code"] == "INVALID_INPUT"
    assert "ControlPause" in out["error"]


@pytest.mark.parametrize("value,expected", [
    (float("inf"), 2000), (float("-inf"), 100), (float("nan"), 100), (1e300, 2000), (2000.0, 2000), (150, 150),
])
def test_pause_clamp_is_finite_safe(value, expected):
    assert client._pause_clamp(value, client.PAUSE_HOLD_MS) == expected
    assert client.pause_socket_timeout(5.0, {"holdMs": value}) >= 5.0
