#!/usr/bin/env python3
"""Black-box HTTP transport and monitor fallback gate; run on a build box."""
import argparse
import json
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from wire_smoke import Backend, META


def post(url, method, params, request_id=1, version="2026-07-28", session=None, origin=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "MCP-Protocol-Version": version}
    if version == "2026-07-28":
        params = {**params, "_meta": META}
        headers["Mcp-Method"] = method
        if "name" in params:
            headers["Mcp-Name"] = params["name"]
    if session:
        headers["Mcp-Session-Id"] = session
    if origin:
        headers["Origin"] = origin
    message = {"jsonrpc": "2.0", "method": method, "params": params}
    if request_id is not None:
        message["id"] = request_id
    request = urllib.request.Request(url, data=json.dumps(message).encode(), headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            raw = response.read().decode()
            if raw.startswith("event:") or raw.startswith("data:"):
                rows = [json.loads(payload) for line in raw.splitlines()
                        if line.startswith("data:")
                        for payload in [line[5:].strip()] if payload]
                result = next((row for row in rows if row.get("id") == request_id), {})
            else:
                result = json.loads(raw) if raw else {}
            return response.status, dict(response.headers), result
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read().decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    args = parser.parse_args()
    with Backend() as backend, tempfile.TemporaryDirectory() as temporary:
        threading.Thread(target=backend.serve_forever, daemon=True).start()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        events = Path(temporary) / "events.jsonl"
        process = subprocess.Popen([args.binary, "monitor", "--native-port", str(backend.server_address[1]),
            "--listen", f"127.0.0.1:{port}", "--events-jsonl", str(events), "--ascii"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        errors = []
        threading.Thread(target=lambda: errors.extend(process.stderr), daemon=True).start()
        url = f"http://127.0.0.1:{port}/mcp"
        try:
            deadline = time.monotonic() + 8
            while True:
                try:
                    status, _, discover = post(url, "server/discover", {})
                    break
                except OSError:
                    assert process.poll() is None, "".join(errors)
                    assert time.monotonic() < deadline, "HTTP listener did not start"
                    time.sleep(.05)
            assert status == 200 and discover["result"]["resultType"] == "complete", (status, discover)
            status, _, tools = post(url, "tools/list", {})
            assert status == 200 and tools["result"]["tools"][0]["name"] == "Echo", (status, tools)
            status, _, called = post(url, "tools/call", {"name": "Echo", "arguments": {"value": 8}})
            assert status == 200 and not called["result"].get("isError", False), (status, called)
            status, _, _ = post(url, "server/discover", {}, origin="https://example.invalid")
            assert status == 403, status
            for version in ("2025-11-25", "2025-06-18"):
                status, headers, initialized = post(url, "initialize", {"protocolVersion": version, "capabilities": {},
                    "clientInfo": {"name": "http-smoke", "version": "1"}}, version=version)
                assert status == 200 and initialized["result"]["protocolVersion"] == version, (status, initialized)
                session = next((value for key, value in headers.items() if key.lower() == "mcp-session-id"), None)
                assert session, headers
                status, _, _ = post(url, "notifications/initialized", {}, request_id=None, version=version, session=session)
                assert status in (200, 202, 204), status
                status, _, listed = post(url, "tools/list", {}, version=version, session=session)
                assert status == 200 and listed["result"]["tools"], (status, listed)
            print("PASS HTTP modern discover/list/call, both legacy sessions, Origin rejection, monitor headless fallback")
        finally:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            backend.shutdown()
        rows = [json.loads(line) for line in events.read_text().splitlines()]
        assert rows, "monitor persisted no metadata"
        assert all(not row.get("arguments") and not row.get("result") for row in rows), rows
        print("PASS monitor metadata persisted without payloads")


if __name__ == "__main__":
    main()
