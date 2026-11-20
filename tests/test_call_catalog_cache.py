"""Schema cache must follow the live endpoint, instance and revision."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import call as client


def identity(instance="a", revision="1"):
    return {"schemaVersion": 1, "instance": instance, "revision": revision}


@pytest.fixture
def backend(tmp_path, monkeypatch):
    monkeypatch.setattr(client, "CACHE_PATH", tmp_path / "schemas.json")
    state = {"identity": identity(), "tools": [{"name": "Tool", "input_schema": {"properties": {}}}], "routes": []}

    def send(host, port, timeout, request):
        state["routes"].append((host, port, request["route"]))
        if request["route"] == "status":
            return {"ok": True, "data": {"catalog": state["identity"]}}
        if request["route"] == "tools":
            return {"ok": True, "data": state["tools"]}
        assert request["route"] == "catalog"
        return {"ok": True, "data": {**state["identity"], "tools": state["tools"]}}

    monkeypatch.setattr(client, "send_request", send)
    return state


def fetch(host="localhost", port=30006):
    return client.load_schemas(host, port, 1, False)


def test_cache_hit_still_checks_status(backend):
    fetch()
    backend["routes"].clear()
    assert "Tool" in fetch()
    assert [route[2] for route in backend["routes"]] == ["status"]


@pytest.mark.parametrize("changed", [identity(revision="2"), identity(instance="b")])
def test_changed_identity_replaces_snapshot(backend, changed):
    fetch()
    backend["identity"] = changed
    backend["tools"] = [{"name": "Added", "input_schema": {}}]
    assert set(fetch()) == {"Added"}


@pytest.mark.parametrize("host,port", [("other", 30006), ("localhost", 30007)])
def test_cache_never_crosses_endpoints(backend, host, port):
    fetch()
    backend["tools"] = [{"name": "Other", "input_schema": {}}]
    assert set(fetch(host, port)) == {"Other"}


def test_unavailable_backend_never_uses_disk_cache(backend, monkeypatch):
    fetch()
    def unavailable(*args):
        raise ConnectionRefusedError("offline")
    monkeypatch.setattr(client, "send_request", unavailable)
    with pytest.raises(ConnectionRefusedError):
        fetch()


def test_legacy_bridge_refetches_tools_each_time(backend):
    backend["identity"] = None
    fetch()
    backend["tools"] = [{"name": "Added", "input_schema": {}}]
    assert set(fetch()) == {"Added"}
    assert [r[2] for r in backend["routes"]] == ["status", "tools", "status", "tools"]


def test_rejection_forces_one_refresh_before_dispatch(monkeypatch):
    calls = []
    def load(host, port, timeout, refresh):
        calls.append(refresh)
        return {"Tool": {"properties": {"new": {"type": "string"}} if refresh else {}}}
    monkeypatch.setattr(client, "load_schemas", load)
    schema, error = client.preflight_schema("localhost", 30006, 1, False, "Tool", {"new": "ok"})
    assert not error
    assert "new" in schema["properties"]
    assert calls == [False, True]


def test_added_tool_gets_one_preflight_refresh(monkeypatch):
    calls = []
    def load(host, port, timeout, refresh):
        calls.append(refresh)
        return {"Added": {}} if refresh else {}
    monkeypatch.setattr(client, "load_schemas", load)
    assert client.preflight_schema("localhost", 30006, 1, False, "Added", {}) == ({}, "")
    assert calls == [False, True]


def test_malformed_and_legacy_cache_are_replaced(backend):
    client.CACHE_PATH.write_text('{"Tool":{}}')
    assert "Tool" in fetch()
    client.CACHE_PATH.write_text("broken")
    assert "Tool" in fetch()
