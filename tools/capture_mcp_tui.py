#!/usr/bin/env python3
"""Capture actual Alacritty pixels using MCP HTTP and a deterministic TCP fixture.

Requires Python 3 (stdlib only), Alacritty, xdotool, ImageMagick import, and the
isolating-gui-runs isolated-run wrapper (Xvfb + private session bus/runtime).
Pass --isolated-run PATH, put isolated-run on PATH, or invoke this script inside
that wrapper. No Cargo commands or live game connections are made.

Example: python3 tools/capture_mcp_tui.py --binary /tmp/tm-control-mcp \
    --output /tmp/tui-wide --commit REV --isolated-run /path/to/isolated-run
Use --columns 80 --rows 24 --details-key Tab for a UI with narrow-view switching.
"""

import argparse
import concurrent.futures
import contextlib
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import urllib.request


PROTOCOL = "2026-07-28"
PACK_TOOL = "tm-mcp-pack-epp.SummarizeMap"
TOOLS = ("GetMode", "GetReadiness", "ControlCamera", "GetEditorSelectionState",
         "ListToolPacks", "GetCursor", "GetLightmapComputeState", PACK_TOOL,
         "ControlInventory", "ControlPlugin")
SHOTS = ("live.png", "error.png", "paused.png", "scrollback.png", "filter.png",
         "empty.png", "detail-scroll.png")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def isolated_environment():
    """Check the wrapper's private runtime, bus, display, and owning Xvfb.

    A DISPLAY value or an environment marker alone is insufficient: verify that
    the X server's stdout is the log inside this particular private runtime.
    """
    try:
        runtime = Path(os.environ["XDG_RUNTIME_DIR"])
        display = os.environ["DISPLAY"]
        info = runtime.lstat()
        if (not re.fullmatch(r"/tmp/isolated-run\.[\w-]+", str(runtime))
                or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o700
                or not re.fullmatch(r":\d+", display)
                or (runtime / "displayfd").read_text().strip() != display[1:]
                or os.environ.get("DBUS_SESSION_BUS_ADDRESS") != f"unix:path={runtime}/bus"
                or not stat.S_ISSOCK((runtime / "bus").stat().st_mode)
                or os.environ.get("WAYLAND_SOCKET")):
            return False
        wayland = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        if (runtime / wayland).exists() or (runtime / "wayland-0").exists():
            return False
        # Xvfb -displayfd does not necessarily create /tmp/.XN-lock.
        for entry in Path("/proc").glob("[0-9]*/comm"):
            try:
                if (entry.read_text().strip() == "Xvfb"
                        and (entry.parent / "fd/1").resolve() == runtime / "xvfb.log"
                        and b"-displayfd\x003\x00" in (entry.parent / "cmdline").read_bytes()):
                    return True
            except OSError:
                continue
        return False
    except (OSError, KeyError, ValueError):
        return False


def descendants(pid):
    children = {}
    for entry in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = entry.read_text().rsplit(")", 1)[1].split()
            children.setdefault(int(fields[1]), []).append(int(entry.parent.name))
        except (OSError, ValueError, IndexError):
            continue
    found = [pid]
    for parent in found:
        found.extend(children.get(parent, ()))
    return found


def stop_tree(process):
    # The monitor gets its own PTY session; killpg(Alacritty) alone misses it.
    pids = descendants(process.pid)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in reversed(pids):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, sig)
        try:
            process.wait(timeout=0.8)
        except subprocess.TimeoutExpired:
            pass


@contextlib.contextmanager
def managed_process(command, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        yield process
    finally:
        stop_tree(process)


class Fixture(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = []
        self.failures = []
        super().__init__(("127.0.0.1", 0), NativeHandler)

    def reply(self, request):
        identity = {"schemaVersion": 1, "instance": "tui-capture-fixture", "revision": "1"}
        route = request["route"]
        if route == "status":
            return {"alive": True, "catalog": identity}
        if route == "catalog":
            return {**identity, "tools": [
                {"name": name, "description": "Screenshot fixture: " + name,
                 "pack": "fixture", "generation": "1",
                 "input_schema": {"type": "object", "additionalProperties": True}}
                for name in TOOLS]}
        require(route == "call", f"Unexpected native route: {route}")
        tool = request["tool"]
        require(tool in TOOLS, f"Unexpected fixture tool: {tool}")
        self.calls.append(tool)
        if tool == PACK_TOOL:
            self.started.set()
            require(self.release.wait(15), "Long fixture call was never released")
            output = {
                "blocks": 384, "items": 27, "mapName": "Monitor capture — 日本語 🚗 é",
                "rows": [{"index": i, "label": f"区間 {i:02d} — café 🚗",
                          "description": "Wrapped Unicode payload: 雪道 / café / é / 🚗. " * 3}
                         for i in range(24)],
                "zzFinalWrappedLine": "END OF UNICODE FIXTURE — 最後の行 🚗 é"}
        else:
            time.sleep(0.015)
            output = {
                "GetMode": {"mode": "MapEditor"},
                "GetReadiness": {"mode": "MapEditor", "editorReady": True, "dialogOpen": False},
                "ControlCamera": {"position": {"x": 128, "y": 64, "z": 256}, "changed": True},
                "GetEditorSelectionState": {"blocks": 12, "items": 2},
                "ListToolPacks": {"packs": ["builtin", "tm-mcp-pack-epp"]},
                "GetCursor": {"position": {"x": 8, "y": 1, "z": 12}},
                "GetLightmapComputeState": {"running": False, "shadowsClear": True},
            }.get(tool, {})
        result = {"success": True, "output": output}
        if tool == "ControlInventory":
            result = {"success": False, "code": "item_not_found",
                      "error": "Fixture item is not present in the current inventory"}
        elif tool == "ControlPlugin":
            result = {"success": False, "code": "tool_busy", "retryable": True,
                      "error": "bridge reload requires idle dispatch"}
        return {"tool": tool, "result": result}

    @contextlib.contextmanager
    def running(self):
        thread = threading.Thread(target=self.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        try:
            yield self
        finally:
            self.release.set()
            self.shutdown()
            self.server_close()
            thread.join(timeout=1)


class NativeHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self.connection.settimeout(3)
            request = json.loads(self.rfile.readline(1024 * 1024))
            data = self.server.reply(request)
            response = {"id": request["id"], "route": request["route"],
                        "ok": True, "error": "", "data": data}
            self.wfile.write((json.dumps(response, ensure_ascii=False) + "\n").encode())
        except Exception as error:
            self.server.failures.append(str(error))


class McpClient:
    def __init__(self, port):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.sequence = itertools.count(1)
        # Never send these requests through a user's HTTP proxy.
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def post(self, method, params=None):
        sequence = next(self.sequence)
        params = {**(params or {}), "_meta": {
            "io.modelcontextprotocol/protocolVersion": PROTOCOL,
            "io.modelcontextprotocol/clientCapabilities": {}}}
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": PROTOCOL, "Mcp-Method": method}
        if "name" in params:
            headers["Mcp-Name"] = params["name"]
        request = urllib.request.Request(self.url, headers=headers, data=json.dumps({
            "jsonrpc": "2.0", "id": sequence, "method": method, "params": params}).encode())
        with self.http.open(request, timeout=18) as response:
            payload = response.read().decode()
        messages = [json.loads(line[5:]) for line in payload.splitlines() if line.startswith("data:")]
        reply = next((item for item in messages if item.get("id") == sequence), None) if messages else json.loads(payload)
        require(reply is not None and reply.get("id") == sequence and "result" in reply,
                f"Invalid MCP response: {reply}")
        return reply["result"]

    def call(self, name, arguments=None, error=False):
        result = self.post("tools/call", {"name": name, "arguments": arguments or {}})
        require(bool(result.get("isError")) == error, f"Unexpected tool result: {result}")
        return result


def run(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=5).strip()


def wait_for(check, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {description}")


def terminal_size(process, binary):
    for pid in descendants(process.pid)[1:]:
        try:
            if Path(f"/proc/{pid}/exe").resolve() == binary:
                with open(f"/proc/{pid}/fd/0", "rb", buffering=0) as tty:
                    rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(tty, termios.TIOCGWINSZ, bytes(8)))
                return {"columns": columns, "rows": rows}
        except (OSError, ValueError):
            continue
    return None


def png_dimensions(path):
    with path.open("rb") as image:
        header = image.read(24)
    require(header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", f"Invalid PNG: {path}")
    width, height = struct.unpack(">II", header[16:24])
    require(width > 0 and height > 0, f"Empty PNG: {path}")
    return {"width": width, "height": height}


def configuration(columns, rows):
    return f'''[window]
dimensions = {{ columns = {columns}, lines = {rows} }}
padding = {{ x = 14, y = 14 }}
decorations = "None"
[font]
normal = {{ family = "JetBrains Mono", style = "Regular" }}
size = 12.0
[colors.primary]
background = "#0b111b"
foreground = "#d7e1ee"
[colors.normal]
black = "#111a27"
red = "#ff6f81"
green = "#5fe2a0"
yellow = "#f7c96b"
blue = "#7aa2f7"
magenta = "#bd9cff"
cyan = "#63d6ff"
white = "#d7e1ee"
'''


def capture(args, scratch):
    require(isolated_environment(), "Refusing GUI capture outside a private isolated-run Xvfb/session bus/runtime")
    started = time.monotonic()
    with args.binary.open("rb") as binary:
        binary_sha = hashlib.file_digest(binary, "sha256").hexdigest()
    config = scratch / "alacritty.toml"
    config.write_text(configuration(args.columns, args.rows))
    events = scratch / "events.jsonl"
    screenshots = {}
    with Fixture().running() as fixture:
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        client = McpClient(port)
        command = [str(args.binary), "monitor", "--native-host", "127.0.0.1",
                   "--native-port", str(fixture.server_address[1]), "--listen", f"127.0.0.1:{port}",
                   "--poll-ms", "500", "--events-jsonl", str(events)]
        if args.ascii:
            command.append("--ascii")
        terminal_env = os.environ.copy()
        terminal_env.pop("WAYLAND_DISPLAY", None)
        terminal_env.pop("WAYLAND_SOCKET", None)
        terminal_env["WINIT_X11_SCALE_FACTOR"] = "1"
        window_class = f"TmMcpCapture{os.getpid()}"
        with (scratch / "terminal.log").open("w") as log, managed_process([
            "alacritty", "--config-file", str(config), "--class", window_class,
            "--title", "MCP monitor capture", "-e", *command
        ], stdout=log, stderr=log, env=terminal_env) as terminal:
            def ready():
                require(terminal.poll() is None, "Alacritty exited: " + (scratch / "terminal.log").read_text())
                try:
                    result = client.post("server/discover")
                except OSError:
                    return False
                require(result.get("resultType") == "complete", f"Discovery failed: {result}")
                return True

            wait_for(ready, 10, "MCP HTTP discovery")
            catalog = client.post("tools/list")
            require(set(TOOLS) <= {tool["name"] for tool in catalog["tools"]}, "Fixture tools absent from MCP catalog")
            size = wait_for(lambda: terminal_size(terminal, args.binary), 3, "monitor PTY")
            require(size == {"columns": args.columns, "rows": args.rows}, f"Unexpected terminal dimensions: {size}")

            def find_window():
                try:
                    return run("xdotool", "search", "--onlyvisible", "--class", f"^{window_class}$").splitlines()[-1]
                except (subprocess.CalledProcessError, IndexError):
                    return None

            window = wait_for(find_window, 3, "Alacritty window")

            def focus():
                run("xdotool", "windowfocus", "--sync", window)
                require(run("xdotool", "getwindowfocus") == window, "Sandbox window did not receive focus")

            def key(*keys):
                focus()
                # No --window: Alacritty ignores XSendEvent. Focus + XTest works.
                run("xdotool", "key", "--clearmodifiers", *keys)
                time.sleep(0.16)

            def text(value):
                focus()
                run("xdotool", "type", "--clearmodifiers", "--delay", "5", "--", value)
                time.sleep(0.16)

            def shot(name, state):
                time.sleep(0.25)
                require(terminal.poll() is None, "Terminal exited before capture")
                run("import", "-window", window, str(scratch / name))
                screenshots[name] = {"pixels": png_dimensions(scratch / name),
                                     "fixtureCalls": len(fixture.calls), "requestedState": state}
                print(f"Captured {name}", flush=True)

            for name in TOOLS[:7]:
                client.call(name, {"want": "editor"} if name == "GetReadiness" else {})
            # Always release before executor shutdown, including when import/key fails.
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(client.call, PACK_TOOL, {"blocks": True, "items": True, "maxRows": 24})
                try:
                    require(fixture.started.wait(3), "Long call never reached native fixture")
                    shot("live.png", "LIVE, following an active long pack call")
                    require(not pending.done() and not fixture.release.is_set(), "Long call completed before live capture")
                finally:
                    fixture.release.set()
                pending.result(timeout=3)
            if args.details_key:
                key(args.details_key)
                shot("details.png", "Narrow details view, completed long Unicode pack result")
            key(*(["bracketright"] * 100))
            shot("detail-scroll.png", "Details scrolled towards final wrapped Unicode JSON lines")
            key(*(["bracketleft"] * 100))
            if args.details_key:
                key(args.details_key)
            client.call("ControlInventory", {"action": "select", "path": "Fixture/Missing.Item.Gbx"}, error=True)
            client.call("ControlPlugin", {"action": "reload", "plugin": "tm-control-mcp"}, error=True)
            shot("error.png", "LIVE, following native tool_busy error envelope")
            key("slash")
            text("status:error")
            key("Return", "p")
            shot("paused.png", "PAUSED with applied status:error filter")
            key("p", "c")
            for _ in range(55):
                client.call("GetReadiness", {"want": "editor"})
            require(len(fixture.calls) == 65, f"Expected 65 native tool calls, got {len(fixture.calls)}")
            key("Prior", "Prior")
            shot("scrollback.png", "History after 65 tool calls and two PageUp keys")
            key("slash")
            text("GetReadiness")
            shot("filter.png", "Filter input editing GetReadiness")
            key(*(["BackSpace"] * len("GetReadiness")))
            text("no-such-fixture-tool")
            key("Return")
            shot("empty.png", "Applied no-match filter; empty matching history")
            key("q")
            terminal.wait(timeout=3)
            require(terminal.returncode == 0, f"Monitor exit status: {terminal.returncode}")
        require(not fixture.failures, f"Native fixture failures: {fixture.failures}")
        records = [json.loads(line) for line in events.read_text().splitlines()]
        completed = [row for row in records if row.get("ended_ms", 0) > 0]
        require(len(completed) == 65, f"Expected 65 completed telemetry events, got {len(completed)}")
        require(sum(row["status"] == "tool_error" for row in completed) == 2, "Missing error telemetry")
    with args.binary.open("rb") as binary:
        require(hashlib.file_digest(binary, "sha256").hexdigest() == binary_sha, "Binary changed during capture")
    return {"binary": str(args.binary), "binarySha256": binary_sha, "commit": args.commit,
            "dimensions": size, "ascii": args.ascii, "command": command,
            "terminal": "Alacritty / JetBrains Mono 12 pt", "fontconfigFile": os.environ.get("FONTCONFIG_FILE"),
            "capture": "Direct X11 terminal window pixels via ImageMagick import; XTest keyboard input",
            "fixture": {"disclosure": "Real MCP HTTP to a deterministic loopback native bridge fixture; no live game",
                        "nativeAddress": f"127.0.0.1:{fixture.server_address[1]}",
                        "httpAddress": f"127.0.0.1:{port}", "toolCalls": 65, "errors": 2,
                        "completedTelemetryEvents": len(completed), "activeCallAtLiveCapture": PACK_TOOL},
            "screenshots": screenshots, "elapsedSeconds": round(time.monotonic() - started, 2)}


def output_names(args):
    return (*SHOTS, *(("details.png",) if args.details_key else ()), "capture.json")


def check_output(args):
    require(not args.output.exists() or args.output.is_dir(), "--output must be a directory")
    existing = [name for name in output_names(args) if (args.output / name).exists() or (args.output / name).is_symlink()]
    require(args.overwrite or not existing, "Refusing to overwrite " + ", ".join(existing) + "; use --overwrite")


def interrupted(signum, _frame):
    raise InterruptedError(f"Capture interrupted by signal {signum}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, type=lambda value: Path(value).expanduser().resolve())
    parser.add_argument("--output", required=True, type=lambda value: Path(value).expanduser().absolute())
    parser.add_argument("--columns", type=int, default=164)
    parser.add_argument("--rows", type=int, default=46)
    parser.add_argument("--ascii", action="store_true")
    parser.add_argument("--commit", help="Optional caller-supplied binary provenance; never inferred from this checkout")
    parser.add_argument("--overwrite", action="store_true", help="Replace this harness's artifacts only")
    parser.add_argument("--isolated-run", type=Path, help="Path to the isolating-gui-runs Xvfb wrapper")
    parser.add_argument("--details-key", choices=("Tab",), help="Optional narrow UI details toggle")
    parser.add_argument("--_inside", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    require(args.binary.is_file() and os.access(args.binary, os.X_OK), "--binary must be an executable file")
    require(1 <= args.columns <= 400 and 1 <= args.rows <= 150, "Dimensions must be 1..400 columns and 1..150 rows")
    check_output(args)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if not isolated_environment():
        require(not args._inside, "Isolation wrapper did not provide a private Xvfb/session bus/runtime")
        wrapper = args.isolated_run or shutil.which("isolated-run")
        require(wrapper is not None, "Run inside isolated-run, or supply --isolated-run PATH; refusing desktop GUI")
        wrapper = Path(wrapper).expanduser().resolve()
        require(wrapper.is_file() and os.access(wrapper, os.X_OK), "--isolated-run must be executable")
        # Deliberately generous screen; the actual terminal dimensions come from
        # Alacritty and are independently verified against its child's PTY.
        command = [str(wrapper), "--size", f"{max(1280, args.columns * 12 + 64)}x{max(800, args.rows * 26 + 64)}x24"]
        if os.environ.get("FONTCONFIG_FILE"):
            command.extend(["--env", "FONTCONFIG_FILE=" + os.environ["FONTCONFIG_FILE"]])
        command.extend(["--", sys.executable, "-B", str(Path(__file__).resolve()),
                        *(argv if argv is not None else sys.argv[1:]), "--_inside"])
        with managed_process(command) as child:
            return child.wait(timeout=51)
    for tool in ("alacritty", "xdotool", "import"):
        require(shutil.which(tool), f"Missing executable: {tool}")
    # Signals unwind context managers, releasing the long call and cleaning the
    # terminal tree, fixture, and temporary files on failure as well as success.
    signal.signal(signal.SIGALRM, interrupted)
    signal.alarm(46)
    try:
        with tempfile.TemporaryDirectory(prefix="tm-mcp-tui-") as directory:
            scratch = Path(directory)
            metadata = capture(args, scratch)
            (scratch / "capture.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")
            check_output(args)
            args.output.mkdir(parents=True, exist_ok=True)
            for name in output_names(args):
                with (scratch / name).open("rb") as source, (args.output / name).open("wb" if args.overwrite else "xb") as target:
                    shutil.copyfileobj(source, target)
            print(f"Capture receipt: {args.output / 'capture.json'}", flush=True)
    finally:
        signal.alarm(0)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"capture_mcp_tui: {error}", file=sys.stderr)
        sys.exit(1)
