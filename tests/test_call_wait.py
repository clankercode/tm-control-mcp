#!/usr/bin/env python3
"""Unit tests for call.py wait helpers (no live game required)."""
import sys
from pathlib import Path
from unittest import mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import call as call_mod  # noqa: E402


def test_validate_input_unknown_param():
    err = call_mod.validate_input("T", {"x": 1}, {"properties": {"y": {"type": "integer"}}, "required": []})
    assert "unknown parameter" in err


def test_validate_input_ok():
    err = call_mod.validate_input("T", {"y": 2}, {"properties": {"y": {"type": "integer"}}, "required": ["y"]})
    assert err == ""


def test_tool_result_output_success():
    resp = {
        "ok": True,
        "data": {
            "result": {
                "success": True,
                "output": {"ok": True, "timedOut": False},
            }
        },
    }
    out = call_mod.tool_result_output(resp)
    assert out is not None
    assert out["ok"] is True


def test_tool_result_output_failure():
    resp = {"ok": True, "data": {"result": {"success": False, "error": "nope"}}}
    assert call_mod.tool_result_output(resp) is None


def test_wait_until_mode_request_shape():
    captured = {}

    def fake_send(host, port, timeout, request):
        captured["request"] = request
        captured["timeout"] = timeout
        return {
            "ok": True,
            "data": {
                "tool": "WaitUntil",
                "result": {"success": True, "output": {"ok": True, "timedOut": False}},
            },
        }

    with mock.patch.object(call_mod, "send_request", side_effect=fake_send):
        resp = call_mod.wait_until_mode("127.0.0.1", 30006, 5.0, "Editor", 20.0)
    assert captured["request"]["tool"] == "WaitUntil"
    assert captured["request"]["input"]["condition"] == "mode"
    assert captured["request"]["input"]["equals"] == "Editor"
    assert captured["request"]["input"]["timeoutMs"] == 20000
    # Socket must outlive the idle budget AND a long in-game load.
    assert captured["timeout"] >= call_mod.LOADING_WAIT_SOCKET_SECONDS
    assert call_mod.tool_result_output(resp)["ok"] is True


def test_wait_until_ready_request_shape():
    captured = {}

    def fake_send(host, port, timeout, request):
        captured["request"] = request
        return {
            "ok": True,
            "data": {
                "result": {"success": True, "output": {"ok": False, "timedOut": True}},
            },
        }

    with mock.patch.object(call_mod, "send_request", side_effect=fake_send):
        resp = call_mod.wait_until_ready("127.0.0.1", 30006, 5.0, "editor", 8.0)
    assert captured["request"]["input"]["condition"] == "readiness"
    assert captured["request"]["input"]["want"] == "editor"
    assert call_mod.tool_result_output(resp)["ok"] is False


def test_wait_timeout_zero_is_an_immediate_check():
    captured = {}

    def fake_send(host, port, timeout, request):
        captured["request"] = request
        return {"ok": True, "data": {"result": {"success": True, "output": {"ok": True}}}}

    with mock.patch.object(call_mod, "send_request", side_effect=fake_send):
        call_mod.wait_until_ready("127.0.0.1", 30006, 5.0, "editor", 0.0)
    assert captured["request"]["input"]["timeoutMs"] == 0


def test_wait_socket_timeout_respects_server_ceiling():
    # Idle WaitUntil budget is 20s by default, but the socket must stay open
    # through a loading screen (big maps can take many minutes).
    assert call_mod.wait_socket_timeout(5.0, 20_000) >= call_mod.LOADING_WAIT_SOCKET_SECONDS
    assert call_mod.wait_socket_timeout(5.0, 120_000) >= call_mod.LOADING_WAIT_SOCKET_SECONDS
    assert call_mod.wait_socket_timeout(5.0, -1) == 5.0
    # Immediate check (timeoutMs=0) must not jump to the loading-grace socket.
    assert call_mod.wait_socket_timeout(5.0, 0) == 5.0


def test_standalone_wait_prints_wait_response(capsys):
    response = {"ok": True, "data": {"result": {"success": True, "output": {"ok": True}}}}
    with (
        mock.patch.object(call_mod, "send_request", return_value=response),
        mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "--until-ready", "editor"]),
    ):
        assert call_mod.main() == 0
    assert capsys.readouterr().out.strip() == '{"ok":true,"data":{"result":{"success":true,"output":{"ok":true}}}}'


def test_wait_timeout_out_of_range_is_rejected(capsys):
    too_long = str(int(call_mod.MAX_WAIT_TIMEOUT_SECONDS) + 1)
    with mock.patch.object(sys, "argv", ["call.py", "--wait-timeout", too_long, "GetMode"]):
        with pytest.raises(SystemExit) as exc_info:
            call_mod.main()
    assert exc_info.value.code == 2
    assert "must be between 0 and" in capsys.readouterr().err


def test_collect_host_plugin_logs_filters_compile_lines(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text(
        "\n".join(
            [
                '[    ScriptEngine] [ TRAC] [00:00:00.000] [RemoteBuild]  Starting build for "tm-mcp-rb-probe"',
                "[    ScriptEngine] [ERROR] [00:00:00.001] [RemoteBuild]  C:/users/steamuser/OpenplanetNext/Plugins/tm-mcp-rb-probe/Main.as (2, 5) :  ERR : Unexpected token",
                "[    ScriptEngine] [ERROR] [00:00:00.002] [RemoteBuild]  Script compilation failed!",
                "[   ScriptRuntime] [  LOG] [00:00:00.003] [tm-mcp-rb-probe]  hello runtime",
                "[    ScriptEngine] [ TRAC] [00:00:00.004] [other]  Loaded plugin 'other'",
            ]
        )
        + "\n"
    )
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    report = call_mod.collect_host_plugin_logs("tm-mcp-rb-probe", max_lines=20, compile_only=True)
    assert report["errorCount"] == 1
    assert report["compileFailed"] is True
    assert report["loaded"] is False
    assert any("ERR" in line for line in report["lines"])
    assert all("hello runtime" not in line for line in report["lines"])


def test_collect_host_plugin_logs_real_fail_then_loaded(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text(
        "\n".join(
            [
                '[    ScriptEngine] [ TRAC]  Starting build for "tm-mcp-rb-probe"',
                "[    ScriptEngine] [ERROR]  Plugins/tm-mcp-rb-probe/Main.as :  ERR : boom",
                "[    ScriptEngine] [ERROR]  Script compilation failed!",
                "[    ScriptEngine] [ TRAC]  Loaded plugin 'tm-mcp-rb-probe' (version 0.1.0)",
            ]
        )
        + "\n"
    )
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    report = call_mod.collect_host_plugin_logs("tm-mcp-rb-probe", max_lines=20, compile_only=True)
    assert report["compileFailed"] is True
    assert report["loaded"] is True
    assert report["errorCount"] >= 1


def test_collect_host_plugin_logs_zipped_and_legacy(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text(
        "\n".join(
            [
                '[    ScriptEngine] [ TRAC]  Starting build for "MLHook"',
                "[    ScriptEngine] [ TRAC]  Loaded zipped plugin 'MLHook' (version 0.5.4)",
            ]
        )
        + "\n"
    )
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    report = call_mod.collect_host_plugin_logs("MLHook", max_lines=20, compile_only=True)
    assert report["loaded"] is True
    assert report["compileFailed"] is False


def test_collect_host_plugin_logs_last_session_wins(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text(
        "\n".join(
            [
                '[    ScriptEngine] [ TRAC]  Starting build for "tm-mcp-rb-probe"',
                "[    ScriptEngine] [ERROR]  Plugins/tm-mcp-rb-probe/Main.as :  ERR : boom",
                '[    ScriptEngine] [ TRAC]  Starting build for "tm-mcp-rb-probe"',
                "[    ScriptEngine] [ TRAC]  Loaded plugin 'tm-mcp-rb-probe' (version 0.1.0)",
            ]
        )
        + "\n"
    )
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    report = call_mod.collect_host_plugin_logs("tm-mcp-rb-probe", max_lines=20, compile_only=True)
    assert report["loaded"] is True
    assert report["compileFailed"] is False


def test_enrich_control_plugin_logs_replaces_permission_denied(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text("[    ScriptEngine] [ TRAC] [00:00:00.000]  Loaded plugin 'tm-mcp-rb-probe' (version 0.1.0)\n")
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    response = {
        "ok": True,
        "data": {
            "result": {
                "success": True,
                "output": {
                    "action": "getLogs",
                    "log": {"error": "failed to read Openplanet.log: Permission denied", "lines": [], "count": 0},
                },
            }
        },
    }
    call_mod.enrich_control_plugin_logs(response, "ControlPlugin", {"action": "getLogs", "id": "tm-mcp-rb-probe"})
    log_blob = response["data"]["result"]["output"]["log"]
    assert log_blob.get("source") == "host"
    assert log_blob["loaded"] is True
    assert log_blob["count"] >= 1


def test_enrich_failed_load_attaches_compile(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text(
        '[    ScriptEngine] [ TRAC]  Starting build for "tm-mcp-rb-probe"\n'
        "[    ScriptEngine] [ERROR]  Plugins/tm-mcp-rb-probe/Main.as :  ERR : boom\n"
        "[    ScriptEngine] [ERROR]  Script compilation failed!\n"
    )
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    response = {
        "ok": True,
        "data": {
            "result": {
                "success": False,
                "code": "load_failed",
                "error": "LoadPlugin returned null",
            }
        },
    }
    call_mod.enrich_control_plugin_logs(response, "ControlPlugin", {"action": "load", "id": "tm-mcp-rb-probe"})
    compile_blob = response["data"]["result"]["output"]["compile"]
    assert compile_blob["compileFailed"] is True
    assert compile_blob["errorCount"] >= 1


def test_enrich_max_lines_garbage_does_not_crash(tmp_path, monkeypatch):
    log = tmp_path / "Openplanet.log"
    log.write_text("[    ScriptEngine] [ TRAC]  Loaded plugin 'tm-mcp-rb-probe'\n")
    monkeypatch.setenv("TM_OPENPLANET_LOG", str(log))
    response = {
        "ok": True,
        "data": {
            "result": {
                "success": True,
                "output": {"action": "getLogs", "log": {"error": "Permission denied", "count": 0}},
            }
        },
    }
    call_mod.enrich_control_plugin_logs(
        response, "ControlPlugin", {"action": "getLogs", "id": "tm-mcp-rb-probe", "maxLines": "nope"}
    )
    assert response["data"]["result"]["output"]["log"]["source"] == "host"


def test_socket_lifecycle_fixture_exists():
    root = Path(__file__).resolve().parents[1]
    assert (root / "tools" / "verify_socket_lifecycle.py").is_file()
    assert (root / "tools" / "fixtures" / "tm-mcp-socket-probe" / "Main.as").is_file()
    assert (root / "tools" / "fixtures" / "tm-mcp-socket-probe" / "info.toml").is_file()
    src = (root / "src" / "TmMcp_Export.as").read_text()
    for name in (
        "SetSocketEnabled",
        "StartSocket",
        "StopSocket",
        "IsSocketEnabled",
        "IsSocketListening",
        "GetSocketStatus",
    ):
        assert name in src


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
