"""Process discovery platform adapters, including native Windows tasklist output."""
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import call as client


def test_windows_csv_and_exact_process_name():
    stdout = (b'"Trackmania.exe","481","Console","1","100 K"\r\n'
              b'"trackmania.exe","12","Console","1","200 K"\r\n'
              b'"Trackmania.exe.helper","99","Console","1","200 K"\r\n'
              b'"Trackmania.exe","481","Console","1","100 K"\r\n')
    with mock.patch.object(sys, "platform", "win32"), \
         mock.patch.object(client.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout)) as run, \
         mock.patch.object(client.os, "listdir", side_effect=AssertionError("Windows must not read /proc")):
        assert client.find_trackmania_pids() == [12, 481]
        assert run.call_args.args[0] == ["tasklist", "/FI", "IMAGENAME eq Trackmania.exe", "/FO", "CSV", "/NH"]
        assert run.call_args.kwargs["timeout"] == 5


def test_windows_no_match_or_localized_info_is_empty():
    with mock.patch.object(sys, "platform", "win32"), \
         mock.patch.object(client.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"INFO: Aucun processus ne correspond.\r\n")):
        assert client.find_trackmania_pids() == []


def test_linux_discovery_rejects_wrapper_argument_and_handles_exit_race():
    processes = {
        "/proc/12/cmdline": b"C:\\Games\\Trackmania.exe\0--arg\0",
        "/proc/9/cmdline": b"python3\0Trackmania.exe\0",
    }
    def open_process(path, *_):
        if path not in processes:
            raise FileNotFoundError(path)
        return io.BytesIO(processes[path])
    with mock.patch.object(sys, "platform", "linux"), \
         mock.patch.object(client.os, "listdir", return_value=["12", "9", "10", "self"]), \
         mock.patch("builtins.open", side_effect=open_process):
        assert client.find_trackmania_pids() == [12]


def test_process_listing_failure_is_structured(capsys):
    with mock.patch.object(sys, "argv", ["call.py", "GetMode"]), \
         mock.patch.object(client, "find_trackmania_pids", side_effect=FileNotFoundError("tasklist unavailable")):
        assert client.main() == 3
    result = json.loads(capsys.readouterr().out)
    assert result["ok"] is False
    assert "Could not check" in result["error"]
    assert "--skip-process-check" in result["hint"]


def test_process_listing_timeout_is_structured(capsys):
    with mock.patch.object(sys, "argv", ["call.py", "GetMode"]), \
         mock.patch.object(client, "find_trackmania_pids", side_effect=subprocess.TimeoutExpired("tasklist", 5)):
        assert client.main() == 3
    assert json.loads(capsys.readouterr().out)["ok"] is False
