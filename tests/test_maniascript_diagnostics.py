"""Evidence collection must retain failures and never restart/dismiss the game."""
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest

SPEC = importlib.util.spec_from_file_location("maniascript_diagnostics", Path(__file__).parents[1] / "tools/maniascript_diagnostics.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def capture_response(output=None):
    if output is None:
        output = {"detected": True, "fullName": "C:/captures/ScreenShot01.jpg", "sizeBytes": 128}
    return {"ok": True, "data": {"result": {"success": True, "output": output}}}


def test_crash_evidence_is_preserved_and_screenshot_keeps_debugger():
    calls = []
    response = {"ok": True, "data": {"result": {"success": True, "output": {"crashDialogDetected": True, "messages": [{"message": "The script crashed."}]}}}}
    def call(name, params):
        calls.append((name, params))
        return response if name == "GetManiaScriptDiagnostics" else {"ok": True}
    report = MODULE.collect(call, screenshot=True)
    assert report["crashDialogDetected"] is True
    assert report["diagnostics"] is response
    assert report["logAvailable"] is False
    assert calls == [("GetManiaScriptDiagnostics", {}), ("TakeScreenshot", {"currentView": True, "hideOverlay": False})]


def test_transport_failure_is_unknown_not_clean():
    report = MODULE.collect(lambda *_: {"ok": False, "error": "connection refused"})
    assert report["diagnosticsConfirmed"] is False
    assert report["crashDialogDetected"] is None
    assert report["logAvailable"] is False
    assert report["diagnostics"]["error"] == "connection refused"


def test_tool_failure_is_unknown_even_with_successful_transport():
    report = MODULE.collect(lambda *_: {"ok": True, "data": {"result": {"success": False, "error": "unavailable"}}})
    assert report["diagnosticsConfirmed"] is False
    assert report["crashDialogDetected"] is None


@pytest.mark.parametrize("response", [
    {"ok": False, "id": None, "route": "call", "error": "unknown tool", "data": None},
    {"ok": True, "id": "diagnostics", "route": "call", "error": None, "data": {"result": None}},
])
def test_real_null_envelopes_preserve_original_and_still_capture(response):
    calls = []
    screenshot = {"ok": True, "data": {"result": {"success": True}}}

    def call(name, params):
        calls.append(name)
        return response if name == "GetManiaScriptDiagnostics" else screenshot

    report = MODULE.collect(call, screenshot=True)
    assert report["diagnostics"] is response
    assert report["diagnosticsConfirmed"] is False
    assert report["crashDialogDetected"] is None
    assert report["logAvailable"] is False
    assert report["screenshot"] is screenshot
    assert calls == ["GetManiaScriptDiagnostics", "TakeScreenshot"]


@pytest.mark.parametrize("value", [None, [], ["unexpected"], "unexpected", 7, True])
@pytest.mark.parametrize("layer", ["envelope", "data", "result", "output"])
def test_wrong_object_types_are_unknown_and_preserved(layer, value):
    response = {"ok": True, "data": {"result": {"success": True, "output": {"crashDialogDetected": True}}}}
    if layer == "envelope":
        response = value
    elif layer == "data":
        response["data"] = value
    elif layer == "result":
        response["data"]["result"] = value
    else:
        response["data"]["result"]["output"] = value

    report = MODULE.collect(lambda *_: response)
    assert report["diagnostics"] is response
    assert report["diagnosticsConfirmed"] is False
    assert report["crashDialogDetected"] is None
    assert report["logAvailable"] is False


@pytest.mark.parametrize("value", [None, [], {}, "false", 1])
def test_wrong_crash_flag_type_is_unknown(value):
    response = {"ok": True, "data": {"result": {"success": True, "output": {"crashDialogDetected": value}}}}
    report = MODULE.collect(lambda *_: response)
    assert report["crashDialogDetected"] is None
    assert report["diagnostics"] is response


@pytest.mark.parametrize("error", [
    subprocess.TimeoutExpired("capture", 40),
    OSError("capture launch failed"),
])
def test_capture_exception_keeps_confirmed_evidence(error):
    response = {"ok": True, "data": {"result": {"success": True, "output": {
        "crashDialogDetected": True, "messages": [{"message": "The maptype has crashed."}],
    }}}}
    calls = []

    def call(name, params):
        calls.append((name, params))
        if name == "GetManiaScriptDiagnostics":
            return response
        raise error

    report = MODULE.collect(call, screenshot=True)
    assert report["diagnostics"] is response
    assert report["diagnosticsConfirmed"] is True
    assert report["crashDialogDetected"] is True
    assert report["logAvailable"] is False
    assert report["screenshotError"] == str(error)
    assert calls == [("GetManiaScriptDiagnostics", {}), ("TakeScreenshot", {"currentView": True, "hideOverlay": False})]


@pytest.mark.parametrize("capture_error", [
    None,
    subprocess.TimeoutExpired("capture", 40),
    OSError("capture launch failed"),
])
@pytest.mark.parametrize("response", [
    {"ok": False, "id": None, "route": "call", "error": "unknown tool", "data": None},
    {"ok": True, "id": "diagnostics", "route": "call", "error": None, "data": {"result": None}},
    {"ok": True, "id": "diagnostics", "route": "call", "error": None, "data": {"result": {
        "success": True, "output": {"crashDialogDetected": True, "messages": [{"message": "The maptype has crashed."}]},
    }}},
])
def test_main_persists_original_evidence_on_capture_failure(monkeypatch, tmp_path, capsys, response, capture_error):
    destination = tmp_path / "evidence.json"
    monkeypatch.setattr(MODULE.sys, "argv", ["maniascript_diagnostics.py", "--screenshot", "--output", str(destination)])
    screenshot = capture_response()
    calls = []

    def run(command, **kwargs):
        calls.append((command[2], json.loads(command[3])))
        assert kwargs == {"capture_output": True, "text": True, "timeout": 40}
        if command[2] == "GetManiaScriptDiagnostics":
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(response), stderr="")
        assert command[2] == "TakeScreenshot"
        if capture_error is not None:
            raise capture_error
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(screenshot), stderr="")

    monkeypatch.setattr(MODULE.subprocess, "run", run)
    status = MODULE.main()
    printed = json.loads(capsys.readouterr().out)
    saved = json.loads(destination.read_text())
    assert saved == printed
    assert saved["diagnostics"] == response
    confirmed = response["ok"] is True and response["data"]["result"] is not None
    assert saved["diagnosticsConfirmed"] is confirmed
    assert saved["crashDialogDetected"] is (True if confirmed else None)
    assert saved["logAvailable"] is False
    assert status == (0 if confirmed and capture_error is None else 1)
    if capture_error is not None:
        assert saved["screenshotError"] == str(capture_error)
        assert "error" not in saved
    else:
        assert saved["screenshot"] == screenshot
    assert calls == [("GetManiaScriptDiagnostics", {}), ("TakeScreenshot", {"currentView": True, "hideOverlay": False})]


@pytest.mark.parametrize("output", [
    {"detected": True, "fullName": "C:/captures/ScreenShot01.jpg", "sizeBytes": 128},
    {"detected": True, "fullName": "C:/captures/ScreenShot01.jpg", "sizeBytes": 128,
     "detectedScreenshot": {"detected": False, "linuxPath": "", "size": 0}},
    {"detected": False, "timedOut": True, "detectedScreenshot": {
        "detected": True, "linuxPath": "/tmp/captures/ScreenShot01.jpg", "size": 128, "mtime": 1234.5}},
])
def test_observed_fresh_capture_is_complete(monkeypatch, tmp_path, capsys, output):
    screenshot = capture_response(output)
    report = MODULE.collect(lambda *_: screenshot, screenshot=True)
    assert report["screenshot"] is screenshot
    assert "screenshotError" not in report
    _run_main_capture(monkeypatch, tmp_path, capsys, json.dumps(screenshot), 0, screenshot, expected_status=0)


BAD_CAPTURE_OUTPUTS = [
    {},
    {"requested": True},
    {"detected": False, "timedOut": True, "detectedScreenshot": {
        "detected": False, "linuxPath": "", "size": 0}},
    {"detectedScreenshot": None},
    {"detectedScreenshot": []},
]
for flag in (None, False, 1, "true"):
    BAD_CAPTURE_OUTPUTS.extend([
        {"detected": flag, "fullName": "C:/captures/image.jpg", "sizeBytes": 128},
        {"detectedScreenshot": {"detected": flag, "linuxPath": "/tmp/image.jpg", "size": 128}},
    ])
for path in (None, "", "   ", "image\x00.jpg", 1, [], {}):
    BAD_CAPTURE_OUTPUTS.extend([
        {"detected": True, "fullName": path, "sizeBytes": 128},
        {"detectedScreenshot": {"detected": True, "linuxPath": path, "size": 128}},
    ])
for size in (None, 0, -1, True, "128", 1.5):
    BAD_CAPTURE_OUTPUTS.extend([
        {"detected": True, "fullName": "C:/captures/image.jpg", "sizeBytes": size},
        {"detectedScreenshot": {"detected": True, "linuxPath": "/tmp/image.jpg", "size": size}},
    ])


@pytest.mark.parametrize("screenshot", [
    {"ok": False, "error": "connection refused", "data": None},
    {"ok": True, "data": {"result": {"success": False, "error": "capture failed"}}},
    None, [], "unexpected", 7,
    {"ok": 1, "data": {"result": {"success": True, "output": {}}}},
    {"ok": True, "data": None},
    {"ok": True, "data": {"result": None}},
    {"ok": True, "data": {"result": {"success": 1, "output": {}}}},
    capture_response({"detected": False}),
    *[capture_response(output) for output in BAD_CAPTURE_OUTPUTS],
    *[{"ok": True, "data": {"result": {"success": True, "output": output}}}
      for output in (None, [], "unexpected", True)],
])
def test_main_failed_capture_preserves_raw_and_confirmed_crash(monkeypatch, tmp_path, capsys, screenshot):
    _run_main_capture(monkeypatch, tmp_path, capsys, json.dumps(screenshot), 0, screenshot)


def _run_main_capture(monkeypatch, tmp_path, capsys, stdout, returncode, screenshot, expected_status=1):
    diagnostics = {"ok": True, "data": {"result": {"success": True, "output": {
        "crashDialogDetected": True, "messages": [{"message": "The script crashed."}]}}}}
    destination = tmp_path / "capture-evidence.json"
    monkeypatch.setattr(MODULE.sys, "argv", ["diagnostics", "--screenshot", "--output", str(destination)])

    def run(command, **kwargs):
        if command[2] == "GetManiaScriptDiagnostics":
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(diagnostics), stderr="")
        return subprocess.CompletedProcess(command, returncode, stdout=stdout, stderr="capture stderr")

    monkeypatch.setattr(MODULE.subprocess, "run", run)
    assert MODULE.main() == expected_status
    report = json.loads(capsys.readouterr().out)
    assert json.loads(destination.read_text()) == report
    assert report["diagnostics"] == diagnostics
    assert report["diagnosticsConfirmed"] is True
    assert report["crashDialogDetected"] is True
    if expected_status:
        assert report["screenshotError"]
    else:
        assert "screenshotError" not in report
    assert report["screenshot"] == screenshot
    return report


@pytest.mark.parametrize("returncode", [0, 1])
def test_non_json_capture_is_failure(monkeypatch, tmp_path, capsys, returncode):
    screenshot = {"ok": False, "error": "call.py did not return JSON", "returncode": returncode,
                  "stdout": "not JSON", "stderr": "capture stderr"}
    _run_main_capture(monkeypatch, tmp_path, capsys, "not JSON", returncode, screenshot)


@pytest.mark.parametrize("screenshot", [None, capture_response(), {"ok": False, "error": "capture failed"}])
def test_nonzero_capture_preserves_json_and_process_metadata(monkeypatch, tmp_path, capsys, screenshot):
    report = _run_main_capture(monkeypatch, tmp_path, capsys, json.dumps(screenshot), 4, screenshot)
    assert report["screenshotProcess"] == {"returncode": 4, "stderr": "capture stderr"}


def test_nonzero_diagnostics_preserves_confirmed_crash_but_fails(monkeypatch, capsys):
    diagnostics = {"ok": True, "data": {"result": {"success": True, "output": {
        "crashDialogDetected": True, "messages": [{"message": "The script crashed."}]}}}}
    monkeypatch.setattr(MODULE.sys, "argv", ["diagnostics"])
    monkeypatch.setattr(MODULE.subprocess, "run", lambda command, **kwargs:
                        subprocess.CompletedProcess(command, 2, stdout=json.dumps(diagnostics), stderr="diagnostics stderr"))
    assert MODULE.main() == 1
    report = json.loads(capsys.readouterr().out)
    assert report["diagnostics"] == diagnostics
    assert report["diagnosticsConfirmed"] is True
    assert report["crashDialogDetected"] is True
    assert report["diagnosticsProcess"] == {"returncode": 2, "stderr": "diagnostics stderr"}
    assert report["error"]
