#!/usr/bin/env python3
"""Black-box protocol gate. Run the built binary on a build box, no game needed."""
import argparse
import contextlib
import copy
import json
import queue
import socketserver
import subprocess
import threading
import time


META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}


class Backend(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.revision = 1
        self.tools = [self.tool("Echo")]
        self.calls = []

    @staticmethod
    def tool(name, field="value", kind="integer"):
        return {"name": name, "description": "wire fixture", "pack": "fixture",
                "generation": "1", "input_schema": {"type": "object", "properties": {
                    field: {"type": kind}}, "required": [field], "additionalProperties": False}}

    def change(self, tools):
        with self.lock:
            self.tools = tools
            self.revision += 1


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline(16 * 1024 * 1024))
        with self.server.lock:
            identity = {"schemaVersion": 1, "instance": "wire-fixture", "revision": str(self.server.revision)}
            route = request["route"]
            if route == "status":
                data = {"alive": True, "catalog": identity}
            elif route == "catalog":
                data = {**identity, "tools": copy.deepcopy(self.server.tools)}
            elif route == "call":
                self.server.calls.append(request)
                result = {"success": True, "output": request["input"]}
                if request["input"].get("value") == -1:
                    result = {"success": False, "error": "fixture error", "code": "fixture_error"}
                data = {"tool": request["tool"], "result": result}
            else:
                raise AssertionError(route)
        self.wfile.write((json.dumps({"ok": True, "route": route, "error": "", "data": data}) + "\n").encode())


class Client:
    def __init__(self, binary, port):
        self.process = subprocess.Popen([binary, "--native-port", str(port), "--poll-ms", "100"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.messages = queue.Queue()
        self.stderr = []
        self.pending = []
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: self.stderr.extend(self.process.stderr), daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except Exception as error:
                self.messages.put({"invalid_stdout": line, "error": str(error)})

    def send(self, method, params=None, modern=True, notification=False):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "method": method}
        if not notification:
            request["id"] = self.sequence
        if params is not None or modern:
            request["params"] = dict(params or {})
            if modern:
                request["params"]["_meta"] = META
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        return self.sequence

    def receive(self, predicate, seconds=8):
        for index, message in enumerate(self.pending):
            if predicate(message):
                return self.pending.pop(index)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            assert "invalid_stdout" not in message, message
            if predicate(message):
                return message
            self.pending.append(message)
        raise AssertionError(f"wire timeout; pending={self.pending}; stderr={''.join(self.stderr)}; exit={self.process.poll()}")

    def request(self, method, params=None, modern=True):
        request_id = self.send(method, params, modern)
        return self.receive(lambda message: message.get("id") == request_id)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)


@contextlib.contextmanager
def client(binary, backend):
    value = Client(binary, backend.server_address[1])
    try:
        yield value
    finally:
        value.close()


def names(result):
    return {tool["name"] for tool in result["result"]["tools"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    args = parser.parse_args()
    with Backend() as backend:
        threading.Thread(target=backend.serve_forever, daemon=True).start()
        with client(args.binary, backend) as modern:
            discovery = modern.request("server/discover")["result"]
            assert discovery["resultType"] == "complete", discovery
            assert "2026-07-28" in discovery["supportedVersions"], discovery
            assert discovery["capabilities"]["tools"]["listChanged"], discovery
            listed = modern.request("tools/list")
            assert names(listed) == {"Echo"}, listed
            assert listed["result"]["cacheScope"] in ("private", "public")
            assert isinstance(listed["result"]["ttlMs"], (float, int))
            called = modern.request("tools/call", {"name": "Echo", "arguments": {"value": 7}})["result"]
            assert not called.get("isError", False), called
            assert called["structuredContent"]["result"]["output"]["value"] == 7, called
            with backend.lock:
                assert backend.calls[-1]["expect"] == {"instance": "wire-fixture", "generation": "1"}, backend.calls
                previous = len(backend.calls)
            invalid = modern.request("tools/call", {"name": "Echo", "arguments": {"value": 1.5}})
            assert invalid["result"]["isError"], invalid
            with backend.lock:
                assert len(backend.calls) == previous, "invalid input reached native dispatcher"
            failure = modern.request("tools/call", {"name": "Echo", "arguments": {"value": -1}})
            assert failure["result"]["isError"], failure
            subscription_id = modern.send("subscriptions/listen", {"notifications": {"toolsListChanged": True}})
            ack = modern.receive(lambda message: message.get("method") == "notifications/subscriptions/acknowledged")
            assert ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription_id, ack
            for tools in ([backend.tool("Echo"), backend.tool("Added")],
                          [backend.tool("Echo", "changed", "string")], []):
                backend.change(tools)
                notification = modern.receive(lambda message: message.get("method") == "notifications/tools/list_changed")
                assert notification["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription_id, notification
                current = modern.request("tools/list")
                assert names(current) == {tool["name"] for tool in tools}, current
                if len(tools) == 1:
                    assert current["result"]["tools"][0]["inputSchema"] == tools[0]["input_schema"]
            print("PASS modern discovery, call/error mapping, generation guard, schema validation, subscription ack, addition/removal/replacement")
        for version in ("2025-11-25", "2025-06-18"):
            backend.change([backend.tool("Echo")])
            with client(args.binary, backend) as legacy:
                initialized = legacy.request("initialize", {"protocolVersion": version, "capabilities": {},
                    "clientInfo": {"name": "wire-smoke", "version": "1"}}, modern=False)
                assert initialized["result"]["protocolVersion"] == version, initialized
                legacy.send("notifications/initialized", modern=False, notification=True)
                assert names(legacy.request("tools/list", modern=False)) == {"Echo"}
                called = legacy.request("tools/call", {"name": "Echo", "arguments": {"value": 3}}, modern=False)
                assert not called["result"].get("isError", False), called
                print(f"PASS legacy {version} initialize/list/call")
        backend.shutdown()


if __name__ == "__main__":
    main()
