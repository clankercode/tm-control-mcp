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
        resp = call_mod.wait_until_mode("127.0.0.1", 30006, 5.0, "Editor", 12.0)
    assert captured["request"]["tool"] == "WaitUntil"
    assert captured["request"]["input"]["condition"] == "mode"
    assert captured["request"]["input"]["equals"] == "Editor"
    assert captured["request"]["input"]["timeoutMs"] == 12000
    assert captured["timeout"] >= 14.0
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
    assert call_mod.wait_socket_timeout(5.0, 120_000) == 62.0
    assert call_mod.wait_socket_timeout(5.0, -1) == 5.0


def test_standalone_wait_prints_wait_response(capsys):
    response = {"ok": True, "data": {"result": {"success": True, "output": {"ok": True}}}}
    with (
        mock.patch.object(call_mod, "send_request", return_value=response),
        mock.patch.object(sys, "argv", ["call.py", "--skip-process-check", "--until-ready", "editor"]),
    ):
        assert call_mod.main() == 0
    assert capsys.readouterr().out.strip() == '{"ok":true,"data":{"result":{"success":true,"output":{"ok":true}}}}'


def test_wait_timeout_out_of_range_is_rejected(capsys):
    with mock.patch.object(sys, "argv", ["call.py", "--wait-timeout", "61", "GetMode"]):
        with pytest.raises(SystemExit) as exc_info:
            call_mod.main()
    assert exc_info.value.code == 2
    assert "must be between 0 and 60" in capsys.readouterr().err


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
