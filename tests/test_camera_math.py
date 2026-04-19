#!/usr/bin/env python3
"""Camera-math conformance tests.

For a series of known (target, hAngle, vAngle, distance) configurations, set
the editor camera via MCP, then compare the measured orbital camera position
to a predicted position derived from a hypothesised orbital-camera convention.
When a test fails the script prints the predicted and actual positions side
by side so the true convention can be figured out.

Requires Trackmania in the map editor with tm-control-mcp running on
127.0.0.1:30006.

Run: python3 tests/test_camera_math.py
"""
from __future__ import annotations

import json
import math
import socket
import sys
import time
from dataclasses import dataclass

HOST = "127.0.0.1"
PORT = 30006
TIMEOUT = 5.0
SETTLE_SECONDS = 0.30  # let the orbital camera catch up to the written angles

TARGET = (512.0, 200.0, 512.0)
DIST = 120.0
POS_TOL_M = 1.0  # meters


def call(tool: str, inp: dict | None = None) -> dict:
    req = {"route": "call", "tool": tool, "input": inp or {}}
    with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as sock:
        sock.sendall((json.dumps(req, separators=(",", ":")) + "\n").encode())
        sock.shutdown(socket.SHUT_WR)
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode().strip())


def tool_output(resp: dict) -> dict:
    if not resp.get("ok", False):
        raise RuntimeError(f"MCP error: {resp}")
    return resp["data"]["result"]["output"]


def get_camera() -> dict:
    return tool_output(call("GetEditorCamera"))


def set_camera_rad(target, h_rad, v_rad, dist) -> dict:
    return tool_output(
        call(
            "SetEditorCamera",
            {
                "x": target[0],
                "y": target[1],
                "z": target[2],
                "hAngleRad": h_rad,
                "vAngleRad": v_rad,
                "distance": dist,
            },
        )
    )


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_len(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def vec_dist(a, b):
    return vec_len(vec_sub(a, b))


# ---------------------------------------------------------------------------
# Hypothesis: standard Y-up orbital camera where the camera sits on the
# opposite side of the target from the look direction.
#
#   look_dir(h, v) = (cos(v) * sin(h), -sin(v), cos(v) * cos(h))
#   cam_pos        = target - dist * look_dir
#
# h=0, v=0 puts the camera at target + (0, 0, -dist) looking in +Z.
# ---------------------------------------------------------------------------
def predict_pos(target, h_rad, v_rad, dist):
    lx = math.cos(v_rad) * math.sin(h_rad)
    ly = -math.sin(v_rad)
    lz = math.cos(v_rad) * math.cos(h_rad)
    return (
        target[0] - dist * lx,
        target[1] - dist * ly,
        target[2] - dist * lz,
    )


@dataclass
class Case:
    label: str
    h_rad: float
    v_rad: float


CASES = [
    Case("h=0     v=0",        0.0,             0.0),
    Case("h=+90   v=0",        math.pi / 2,     0.0),
    Case("h=-90   v=0",       -math.pi / 2,     0.0),
    Case("h=180   v=0",        math.pi,         0.0),
    Case("h=0     v=+45",      0.0,             math.pi / 4),
    Case("h=0     v=-45",      0.0,            -math.pi / 4),
    Case("h=+45   v=+30",      math.pi / 4,     math.pi / 6),
    Case("h=-135  v=+60",     -3 * math.pi / 4, math.pi / 3),
]


def fmt_vec(v) -> str:
    return f"({v[0]:8.2f}, {v[1]:8.2f}, {v[2]:8.2f})"


def main() -> int:
    try:
        original = get_camera()
    except Exception as exc:
        print(f"could not reach MCP / not in editor: {exc}", file=sys.stderr)
        return 2

    orig_target = tuple(original["target"])
    orig_dist = float(original["distance"])
    orig_h = float(original["hAngle"])
    orig_v = float(original["vAngle"])

    fails = 0
    print(f"{'case':14} {'predicted pos':30} {'actual pos':30} {'err (m)':>9}  readback (h,v rad)")
    print("-" * 120)
    try:
        for case in CASES:
            set_camera_rad(TARGET, case.h_rad, case.v_rad, DIST)
            time.sleep(SETTLE_SECONDS)
            cam = get_camera()
            actual = tuple(cam.get("position", cam.get("orbitalTarget", (0, 0, 0))))
            predicted = predict_pos(TARGET, case.h_rad, case.v_rad, DIST)
            err = vec_dist(actual, predicted)
            status = "OK  " if err <= POS_TOL_M else "FAIL"
            if err > POS_TOL_M:
                fails += 1
            print(
                f"{status} {case.label:10} {fmt_vec(predicted):30} {fmt_vec(actual):30} {err:8.2f}  "
                f"h={float(cam['hAngle']):+.4f} v={float(cam['vAngle']):+.4f}"
            )
    finally:
        # best-effort restore
        try:
            set_camera_rad(orig_target, orig_h, orig_v, orig_dist)
        except Exception as exc:
            print(f"warning: failed to restore original camera: {exc}", file=sys.stderr)

    print("-" * 120)
    print(f"{len(CASES) - fails}/{len(CASES)} cases matched within {POS_TOL_M} m")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
