"""Read-only live socket regression; opt in with TM_MCP_LIVE_TESTS=1."""
import json
import os
import socket
import time
import pytest

pytestmark = pytest.mark.skipif(os.environ.get("TM_MCP_LIVE_TESTS") != "1", reason="requires running TM Control MCP")


def request(payload, split=None):
    with socket.create_connection(("127.0.0.1", 30006), timeout=10) as sock:
        sock.settimeout(10)
        if split:
            sock.sendall(payload[:split])
            time.sleep(0.25)  # more than the old three quiet-frame cutoff
            sock.sendall(payload[split:])
        else:
            sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        result = bytearray()
        while b"\n" not in result:
            chunk = sock.recv(65536)
            if not chunk:
                break
            result.extend(chunk)
    return json.loads(result)


@pytest.mark.parametrize("size", [4000, 24000, 180000])
def test_large_complete_request_reaches_read_only_route(size):
    payload = json.dumps({"route": "status", "probe": "x" * size}, separators=(",", ":")).encode() + b"\n"
    response = request(payload)
    assert response["ok"] is True, response
    assert response["route"] == "status"


def test_delayed_fragment_is_not_treated_as_complete_json():
    payload = json.dumps({"route": "status", "probe": "x" * 8000}).encode() + b"\n"
    response = request(payload, split=1000)
    assert response["ok"] is True, response


def test_utf8_identifier_split_across_read_boundary_round_trips():
    # Put the first multi-byte character across the new 1024-byte read boundary.
    identifier = "é😀"
    padding = 0
    while True:
        payload = json.dumps({"route": "status", "probe": "x" * padding, "id": identifier}, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        if payload.index(identifier.encode()) % 1024 == 1023:
            break
        padding += 1
    response = request(payload)
    assert response["ok"] is True, response
    assert response["id"] == identifier


def test_legacy_eof_without_newline_still_works():
    response = request(b'{"route":"status"}')
    assert response["ok"] is True, response
