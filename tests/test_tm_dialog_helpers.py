"""Offline behavioral tests; subprocesses and bridge calls are always mocked."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import pytest


TOOLS = Path(__file__).resolve().parents[1] / "tools"


@pytest.fixture
def helpers(monkeypatch):
    # tm_shot imports its sibling. Keep import state local to these tests.
    monkeypatch.syspath_prepend(str(TOOLS))
    modules = []
    for name in ("tm_dialog_guard", "tm_shot"):
        spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, name, module)
        spec.loader.exec_module(module)
        modules.append(module)
    guard, shot = modules
    # Fail closed if a test accidentally attempts a real subprocess.
    def forbidden(*args, **kwargs):
        pytest.fail("unmocked subprocess invocation")
    monkeypatch.setattr(guard.subprocess, "run", forbidden)
    return guard, shot


def dialog(frame=None, kind="none", **extra):
    result = {"available": True, "hasFrame": frame is not None, "dialogKind": kind}
    if frame is not None:
        result["frameIdName"] = frame
    return dict(result, **extra)


def reply(output, success=True):
    return {"ok": True, "error": "", "data": {"result": {"success": success, "output": output}}}


def mock_client(monkeypatch, guard, replies):
    pending = iter(replies)
    calls = []
    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        value = next(pending)
        if isinstance(value, Exception):
            raise value
        if isinstance(value, subprocess.CompletedProcess):
            return value
        return subprocess.CompletedProcess(argv, 0, json.dumps(value), "")
    monkeypatch.setattr(guard.subprocess, "run", run)
    return calls


def tool_names(calls):
    return [argv[-2] for argv, _ in calls]


def shot_args(**overrides):
    return SimpleNamespace(**dict({"target": None, "distance": None, "vangle": None,
                                   "hangle": None, "settle": 0, "screenshot_dir": None,
                                   "call_timeout": 20, "capture_timeout": 0}, **overrides))


def capture(**extra):
    return dict({"requested": True, "detected": True, "sizeBytes": 4,
                 "fullName": "C:\\Game\\ScreenShots\\ScreenShot42.jpg"}, **extra)


def test_only_identified_confirmation_is_cancelled_and_verified(helpers, monkeypatch, capsys):
    guard, _ = helpers
    confirm = dialog("FrameAskYesNo")
    calls = mock_client(monkeypatch, guard, [
        reply(confirm), reply({"responded": True, "action": "cancel", "before": confirm,
                               "after": dialog()}), reply(dialog()),
    ])
    monkeypatch.setattr(guard.time, "sleep", lambda _: None)
    assert guard.main([]) == 0
    assert capsys.readouterr().out == "CLEAR\n"
    assert tool_names(calls) == ["GetDialog", "RespondDialog", "GetDialog"]
    assert json.loads(calls[1][0][-1]) == {"action": "cancel"}
    assert all(argv[:2] == [sys.executable, str(TOOLS / "call.py")] for argv, _ in calls)
    assert all(kwargs["timeout"] == 20 for _, kwargs in calls)


@pytest.mark.parametrize("state", [
    dialog("FrameDialogSaveAs"), dialog(kind="message"), dialog(kind="wait"),
    dialog("UnexpectedFrame"),
    dialog(activeMenus=[{"frameIdName": "FrameAskYesNo"}]),
    dialog(activeMenus=[{"frameIdName": "FrameDialogEditorChallengeCard"}]),
])
def test_unrelated_dialogs_are_blocked_without_cancelling(helpers, monkeypatch, state, capsys):
    guard, _ = helpers
    calls = mock_client(monkeypatch, guard, [reply(state)])
    assert guard.main([]) == 1
    assert "CLEAR" not in capsys.readouterr().out
    assert tool_names(calls) == ["GetDialog"]


def test_normal_menu_frames_are_not_cancelled(helpers, monkeypatch):
    guard, _ = helpers
    calls = mock_client(monkeypatch, guard, [reply(dialog(activeMenus=[
        {"frameIdName": "FrameMainMenu"}, {"index": 1},
    ]))])
    assert guard.clear_dialogs(settle=0)
    assert tool_names(calls) == ["GetDialog"]


@pytest.mark.parametrize("bad_reply", [
    {"ok": False, "error": "unreachable"}, {}, [],
    {"ok": True, "data": None}, reply({}, success=False),
    reply({"available": False}), reply({}), reply(dialog(hasFrame="false")),
    reply(dialog(dialogKind="unknown")), reply(dialog(hasFrame=True)),
    reply(dialog(activeMenus=None)), reply(dialog(activeMenus=[None])),
    reply(dialog(frameIdName="FrameAskYesNo")),
    subprocess.CompletedProcess([], 0, "not JSON", ""),
    subprocess.CompletedProcess([], 4, json.dumps(reply(dialog())), "socket failed"),
    subprocess.TimeoutExpired("call.py", 20), OSError("client missing"),
])
def test_transport_tool_and_unknown_state_never_clear(helpers, monkeypatch, bad_reply, capsys):
    guard, _ = helpers
    calls = mock_client(monkeypatch, guard, [bad_reply])
    assert guard.main([]) == 1
    out = capsys.readouterr()
    assert "CLEAR" not in out.out
    assert "ERROR" in out.err
    assert tool_names(calls) == ["GetDialog"]


@pytest.mark.parametrize("response", [
    reply({}, success=False), reply({"responded": False}),
    reply({"responded": True, "action": "cancel", "before": dialog("FrameAskYesNo")}),
    reply({"responded": True, "action": "cancel", "before": dialog(), "after": dialog()}),
])
def test_failed_or_unverified_cancel_is_an_error(helpers, monkeypatch, response, capsys):
    guard, _ = helpers
    mock_client(monkeypatch, guard, [reply(dialog("FrameAskYesNo")), response])
    assert guard.main([]) == 1
    assert "CLEAR" not in capsys.readouterr().out


def test_cancel_that_leaves_confirmation_is_bounded(helpers, monkeypatch):
    guard, _ = helpers
    confirm = dialog("FrameAskYesNo")
    acknowledged = {"responded": True, "action": "cancel", "before": confirm, "after": confirm}
    calls = mock_client(monkeypatch, guard, [reply(confirm), reply(acknowledged), reply(confirm)])
    assert guard.clear_dialogs(max_rounds=1, settle=0) is False
    assert tool_names(calls) == ["GetDialog", "RespondDialog", "GetDialog"]


def test_cancel_chain_stops_at_unrelated_dialog(helpers, monkeypatch):
    guard, _ = helpers
    confirm = dialog("FrameAskYesNo")
    save_as = dialog("FrameDialogSaveAs")
    calls = mock_client(monkeypatch, guard, [
        reply(confirm), reply({"responded": True, "action": "cancel", "before": confirm,
                               "after": save_as}), reply(save_as),
    ])
    assert guard.clear_dialogs(settle=0) is False
    assert tool_names(calls) == ["GetDialog", "RespondDialog", "GetDialog"]


def test_watch_stops_nonzero_on_transport_error(helpers, monkeypatch):
    guard, _ = helpers
    mock_client(monkeypatch, guard, [{"ok": False, "error": "offline"}])
    assert guard.main(["--watch"]) == 1


@pytest.mark.parametrize("failed_guard", [False, "error"])
def test_shot_stops_on_guard_failure(helpers, monkeypatch, failed_guard, capsys):
    guard, shot = helpers
    def clear(**kwargs):
        if failed_guard == "error":
            raise guard.HelperError("unknown dialog state")
        return False
    monkeypatch.setattr(shot, "clear_dialogs", clear)
    assert shot.main([]) == 1  # any call would hit the forbidden subprocess
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("options,tool", [
    (["--target", "1,2,3"], "SetEditorOrbitalTarget"),
    (["--distance", "12", "--vangle", "-25", "--hangle", "170"], "SetEditorCamera"),
])
def test_failed_camera_aborts_before_capture(helpers, monkeypatch, options, tool, capsys):
    guard, shot = helpers
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: True)
    calls = mock_client(monkeypatch, guard, [reply({}, success=False)])
    assert shot.main(options) == 1
    assert capsys.readouterr().out == ""
    assert tool_names(calls) == [tool]


def test_shot_preserves_editor_camera_parameters(helpers, monkeypatch):
    guard, shot = helpers
    guard_checks = []
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: guard_checks.append(True) or True)
    calls = mock_client(monkeypatch, guard, [reply({}), reply({}), reply(capture())])
    args = shot_args(target={"x": 32, "y": 11, "z": 40}, distance=12, vangle=-25, hangle=170)
    assert shot.take_shot(args) == capture()["fullName"]
    assert tool_names(calls) == ["SetEditorOrbitalTarget", "SetEditorCamera", "TakeScreenshot"]
    assert json.loads(calls[0][0][-1]) == args.target
    assert json.loads(calls[1][0][-1]) == {"distance": 12, "vAngle": -25, "hAngle": 170}
    assert json.loads(calls[2][0][-1]) == {"currentView": True}
    assert len(guard_checks) == 2


def test_dialog_appearing_during_camera_settle_aborts_capture(helpers, monkeypatch):
    guard, shot = helpers
    checks = iter([True, False])
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: next(checks))
    calls = mock_client(monkeypatch, guard, [reply({})])
    with pytest.raises(guard.HelperError, match="guard is blocked"):
        shot.take_shot(shot_args(distance=12))
    assert tool_names(calls) == ["SetEditorCamera"]


@pytest.mark.parametrize("response", [
    reply({}, success=False), {"ok": False, "error": "socket unavailable"},
    reply(capture(timedOut=True)), reply(capture(pollError="read failed")),
    reply(capture(detected=False)), reply(capture(sizeBytes=0)), reply({}),
    reply(capture(fullNameBefore=capture()["fullName"])),
    subprocess.TimeoutExpired("call.py", 20),
])
def test_capture_failures_never_print_a_path(helpers, monkeypatch, response, capsys):
    guard, shot = helpers
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: True)
    calls = mock_client(monkeypatch, guard, [response])
    assert shot.main([]) == 1
    assert capsys.readouterr().out == ""
    assert tool_names(calls) == ["TakeScreenshot"]


def test_unchanged_old_file_is_not_returned_even_if_tool_claims_success(helpers, monkeypatch, tmp_path, capsys):
    guard, shot = helpers
    old = tmp_path / "ScreenShot42.jpg"
    old.write_bytes(b"old!")
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: True)
    mock_client(monkeypatch, guard, [reply(capture())])
    assert shot.main(["--screenshot-dir", str(tmp_path), "--capture-timeout", "0"]) == 1
    assert capsys.readouterr().out == ""
    assert old.read_bytes() == b"old!"


@pytest.mark.parametrize("existing", [False, True])
def test_mapped_capture_requires_new_or_changed_file(helpers, monkeypatch, tmp_path, existing):
    _, shot = helpers
    path = tmp_path / "ScreenShot42.jpg"
    if existing:
        path.write_bytes(b"old")
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: True)
    def take(tool, payload, **kwargs):
        assert tool == "TakeScreenshot"
        path.write_bytes(b"new!")
        # A newer unrelated file must not be selected.
        (tmp_path / "ScreenShot99.jpg").write_bytes(b"other")
        return capture()
    monkeypatch.setattr(shot, "call", take)
    assert shot.take_shot(shot_args(screenshot_dir=str(tmp_path))) == path


def test_client_detected_host_path_must_match_native_capture(helpers, tmp_path):
    guard, shot = helpers
    path = tmp_path / "ScreenShot42.jpg"
    path.write_bytes(b"new!")
    output = capture(detectedScreenshot={"detected": True, "linuxPath": str(path)})
    assert shot.capture_path(output) == path
    output["detectedScreenshot"]["linuxPath"] = str(tmp_path / "ScreenShot41.jpg")
    with pytest.raises(guard.HelperError):
        shot.capture_path(output)


def test_client_detected_host_file_size_must_match_native_capture(helpers, tmp_path):
    guard, shot = helpers
    path = tmp_path / "ScreenShot42.jpg"
    path.write_bytes(b"truncated")
    output = capture(detectedScreenshot={"detected": True, "linuxPath": str(path)})
    with pytest.raises(guard.HelperError, match="does not match"):
        shot.capture_path(output)


def test_configured_directory_cannot_be_bypassed_by_detected_host_path(helpers, monkeypatch, tmp_path):
    guard, shot = helpers
    mapped = tmp_path / "mapped"
    mapped.mkdir()
    other = tmp_path / "ScreenShot42.jpg"
    other.write_bytes(b"new!")
    monkeypatch.setattr(shot, "clear_dialogs", lambda **_: True)
    mock_client(monkeypatch, guard, [reply(capture(detectedScreenshot={
        "detected": True, "linuxPath": str(other),
    }))])
    with pytest.raises(guard.HelperError, match="no new screenshot"):
        shot.take_shot(shot_args(screenshot_dir=str(mapped)))


def test_mapped_capture_waits_for_new_file_without_reusing_old(helpers, monkeypatch, tmp_path):
    _, shot = helpers
    path = tmp_path / "ScreenShot42.jpg"
    path.write_bytes(b"old!")
    before = shot.snapshot(tmp_path)
    monkeypatch.setattr(shot.time, "sleep", lambda _: path.write_bytes(b"new!"))
    assert shot.capture_path(capture(), tmp_path, before, timeout=1) == path


def test_screenshot_directory_can_come_from_environment(helpers, monkeypatch, tmp_path, capsys):
    _, shot = helpers
    monkeypatch.setenv("TM_SCREENSHOT_DIR", str(tmp_path))
    seen = []
    monkeypatch.setattr(shot, "take_shot", lambda args: seen.append(args.screenshot_dir) or "new.jpg")
    assert shot.main([]) == 0
    assert seen == [str(tmp_path)]
    assert capsys.readouterr().out == "new.jpg\n"


@pytest.mark.parametrize("options", [
    ["--target", "1,2"], ["--target", "1,nan,3"], ["--distance", "-1"],
    ["--vangle", "inf"], ["--settle", "-1"], ["--capture-timeout", "nan"],
    ["--call-timeout", "0"],
])
def test_invalid_shot_arguments_fail_before_any_bridge_call(helpers, options):
    _, shot = helpers
    with pytest.raises(SystemExit) as error:
        shot.main(options)
    assert error.value.code == 2
