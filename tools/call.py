#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time


def is_trackmania_process(cmdline: bytes) -> bool:
    if not cmdline:
        return False
    argv0 = cmdline.split(b"\0", 1)[0].decode(errors="ignore")
    normalized = argv0.replace("\\", "/").lower()
    return normalized == "trackmania.exe" or normalized.endswith("/trackmania.exe")


def find_trackmania_pids() -> list[int]:
    pids: list[int] = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/cmdline", "rb") as f:
                cmdline = f.read()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if is_trackmania_process(cmdline):
            pids.append(int(name))
    return sorted(pids)


def print_json(payload: dict, pretty: bool) -> None:
    if pretty:
        print(json.dumps(payload, indent=2))
    else:
        print(json.dumps(payload, separators=(",", ":")))


def print_json_error(message: str, pretty: bool, **extra) -> None:
    payload = {"ok": False, "error": message}
    payload.update(extra)
    print_json(payload, pretty)


def screenshot_extension(input_data: object) -> str:
    if not isinstance(input_data, dict):
        return ".jpg"
    fmt = str(input_data.get("format", "jpg")).lower()
    if fmt == "jpeg":
        fmt = "jpg"
    if fmt not in {"jpg", "webp", "tga", "dds"}:
        fmt = "jpg"
    return f".{fmt}"


def user_game_folder() -> Path:
    configured = os.environ.get("TM_USER_GAME_FOLDER")
    if configured:
        return Path(configured).expanduser()
    return (
        Path.home()
        / ".local/share/Steam/steamapps/compatdata/2225070/pfx/drive_c/users/steamuser/Documents/Trackmania"
    )


def screenshot_candidates(extension: str) -> dict[str, tuple[float, int]]:
    root = user_game_folder()
    candidates: dict[str, tuple[float, int]] = {}
    for folder in (root, root / "ScreenShots"):
        if not folder.is_dir():
            continue
        for path in folder.glob(f"ScreenShot*{extension}"):
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            candidates[str(path)] = (stat.st_mtime, stat.st_size)
    return candidates


def find_new_screenshot(before: dict[str, tuple[float, int]], extension: str, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    latest: tuple[str, tuple[float, int]] | None = None
    while time.monotonic() <= deadline:
        after = screenshot_candidates(extension)
        changed = {
            path: meta
            for path, meta in after.items()
            if path not in before or before[path] != meta
        }
        if changed:
            latest = max(changed.items(), key=lambda item: item[1][0])
            break
        time.sleep(0.1)

    if latest is None:
        return {"detected": False, "linuxPath": "", "size": 0}

    path, (mtime, size) = latest
    return {"detected": True, "linuxPath": path, "mtime": mtime, "size": size}


def attach_screenshot_path(response: object, screenshot_info: dict) -> None:
    if not isinstance(response, dict):
        return
    data = response.get("data")
    if not isinstance(data, dict):
        return
    result = data.get("result")
    if not isinstance(result, dict):
        return
    output = result.get("output")
    if not isinstance(output, dict):
        return
    output["detectedScreenshot"] = screenshot_info


def main() -> int:
    parser = argparse.ArgumentParser(description="Call the TM Control MCP Openplanet plugin")
    parser.add_argument("route_or_tool", help="Route name or tool name")
    parser.add_argument("input_json", nargs="?", default="{}")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=30006)
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout in seconds")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON responses")
    parser.add_argument("--skip-process-check", action="store_true", help="Do not check for Trackmania.exe before connecting")
    args = parser.parse_args()

    try:
        input_data = json.loads(args.input_json)
    except json.JSONDecodeError as exc:
        print(f"invalid input JSON: {exc}", file=sys.stderr)
        return 2

    pids: list[int] = []
    if not args.skip_process_check:
        pids = find_trackmania_pids()
        if not pids:
            print_json_error(
                "Trackmania.exe process not found; the game may be crashed or not fully launched",
                args.pretty,
                hint="Start Trackmania/Openplanet before calling the MCP socket, or pass --skip-process-check for raw socket debugging.",
            )
            return 3

    if args.route_or_tool in {"status", "tools"}:
        request = {"route": args.route_or_tool}
    else:
        request = {"route": "call", "tool": args.route_or_tool, "input": input_data}

    screenshot_before: dict[str, tuple[float, int]] | None = None
    screenshot_ext = screenshot_extension(input_data)
    if args.route_or_tool == "TakeScreenshot":
        screenshot_before = screenshot_candidates(screenshot_ext)

    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
            sock.settimeout(args.timeout)
            request_bytes = (json.dumps(request, separators=(",", ":")) + "\n").encode()
            sock.sendall(request_bytes)
            sock.shutdown(socket.SHUT_WR)
            chunks: list[bytes] = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                if b"\n" in chunk:
                    break
    except (ConnectionRefusedError, TimeoutError, socket.timeout, OSError) as exc:
        print_json_error(
            f"Could not reach TM Control MCP at {args.host}:{args.port}: {exc}",
            args.pretty,
            trackmaniaPids=pids,
            hint="If Trackmania.exe is listed but the socket does not respond, Openplanet or the plugin may be frozen; restart the game or reload tm-control-mcp.",
        )
        return 4

    response_text = b"".join(chunks).decode().strip()
    if not response_text:
        print_json_error(
            f"TM Control MCP at {args.host}:{args.port} closed without a response",
            args.pretty,
            trackmaniaPids=pids,
            hint="The plugin may have errored or Openplanet may be mid-reload.",
        )
        return 5

    try:
        response = json.loads(response_text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        print_json_error(
            f"TM Control MCP at {args.host}:{args.port} returned an invalid response: {exc}",
            args.pretty,
            trackmaniaPids=pids,
            hint="If Trackmania.exe is listed but the socket reply is malformed, Openplanet or the plugin may be frozen or partially crashed.",
        )
        return 6

    if screenshot_before is not None:
        attach_screenshot_path(response, find_new_screenshot(screenshot_before, screenshot_ext, args.timeout))

    print_json(response, args.pretty)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
