#!/usr/bin/env python3
import argparse
import json
import socket
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Call the TM Control MCP Openplanet plugin")
    parser.add_argument("route_or_tool", help="Route name or tool name")
    parser.add_argument("input_json", nargs="?", default="{}")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=30006)
    args = parser.parse_args()

    try:
        input_data = json.loads(args.input_json)
    except json.JSONDecodeError as exc:
        print(f"invalid input JSON: {exc}", file=sys.stderr)
        return 2

    if args.route_or_tool in {"status", "tools"}:
        request = {"route": args.route_or_tool}
    else:
        request = {"route": "call", "tool": args.route_or_tool, "input": input_data}

    with socket.create_connection((args.host, args.port), timeout=5.0) as sock:
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

    print(json.dumps(json.loads(b"".join(chunks).decode().strip()), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
