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


def plugin(plugin_id, enabled=True, source="UserFolder", kind="Folder", path=None):
    basename = plugin_id + (".op" if kind == "Zip" else "")
    return {"id": plugin_id, "enabled": enabled, "source": source, "type": kind,
            "sourcePathBase": basename,
            "sourcePath": path or "/plugins/" + basename}


def pack(plugin_id, pack_id=None, enabled=True):
    return {"id": pack_id or plugin_id, "plugin": plugin_id, "enabled": enabled}


def retained(plugin_id, **kwargs):
    entry = plugin(plugin_id, **kwargs)
    del entry["enabled"]
    return {**entry, "packs": [plugin_id]}


@pytest.fixture
def clock(monkeypatch):
    class Clock:
        now = 0.0
        waits = []

        def sleep(self, seconds):
            assert 0 < seconds <= 0.1
            self.waits.append(seconds)
            self.now += seconds

    clock = Clock()
    monkeypatch.setattr(state.time, "monotonic", lambda: clock.now)
    monkeypatch.setattr(state.time, "sleep", clock.sleep)
    monkeypatch.setattr(state, "REGISTRATION_TIMEOUT", 0.3)
    return clock


class Bridge:
    """Script plugin/registry observations; record mutations independently."""
    def __init__(self, plugins, packs=(), load=None):
        self.plugins = list(plugins)
        self.packs = list(packs)
        self.loads = []
        self.observations = []
        self.load = load if load is not None else {
            "compile": {"loaded": True, "compileFailed": False, "errorCount": 0}}

    def __call__(self, tool, arguments, **kwargs):
        self.observations.append((tool, arguments, kwargs))
        if tool == "ControlPlugin":
            self.loads.append(arguments)
            if isinstance(self.load, Exception):
                raise self.load
            return self.load
        observations, key = ((self.plugins, "plugins") if tool == "ListPlugins"
                             else (self.packs, "packs"))
        assert observations, f"Unexpected {tool}"
        reply = observations.pop(0) if len(observations) > 1 else observations[0]
        return {key: reply}


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


def test_snapshot_retains_only_registered_enabled_consumers_and_all_pack_ids():
    bridge = Bridge(plugins=[[
        plugin("provider"), plugin("a"), plugin("b", kind="Zip", source="ApplicationFolder"),
        plugin("disabled", False), plugin("unrelated"),
    ]], packs=[[
        pack("provider"), pack("a", "a_one"), pack("a", "a_two"), pack("b"),
        pack("disabled"), pack("unrelated", enabled=False), pack("stale"),
    ]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        snapshot = state.snapshot("provider")
    assert snapshot == [
        {**retained("a"), "packs": ["a_one", "a_two"]},
        retained("b", kind="Zip", source="ApplicationFolder"),
    ]
    assert not bridge.loads
    assert bridge.observations[1][1] == {"includeDisabled": True, "includeSourcePath": True}


def test_restore_rechecks_peers_and_leaves_enabled_and_unrelated_alone(clock, capsys):
    both = [plugin("a"), plugin("b"), plugin("unrelated", False)]
    bridge = Bridge(plugins=[[plugin("unrelated", False)], both],
                    packs=[[pack("a"), pack("b")]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        state.restore([retained("a"), retained("b")])
    assert [load["id"] for load in bridge.loads] == ["a"]
    output = capsys.readouterr().out
    assert output.count("confirmed registered") == 2
    assert "running" not in output


@pytest.mark.parametrize("source,kind,path,expected_path", [
    ("ApplicationFolder", "Zip", "/application/Plugins/a.op", "/application/Plugins/a.op"),
    ("UserFolder", "Zip", "/user/Plugins/a.op", "/user/Plugins/a.op"),
    ("ApplicationFolder", "Folder", "C:\\Application\\Plugins\\a", "C:\\Application\\Plugins\\a/"),
    ("UserFolder", "Folder", "/user/Plugins/a", "/user/Plugins/a/"),
])
def test_exact_descriptor_load_prevents_source_and_folder_zip_collisions(
        source, kind, path, expected_path, clock):
    original = plugin("a", source=source, kind=kind, path=path)
    bridge = Bridge(plugins=[[], [original]], packs=[[pack("a")]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        state.restore([retained("a", source=source, kind=kind, path=path)])
    assert bridge.loads == [{"action": "load", "id": "a", "path": expected_path,
                             "source": source, "type": kind}]


@pytest.mark.parametrize("changed", [
    {"source": "ApplicationFolder"}, {"type": "Zip", "sourcePath": "/plugins/a.op",
                                       "sourcePathBase": "a.op"},
    {"sourcePath": "/other/Plugins/a"}, {"enabled": False},
])
def test_current_identity_mismatch_or_disabled_preserves_snapshot_and_never_loads(changed):
    previous = [retained("a"), retained("b")]
    saved = json.dumps(previous, sort_keys=True)
    bridge = Bridge(plugins=[[{**plugin("a"), **changed}]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        with pytest.raises(state.UnknownState):
            state.restore(previous)
    assert json.dumps(previous, sort_keys=True) == saved
    assert not bridge.loads


@pytest.mark.parametrize("report", [
    {"loaded": False, "compileFailed": True, "errorCount": 1},
    {"loaded": True, "compileFailed": True, "errorCount": 0},
    {"loaded": True, "compileFailed": False, "errorCount": 2},
    {"compileFailed": "false"}, {"errorCount": "0"}, {"errorCount": True},
    {"errorCount": -1}, None, [],
])
def test_failed_compile_even_with_enabled_placeholder_stops_before_next_load(report, capsys):
    bridge = Bridge(plugins=[[], [plugin("a")]], packs=[[pack("a")]],
                    load={"compile": report})
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        assert state.main(["restore", json.dumps([retained("a"), retained("b")])]) == 1
    assert [load["id"] for load in bridge.loads] == ["a"]
    assert [tool for tool, _, _ in bridge.observations] == ["ListPlugins", "ControlPlugin"]
    output = capsys.readouterr()
    assert "confirmed" not in output.out
    assert "incomplete" in output.err


@pytest.mark.parametrize("existing", [True, False])
def test_absent_registry_is_bounded_incomplete_and_never_loads_next_consumer(existing, clock, capsys):
    bridge = Bridge(plugins=[[plugin("a")]] if existing else [[], [plugin("a")]],
                    packs=[[]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        assert state.main(["restore", json.dumps([retained("a"), retained("b")])]) == 1
    assert [load["id"] for load in bridge.loads] == ([] if existing else ["a"])
    assert clock.now == pytest.approx(0.3)
    assert clock.waits
    output = capsys.readouterr()
    assert "confirmed" not in output.out
    assert "registration not confirmed" in output.err


@pytest.mark.parametrize("existing", [True, False])
def test_late_registration_waits_for_every_original_pack(existing, clock, capsys):
    descriptor = {**retained("a"), "packs": ["one", "two"]}
    bridge = Bridge(plugins=[[plugin("a")]] if existing else [[], [plugin("a")]],
                    packs=[[], [pack("a", "one")], [pack("a", "one"), pack("a", "two")]],
                    load={"compile": {"loaded": False, "compileFailed": False, "errorCount": 0}})
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        state.restore([descriptor])
    assert len(bridge.loads) == (0 if existing else 1)
    assert len(clock.waits) == 2
    assert "confirmed registered" in capsys.readouterr().out
    assert all(0 < kwargs["timeout"] <= 0.3 for tool, _, kwargs in bridge.observations
               if tool == "ListToolPacks")


@pytest.mark.parametrize("packs", [[pack("other", "a")], [pack("a", enabled=False)],
                                    [pack("a", "different")]])
def test_wrong_or_disabled_pack_never_confirms_registration(packs, clock):
    bridge = Bridge(plugins=[[plugin("a")]], packs=[packs])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        with pytest.raises(state.UnknownState):
            state.restore([retained("a"), retained("b")])
    assert not bridge.loads


def test_identity_change_while_waiting_stops_restoration(clock):
    bridge = Bridge(plugins=[[plugin("a")], [plugin("a", path="/other/a")]],
                    packs=[[pack("a")]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        with pytest.raises(state.UnknownState, match="identity changed"):
            state.restore([retained("a"), retained("b")])
    assert not bridge.loads


@pytest.mark.parametrize("reply", [{}, {"plugins": None}, {"plugins": [{}]},
                                    {"plugins": [plugin("a", False)]}])
def test_unknown_or_disabled_current_state_never_loads(reply):
    with mock.patch.object(state, "call_tool", return_value=reply) as calls:
        with pytest.raises(state.UnknownState):
            state.restore([retained("a")])
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
        assert state.main(["restore", json.dumps([retained("a"), retained("b")])]) == 1
        assert run.call_count == 2
    output = capsys.readouterr()
    assert "confirmed" not in output.out
    assert "incomplete" in output.err and "skipped safely" in output.err


@pytest.mark.parametrize("entries", [[pack("a"), pack("a")], [{"plugin": "a", "enabled": True}],
                                     [{**pack("a"), "id": 1}], [pack("a", "bad.id")]])
def test_malformed_pack_identities_fail_closed(entries):
    with mock.patch.object(state, "call_tool", return_value={"packs": entries}):
        with pytest.raises(state.UnknownState):
            state.snapshot("provider")


def test_snapshot_failure_emits_no_retained_set(capsys):
    with mock.patch.object(state, "call_tool", side_effect=state.UnknownState("unavailable")):
        assert state.main(["snapshot", "provider"]) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert "snapshot incomplete" in output.err


@pytest.mark.parametrize("previous", [None, {}, "a", [None], [1], [""], ["old-id"]])
def test_malformed_retained_set_never_contacts_game(previous):
    with mock.patch.object(state, "call_tool") as calls:
        with pytest.raises(state.UnknownState):
            state.restore(previous)
        calls.assert_not_called()


@pytest.mark.parametrize("change", [
    {"source": "Unknown"}, {"type": "Unknown"}, {"source": None},
    {"sourcePath": None}, {"sourcePath": "relative/a"},
    {"sourcePath": "/plugins/../a"}, {"sourcePathBase": "different"},
    {"id": ""}, {"id": 2}, {"id": "../a"}, {"id": "a/b"}, {"id": "a\\b"},
    {"id": "a:part"}, {"id": " a"}, {"id": "."},
    {"packs": []}, {"packs": "a"}, {"packs": [None]},
    {"packs": ["a", "a"]}, {"packs": ["bad.id"]},
])
def test_malformed_descriptor_anywhere_rejects_whole_set_without_contact(change):
    with mock.patch.object(state, "call_tool") as calls:
        with pytest.raises(state.UnknownState):
            state.restore([retained("valid"), {**retained("a"), **change}])
        calls.assert_not_called()


@pytest.mark.parametrize("missing", ["id", "source", "type", "sourcePath", "sourcePathBase", "packs"])
def test_missing_descriptor_fields_rejected_without_contact(missing):
    descriptor = retained("a")
    del descriptor[missing]
    with mock.patch.object(state, "call_tool") as calls:
        assert state.main(["restore", json.dumps([descriptor])]) == 1
        calls.assert_not_called()


def test_duplicate_retained_plugins_and_pack_owners_rejected_without_contact():
    for previous in ([retained("a"), retained("a")],
                     [retained("a"), {**retained("b"), "packs": ["a"]}]):
        with mock.patch.object(state, "call_tool") as calls:
            with pytest.raises(state.UnknownState):
                state.restore(previous)
            calls.assert_not_called()


def test_snapshot_missing_full_identity_emits_no_fallback_descriptor(capsys):
    current = plugin("a")
    del current["sourcePath"]
    bridge = Bridge(plugins=[[current]], packs=[[pack("a")]])
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        assert state.main(["snapshot", "provider"]) == 1
    assert not bridge.loads
    assert capsys.readouterr().out == ""


def test_folder_named_op_is_explicitly_loaded_as_folder(clock):
    bridge = Bridge(plugins=[[], [plugin("a.op")]], packs=[[pack("a.op", "custom")]])
    descriptor = {**retained("a.op"), "packs": ["custom"]}
    with mock.patch.object(state, "call_tool", side_effect=bridge):
        state.restore([descriptor])
    assert bridge.loads[0]["type"] == "Folder"
    assert bridge.loads[0]["path"] == "/plugins/a.op/"


def test_deadline_expires_during_observation_without_subsequent_load(clock, capsys):
    bridge = Bridge(plugins=[[plugin("a")]], packs=[[pack("a")]])

    def slow_registry(tool, arguments, **kwargs):
        reply = bridge(tool, arguments, **kwargs)
        if tool == "ListToolPacks":
            clock.now += kwargs["timeout"]
        return reply

    with mock.patch.object(state, "call_tool", side_effect=slow_registry):
        assert state.main(["restore", json.dumps([retained("a"), retained("b")])]) == 1
    assert not bridge.loads
    assert "confirmed" not in capsys.readouterr().out


def test_polling_client_timeout_is_bounded_and_stops_sequence(clock):
    process = subprocess.CompletedProcess([], 0, json.dumps(envelope({"plugins": [plugin("a")]})), "")
    with mock.patch.object(state.subprocess, "run", side_effect=[
        process, subprocess.TimeoutExpired("call", 0.3),
    ]) as run:
        assert state.main(["restore", json.dumps([retained("a"), retained("b")])]) == 1
    assert run.call_count == 2
    assert run.call_args.kwargs["timeout"] == pytest.approx(0.3)
    assert float(run.call_args.args[0][-1]) == pytest.approx(0.3)


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
