"""Read-only crash/message-box detection; all display and sockets are mocked."""
import json
from pathlib import Path
import subprocess
import sys
from unittest import mock
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import call as client
import tm_get_running_pids as discovery


def window(xid, title, width=640, height=240, **extra):
    return dict(xid=xid, name=title, width=width, height=height, **extra)


def test_crash_box_is_distinguished_from_generic_dialog():
    main = window(1, "Trackmania", 1280, 720)
    crash = window(2, 'Crash in "Openplanet.dll"', dialogType=True)
    helper = window(3, "Error", 1, 1)
    assert discovery.classify_dialogs([main, helper]) == []
    result = discovery.classify_dialogs([main, crash, helper])
    assert result[0]["kind"] == "crash"
    assert result[0]["xid"] == 2
    generic = window(4, "Confirmation", dialogType=True, transientFor=1)
    assert discovery.classify_dialogs([main, generic])[0]["kind"] == "message"
    assert discovery.classify_dialogs([main, window(5, "Other window")])[0]["kind"] == "candidate"


def test_timeout_reports_verified_crash_box_and_distinct_exit(capsys):
    dialog = {"xid": 2, "name": "Crash in openplanet.dll", "kind": "crash"}
    with mock.patch.object(sys, "argv", ["call.py", "GetMode"]), \
         mock.patch.object(client, "find_trackmania_pids", return_value=[42]), \
         mock.patch.object(client, "find_game_dialogs", return_value=[dict(dialog, pid=42)]), \
         mock.patch.object(client.socket, "create_connection", side_effect=TimeoutError("timed out")):
        assert client.main() == 14
    result = json.loads(capsys.readouterr().out)
    assert result["dialogs"][0]["kind"] == "crash"
    assert "crash" in result["hint"].lower()


def test_no_display_utilities_never_masks_socket_failure(capsys):
    with mock.patch.object(sys, "argv", ["call.py", "GetMode"]), \
         mock.patch.object(client, "find_trackmania_pids", return_value=[42]), \
         mock.patch.object(discovery.subprocess, "run", side_effect=FileNotFoundError("xdotool")), \
         mock.patch.object(client.socket, "create_connection", side_effect=TimeoutError("timed out")):
        assert client.main() == 4
    result = json.loads(capsys.readouterr().out)
    assert "not" in result["hint"].lower() or "unavailable" in result["hint"].lower()


def test_foreign_windows_are_rejected_before_properties():
    with mock.patch.object(discovery, "_xdotool", return_value="101"), \
         mock.patch.object(discovery, "get_window_pid", return_value=43), \
         mock.patch.object(discovery, "_window_properties") as props:
        assert discovery._x11_windows(42) == []
    props.assert_not_called()


@pytest.mark.parametrize("args,target,fallback", [
    (["--wait-mode", "Menu"], "wait_until_mode", 10),
    (["--until-ready", "menu"], "wait_until_ready", 12),
    (["--strict"], "load_schemas", 7),
])
@pytest.mark.parametrize("has_dialog", [False, True])
def test_pre_call_transport_errors_share_dialog_detection(args, target, fallback, has_dialog, capsys):
    dialogs = [{"kind": "crash", "xid": 2}] if has_dialog else []
    with mock.patch.object(sys, "argv", ["call.py", *args, "GetMode"]), \
         mock.patch.object(client, "find_trackmania_pids", return_value=[42]), \
         mock.patch.object(client, "find_game_dialogs", return_value=dialogs), \
         mock.patch.object(client, target, side_effect=TimeoutError("timeout")):
        assert client.main() == (14 if has_dialog else fallback)
    assert json.loads(capsys.readouterr().out)["dialogs"] == dialogs


def test_main_window_titles_are_not_message_box_proof():
    for title in ("Error", "Crash test map", "Trackmania"):
        assert discovery.classify_dialogs([window(1, title, 1280, 720)]) == []
    result = discovery.classify_dialogs([window(1, "Trackmania", 1280, 720), window(2, "Error")])
    assert result[0]["evidence"] == ["title"]


def test_every_child_timeout_uses_remaining_shared_budget():
    elapsed = [0.0]

    def run(cmd, **kwargs):
        timeout = kwargs["timeout"]
        assert 0 < timeout <= 0.5
        elapsed[0] += min(timeout, 0.35)
        if elapsed[0] >= 2.0:
            raise subprocess.TimeoutExpired(cmd, timeout)
        if "search" in cmd:
            out = "1 2 3 4 5 6"
        elif "getwindowpid" in cmd:
            out = "42"
        elif "getwindowgeometry" in cmd:
            out = "X=0 Y=0 WIDTH=1280 HEIGHT=720"
        else:
            out = "Trackmania"
        return subprocess.CompletedProcess(cmd, 0, stdout=out)

    with mock.patch.object(discovery.time, "monotonic", side_effect=lambda: elapsed[0]), \
         mock.patch.object(discovery.subprocess, "run", side_effect=run):
        discovery.find_game_dialogs([42, 43])
    assert elapsed[0] <= 2.0
