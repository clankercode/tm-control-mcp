"""Offline pack-restoration tests. Never run build.sh or contact a game."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
from unittest import mock

import pytest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_pack_state", ROOT / "tools/build_pack_state.py")
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


def envelope(output):
    return {"ok": True, "data": {"result": {"success": True, "output": output}}}


def plugin(plugin_id, enabled=True):
    return {"id": plugin_id, "enabled": enabled}


@pytest.mark.parametrize("response", [
    None, [], {}, {"ok": False}, {"ok": 1}, {"ok": "true"},
    {"ok": True}, {"ok": True, "data": None},
    {"ok": True, "data": {"result": []}},
    {"ok": True, "data": {"result": {"success": False, "output": {"plugins": []}}}},
    {"ok": False, "data": {"result": {"success": True, "output": {"plugins": []}}}},
    {"ok": True, "data": {"result": {"success": 1, "output": {"plugins": []}}}},
    {"ok": True, "data": {"result": {"output": {"plugins": []}}}},
    envelope(None), envelope([]),
])
def test_invalid_envelope_never_becomes_known_unloaded(response):
    process = subprocess.CompletedProcess([], 0, json.dumps(response), "")
    with mock.patch.object(state.subprocess, "run", return_value=process):
        with pytest.raises(state.UnknownState):
            state.loaded_plugins()


@pytest.mark.parametrize("stdout,code", [("not json", 0), ("", 0),
                                                (json.dumps(envelope({"plugins": []})), 3)])
def test_client_failures_are_unknown(stdout, code):
    with mock.patch.object(state.subprocess, "run", return_value=
                           subprocess.CompletedProcess([], code, stdout, "")):
        with pytest.raises(state.UnknownState):
            state.loaded_plugins()


@pytest.mark.parametrize("error", [OSError("unavailable"), subprocess.TimeoutExpired("call", 25)])
def test_unavailable_client_is_unknown(error):
    with mock.patch.object(state.subprocess, "run", side_effect=error):
        with pytest.raises(state.UnknownState):
            state.loaded_plugins()


@pytest.mark.parametrize("key,id_key", [("plugins", "id"), ("packs", "plugin")])
@pytest.mark.parametrize("entries", [None, {}, "", [None], [[]], [{}],
                                    [{"id": "p", "plugin": "p"}],
                                    [{"id": 3, "plugin": 3, "enabled": True}],
                                    [{"id": "p", "plugin": "p", "enabled": "true"}],
                                    [{"id": "p", "plugin": "p", "enabled": 1}]])
def test_malformed_arrays_are_unknown(key, id_key, entries):
    with pytest.raises(state.UnknownState):
        state.typed_entries({key: entries}, key, id_key)
    with pytest.raises(state.UnknownState):
        state.typed_entries({}, key, id_key)


def test_valid_empty_array_is_known_absence():
    with mock.patch.object(state, "call_tool", return_value={"plugins": []}):
        assert state.loaded_plugins() == {}


def test_duplicate_loaded_ids_are_unknown():
    with mock.patch.object(state, "call_tool", return_value=
                           {"plugins": [plugin("a"), plugin("a", False)]}):
        with pytest.raises(state.UnknownState):
            state.loaded_plugins()


def test_snapshot_filters_prior_running_registered_set():
    packs = [{"plugin": name, "enabled": enabled} for name, enabled in [
        ("provider", True), ("a", True), ("a", True), ("b", True),
        ("disabled", False), ("stale", True), ("disabled-loaded", True),
    ]]
    with mock.patch.object(state, "call_tool", side_effect=[
        {"packs": packs},
        {"plugins": [plugin("provider"), plugin("a"), plugin("b"),
                     plugin("disabled", False), plugin("disabled-loaded", False),
                     plugin("unrelated")]},
    ]) as calls:
        assert state.snapshot("provider") == ["a", "b"]
        assert calls.call_args_list == [mock.call("ListToolPacks", {}),
                                       mock.call("ListPlugins", {"includeDisabled": True})]


def test_restore_rechecks_each_id_and_leaves_active_and_unrelated_alone(capsys):
    with mock.patch.object(state, "call_tool", side_effect=[
        {"plugins": [plugin("unrelated")]}, {},
        {"plugins": [plugin("a"), plugin("b"), plugin("unrelated")]},
        {"plugins": [plugin("a"), plugin("b"), plugin("unrelated")]},
    ]) as calls:
        state.restore(["a", "b", "a"])
        assert calls.call_args_list == [
            mock.call("ListPlugins", {"includeDisabled": True}),
            mock.call("ControlPlugin", {"action": "load", "id": "a"}),
            mock.call("ListPlugins", {"includeDisabled": True}),
            mock.call("ListPlugins", {"includeDisabled": True}),
        ]
    assert "a confirmed running" in capsys.readouterr().out


@pytest.mark.parametrize("reply", [{}, {"plugins": None}, {"plugins": [{}]},
                                    {"plugins": [plugin("a", False)]}])
def test_unknown_or_disabled_current_state_never_loads(reply):
    with mock.patch.object(state, "call_tool", return_value=reply) as calls:
        with pytest.raises(state.UnknownState):
            state.restore(["a"])
        assert calls.call_count == 1


@pytest.mark.parametrize("load_response", [
    {"ok": False}, envelope(None),
    {"ok": True, "data": {"result": {"success": False, "output": {}}}},
])
def test_failed_load_stops_sequence_and_reports_failure(load_response, capsys):
    responses = [envelope({"plugins": []}), load_response]
    with mock.patch.object(state.subprocess, "run", side_effect=[
        subprocess.CompletedProcess([], 0, json.dumps(reply), "") for reply in responses
    ]) as run:
        assert state.main(["restore", '["a", "b"]']) == 1
        assert run.call_count == 2
    output = capsys.readouterr()
    assert "confirmed running" not in output.out
    assert "incomplete" in output.err and "skipped safely" in output.err


@pytest.mark.parametrize("after", [{"plugins": []}, {"plugins": [plugin("a", False)]}, {}])
def test_unverified_load_does_not_claim_success(after, capsys):
    with mock.patch.object(state, "call_tool", side_effect=[{"plugins": []}, {}, after]) as calls:
        assert state.main(["restore", '["a", "b"]']) == 1
        assert calls.call_count == 3
    output = capsys.readouterr()
    assert "confirmed running" not in output.out
    assert "incomplete" in output.err


def test_snapshot_failure_emits_no_retained_set(capsys):
    with mock.patch.object(state, "call_tool", side_effect=state.UnknownState("unavailable")):
        assert state.main(["snapshot", "provider"]) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert "snapshot incomplete" in output.err


@pytest.mark.parametrize("previous", [None, {}, "a", [None], [1], [""]])
def test_malformed_retained_set_never_contacts_game(previous):
    with mock.patch.object(state, "call_tool") as calls:
        with pytest.raises(state.UnknownState):
            state.restore(previous)
        calls.assert_not_called()


def test_empty_retained_set_never_contacts_game():
    with mock.patch.object(state, "call_tool") as calls:
        state.restore([])
        calls.assert_not_called()


def test_shell_syntax_without_execution():
    # Parse stdin only; this neither invokes the build nor executes any commands.
    result = subprocess.run([shutil.which("bash"), "-n"],
                            input=(ROOT / "build.sh").read_text(),
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("mode,skip,capability,expected_calls", [
    ("release", "0", True, 0), ("dev", "1", True, 0),
    ("release-check", "1", True, 0), ("dev", "0", False, 0),
    ("release-check", "0", False, 0), ("dev", "0", True, 2),
    ("release-check", "0", True, 2),
])
def test_shell_guards_without_running_build(mode, skip, capability, expected_calls, tmp_path):
    # Execute only the guard/snapshot/restore function definitions with a fake
    # python3. No staging, build entry point, RemoteBuild or socket is invoked.
    source = (ROOT / "build.sh").read_text()
    functions = "can_reload() {" + source.split("can_reload() {", 1)[1].split("remote_load_folder()", 1)[0]
    fake_remote = "tm-remote-build() { :; }" if capability else ""
    script = f'''set -euo pipefail
{functions}
{fake_remote}
python3() {{ printf 'helper-called %s\\n' "$1" >&2; printf '[]\\n'; }}
mode="$1"
TM_PLUGIN_SKIP_RELOAD="$2"
plugin_name=provider
pack_plugins="$(snapshot_tool_pack_plugins)" || pack_plugins=""
restore_tool_pack_plugins
'''
    result = subprocess.run([shutil.which("bash"), "-c", script, "guard-test", mode, skip],
                            env={"PATH": str(tmp_path)}, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stderr.count("helper-called") == expected_calls
