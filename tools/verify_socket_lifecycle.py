#!/usr/bin/env python3
"""Live test: socket enable/disable/set + in-process export surface.

Requires Trackmania, tm-control-mcp, and tm-remote-build.

  python3 tools/verify_socket_lifecycle.py
  python3 tools/verify_socket_lifecycle.py --rb-host 10.100.1.3
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
FIXTURE = ROOT / "tools" / "fixtures" / "tm-mcp-socket-probe"
PLUGIN_ID = "tm-mcp-socket-probe"
OP_PLUGINS = Path.home() / "OpenplanetNext" / "Plugins"
STORAGE = Path.home() / "OpenplanetNext" / "PluginStorage"


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


def find_report() -> Path | None:
    matches = list(STORAGE.glob(f"**/{PLUGIN_ID}/**/socket-lifecycle.json"))
    matches += list(STORAGE.glob(f"**/{PLUGIN_ID}/socket-lifecycle.json"))
    return max(matches, key=lambda p: p.stat().st_mtime) if matches else None


def rb(args: argparse.Namespace, *cmd: str) -> subprocess.CompletedProcess:
    full = ["tm-remote-build", *cmd, "-op", "OpenplanetNext", "--host", args.rb_host]
    return subprocess.run(full, capture_output=True, text=True, timeout=90)


def install_fixture() -> None:
    dest = OP_PLUGINS / PLUGIN_ID
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(FIXTURE, dest)


def uninstall_fixture(args: argparse.Namespace) -> None:
    rb(args, "unload", PLUGIN_ID)
    dest = OP_PLUGINS / PLUGIN_ID
    if dest.exists():
        shutil.rmtree(dest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rb-host", default="10.100.1.3")
    parser.add_argument("--timeout", type=float, default=20.0)
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

    code, st = call("status")
    data = st.get("data") if isinstance(st, dict) else None
    sock = data.get("socket") if isinstance(data, dict) else {}
    if not isinstance(sock, dict):
        sock = {}
    ok("socket up", code == 0 and st.get("ok") is True)
    ok("listening at start", sock.get("listening") is True, str(sock.get("state")))

    code, r = call("SetPluginSetting", {"varName": "S_TmMcpHost", "value": "0.0.0.0", "save": False})
    ok("SetPluginSetting rejects non-loopback", result(r).get("success") is False)

    # wipe prior report
    old = find_report()
    if old and old.exists():
        old.unlink()

    install_fixture()
    loaded = rb(args, "load", "folder", PLUGIN_ID)
    ok("load export probe", loaded.returncode == 0, (loaded.stdout + loaded.stderr)[-120:])

    report_path = None
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        report_path = find_report()
        if report_path and report_path.is_file():
            break
        time.sleep(0.25)

    if report_path is None:
        ok("probe wrote report", False, "socket-lifecycle.json not found")
        report = {}
    else:
        report = json.loads(report_path.read_text())
        ok("probe wrote report", True, str(report_path))

    ok("exports stop/start ok", report.get("ok") is True, json.dumps({k: report.get(k) for k in ("stopOk", "startOk", "error")}))
    steps = {s.get("step"): s for s in report.get("steps") or [] if isinstance(s, dict)}
    stopped = steps.get("afterSetFalse") or {}
    started = steps.get("afterStart") or {}
    ok("SetSocketEnabled(false) stopped listener", stopped.get("isListeningFn") is False and stopped.get("enabled") is False)
    ok("StartSocket listening again", started.get("isListeningFn") is True and started.get("enabled") is True)

    # socket should be back for call.py
    st = {}
    for _ in range(10):
        code, st = call("status")
        if code == 0 and isinstance(st, dict) and st.get("ok"):
            break
        time.sleep(0.3)
    data = st.get("data") if isinstance(st, dict) else None
    sock = data.get("socket") if isinstance(data, dict) else {}
    if not isinstance(sock, dict):
        sock = {}
    ok("call.py status after export cycle", code == 0 and sock.get("listening") is True)

    uninstall_fixture(args)
    print("----")
    print(f"ad-hoc verification: {pass_n}/{pass_n + fail_n} passed")
    return 0 if fail_n == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
