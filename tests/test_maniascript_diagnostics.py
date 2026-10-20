"""Evidence collection must retain failures and never restart/dismiss the game."""
import importlib.util
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("maniascript_diagnostics", Path(__file__).parents[1] / "tools/maniascript_diagnostics.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


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
