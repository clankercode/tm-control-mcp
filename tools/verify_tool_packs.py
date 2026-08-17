#!/usr/bin/env python3
"""Live test: RegisterToolPack fixture Ping/Echo/GetMode.

Requires Trackmania, tm-control-mcp, tm-remote-build.

  python3 tools/verify_tool_packs.py
  python3 tools/verify_tool_packs.py --rb-host 10.100.1.3
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tools" / "fixtures" / "tm-mcp-pack-fixture"
PLUGIN_ID = "tm-mcp-pack-fixture"
PACK_ID = "fixture"
OP_PLUGINS = Path.home() / "OpenplanetNext" / "Plugins"


def call(tool: str, payload=None, timeout: float = 20.0):
    cmd = [sys.executable, str(ROOT / "tools" / "call.py"), tool]
    if payload is not None:
        cmd.append(json.dumps(payload))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    try:
        return r.returncode, json.loads(r.stdout or "{}")
    except Exception:
        return r.returncode, {"raw": r.stdout, "err": r.stderr}


def result(d):
    return ((d.get("data") or {}).get("result") or {})


def output(d):
    r = result(d)
    return r.get("output") or {}


def rb(host: str, *cmd: str) -> subprocess.CompletedProcess:
    full = ["tm-remote-build", *cmd, "-op", "OpenplanetNext", "--host", host]
    return subprocess.run(full, capture_output=True, text=True, timeout=90)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rb-host", default="10.100.1.3")
    parser.add_argument("--keep", action="store_true", help="leave fixture plugin installed")
    args = parser.parse_args()
    pass_n = fail_n = 0

    def ok(name: str, cond: bool, detail: str = "") -> None:
        nonlocal pass_n, fail_n
        if cond:
            pass_n += 1
            print(f"PASS {name}" + (f" — {detail}" if detail else ""))
        else:
            fail_n += 1
            print(f"FAIL {name}" + (f" — {detail}" if detail else ""))

    dest = OP_PLUGINS / PLUGIN_ID
    rb(args.rb_host, "unload", PLUGIN_ID)
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(FIXTURE, dest)

    loaded = rb(args.rb_host, "load", "folder", PLUGIN_ID)
    ok("fixture load", loaded.returncode == 0, (loaded.stdout + loaded.stderr)[-200:])
    time.sleep(1.5)

    _, packs = call("ListToolPacks")
    listed = output(packs).get("packs") or []
    ids = [p.get("id") for p in listed]
    fixture_row = next((p for p in listed if p.get("id") == PACK_ID), None)
    ok("ListToolPacks has custom pack id", PACK_ID in ids, json.dumps(output(packs))[:240])
    ok(
        "ListToolPacks plugin stays folder id",
        fixture_row is not None and fixture_row.get("plugin") == PLUGIN_ID,
        json.dumps(fixture_row)[:240],
    )

    _, ping = call(f"{PACK_ID}.Ping")
    ok("fixture.Ping", output(ping).get("pong") is True, json.dumps(result(ping))[:200])

    _, echo = call(f"{PACK_ID}.Echo", {"text": "hi"})
    ok("fixture.Echo", output(echo).get("text") == "hi", json.dumps(result(echo))[:200])

    _, mode = call(f"{PACK_ID}.GetMode")
    ok("fixture.GetMode wraps GetMode", isinstance(output(mode).get("mode"), str))

    _, raw = call("GetMode")
    ok("builtin GetMode still works", isinstance(output(raw).get("mode"), str))

    if not args.keep:
        rb(args.rb_host, "unload", PLUGIN_ID)
        time.sleep(0.5)
        _, after = call("ListToolPacks")
        after_ids = [p.get("id") for p in (output(after).get("packs") or [])]
        ok("fixture gone after unload", PACK_ID not in after_ids, json.dumps(output(after))[:240])
        if dest.exists():
            shutil.rmtree(dest)

    print("----")
    print(f"ad-hoc verification: {pass_n}/{pass_n + fail_n} passed")
    return 0 if fail_n == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
