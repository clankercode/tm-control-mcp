#!/usr/bin/env python3
"""FocusCamera conformance test.

For several (start_pos, focus_target, distance) combinations:
  1. Seed the camera at a known start configuration.
  2. Call FocusCamera to focus on `focus_target` at `distance`.
  3. Wait for the animation to complete.
  4. Verify the resulting camera's look direction points at `focus_target`,
     and the camera sits at `distance` from it.

The look direction is reconstructed from the game's convention, validated by
tests/test_camera_math.py:
    look_dir(h, v) = (cos(v)*sin(h), -sin(v), cos(v)*cos(h))

If the plugin computes incorrect (h, v) when focusing, the reconstructed look
direction won't align with (focus_target - cam_pos), and the test fails.

Run: python3 tests/test_focus_camera.py
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
ANIMATION_WAIT_S = 3.0  # covers the animation plus slack

ANGLE_TOL_DEG = 2.0
DIST_TOL_M = 1.5


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


def set_camera(target, h_rad, v_rad, dist):
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


def focus_camera(target, dist):
    return tool_output(
        call(
            "FocusCamera",
            {"x": target[0], "y": target[1], "z": target[2], "distance": dist},
        )
    )


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_len(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def vec_norm(a):
    n = vec_len(a)
    if n < 1e-9:
        return (0.0, 0.0, 0.0)
    return (a[0] / n, a[1] / n, a[2] / n)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def look_dir_from_angles(h, v):
    return (
        math.cos(v) * math.sin(h),
        -math.sin(v),
        math.cos(v) * math.cos(h),
    )


@dataclass
class Case:
    label: str
    start_target: tuple
    start_h: float
    start_v: float
    start_dist: float
    focus_target: tuple
    focus_dist: float


# Pick start positions and focus targets that exercise a range of directions
# (positive/negative X/Z, up/down elevation differences).
CASES = [
    Case(
        "focus forward-+X",
        start_target=(400.0, 200.0, 400.0),
        start_h=0.0,
        start_v=0.0,
        start_dist=120.0,
        focus_target=(600.0, 210.0, 400.0),
        focus_dist=80.0,
    ),
    Case(
        "focus back +Z",
        start_target=(512.0, 200.0, 400.0),
        start_h=math.pi / 2,
        start_v=0.3,
        start_dist=100.0,
        focus_target=(512.0, 220.0, 650.0),
        focus_dist=70.0,
    ),
    Case(
        "focus look-up-steep",
        start_target=(500.0, 80.0, 500.0),
        start_h=math.pi / 4,
        start_v=0.0,
        start_dist=150.0,
        focus_target=(500.0, 220.0, 500.0),
        focus_dist=90.0,
    ),
    Case(
        "focus diag up-+X+Z",
        start_target=(300.0, 90.0, 300.0),
        start_h=-math.pi / 3,
        start_v=-0.2,
        start_dist=110.0,
        focus_target=(700.0, 210.0, 650.0),
        focus_dist=120.0,
    ),
    Case(
        "focus diag down-+X-Z",
        start_target=(700.0, 230.0, 700.0),
        start_h=math.pi,
        start_v=0.1,
        start_dist=90.0,
        focus_target=(500.0, 90.0, 350.0),
        focus_dist=100.0,
    ),
]


def fmt_vec(v):
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
    header = (
        f"{'case':22} {'dir err (deg)':>13} {'dist err (m)':>12} "
        f"{'expected look':30} {'reconstructed look':30}"
    )
    print(header)
    print("-" * len(header))

    try:
        for case in CASES:
            # 1) seed
            set_camera(case.start_target, case.start_h, case.start_v, case.start_dist)
            time.sleep(0.3)
            seed_cam = get_camera()
            # 2) focus
            focus_camera(case.focus_target, case.focus_dist)
            # 3) wait for animation
            time.sleep(ANIMATION_WAIT_S)
            # 4) read back
            cam = get_camera()
            pos = tuple(cam["position"])
            h = float(cam["hAngle"])
            v = float(cam["vAngle"])
            dist = float(cam["distance"])

            expected = vec_norm(vec_sub(case.focus_target, pos))
            reconstructed = look_dir_from_angles(h, v)
            cos_angle = max(-1.0, min(1.0, dot(expected, reconstructed)))
            dir_err_deg = math.degrees(math.acos(cos_angle))
            dist_err = abs(dist - case.focus_dist)

            ok_dir = dir_err_deg <= ANGLE_TOL_DEG
            ok_dist = dist_err <= DIST_TOL_M
            status = "OK  " if ok_dir and ok_dist else "FAIL"
            if not (ok_dir and ok_dist):
                fails += 1
            actual_dist = vec_len(vec_sub(case.focus_target, pos))
            orbital_dist = float(cam.get("orbitalDistance", -1))
            target_rb = tuple(cam.get("target", (0, 0, 0)))
            print(
                f"{status} {case.label:17} {dir_err_deg:13.2f} {dist_err:12.2f} "
                f"{fmt_vec(expected):30} {fmt_vec(reconstructed):30} "
                f"h={h:+.4f} v={v:+.4f} reqDist={case.focus_dist:.1f} pmtDist={dist:.2f} "
                f"orbDist={orbital_dist:.2f} actualDist={actual_dist:.2f} "
                f"targetRB={fmt_vec(target_rb)} endPos={fmt_vec(pos)}"
            )
    finally:
        try:
            set_camera(orig_target, orig_h, orig_v, orig_dist)
        except Exception as exc:
            print(f"warning: failed to restore original camera: {exc}", file=sys.stderr)

    print("-" * len(header))
    print(
        f"{len(CASES) - fails}/{len(CASES)} cases within "
        f"{ANGLE_TOL_DEG} deg / {DIST_TOL_M} m"
    )
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
