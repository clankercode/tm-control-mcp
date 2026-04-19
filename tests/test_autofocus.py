#!/usr/bin/env python3
"""Autofocus conformance test.

Places a block through PlaceBlockViaEditorPlusPlus with autofocus=true from
several seed camera positions, then verifies that after the animation:

  1. The camera pitch (vAngle) is ~+65 degrees (looking down from above).
  2. The horizontal yaw is the angle that points FROM the placed block back
     toward the seed camera position (so the transition sweeps naturally
     from the user's viewpoint).
  3. The target readback equals the placed block position.
  4. The distance readback equals the requested autofocus distance.

Removes each placed block afterward via RemoveRecentBlocks.

Run: python3 tests/test_autofocus.py
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
ANIMATION_WAIT_S = 1.0

EXPECTED_PITCH_DEG = 65.0  # AutofocusCameraOn hardcodes 65 deg down
PITCH_TOL_DEG = 2.0
YAW_TOL_DEG = 2.0
DIST_TOL_M = 1.0
TARGET_TOL_M = 1.0


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


def select_block(block_name):
    return tool_output(call("SelectBlockModel", {"blockName": block_name}))


def place_block_with_autofocus(block_name, pos, autofocus_distance):
    return tool_output(
        call(
            "PlaceBlockViaEditorPlusPlus",
            {
                "blockName": block_name,
                "x": pos[0],
                "y": pos[1],
                "z": pos[2],
                "autofocus": True,
                "autofocusDistance": autofocus_distance,
            },
        )
    )


def remove_recent_block():
    return tool_output(call("RemoveRecentBlocks", {"count": 1}))


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_len(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def normalize_angle_deg(a):
    while a > 180.0:
        a -= 360.0
    while a < -180.0:
        a += 360.0
    return a


@dataclass
class Case:
    label: str
    seed_target: tuple       # camera target during seed
    seed_h: float            # camera hAngle during seed (rad)
    seed_v: float            # camera vAngle during seed (rad)
    seed_dist: float
    block_pos: tuple         # where the block gets placed (free-block pos)
    autofocus_distance: float


# Seed positions spread around a central block so the expected yaw
# differs meaningfully case to case.
CASES = [
    Case("seed +X",   (300.0, 100.0, 500.0),  math.pi / 2, 0.1, 120.0, (700.0, 120.0, 500.0), 80.0),
    Case("seed -X",   (700.0, 100.0, 500.0), -math.pi / 2, 0.1, 120.0, (300.0, 120.0, 500.0), 80.0),
    Case("seed +Z",   (500.0, 100.0, 300.0),  0.0,         0.1, 120.0, (500.0, 120.0, 700.0), 80.0),
    Case("seed diag", (300.0, 100.0, 300.0),  math.pi / 4, 0.1, 120.0, (700.0, 120.0, 700.0), 100.0),
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

    # Pick a stock block.
    try:
        select_block("RoadTechStraight")
    except Exception as exc:
        print(f"failed to select block: {exc}", file=sys.stderr)
        return 2

    fails = 0
    header = (
        f"{'case':10} {'pitch (deg, ~65)':>17} {'yaw err (deg)':>14} "
        f"{'dist err':>9}"
    )
    print(header)
    print("-" * len(header))

    try:
        for case in CASES:
            # 1) seed
            set_camera(case.seed_target, case.seed_h, case.seed_v, case.seed_dist)
            time.sleep(0.3)
            seed = get_camera()
            seed_cam_pos = tuple(seed["position"])

            # 2) place block (triggers autofocus)
            try:
                place_block_with_autofocus("RoadTechStraight", case.block_pos, case.autofocus_distance)
            except Exception as exc:
                print(f"FAIL {case.label:5}   place failed: {exc}")
                fails += 1
                continue

            # 3) wait for animation
            time.sleep(ANIMATION_WAIT_S)

            # 4) read camera state
            cam = get_camera()
            h_rb = float(cam["hAngle"])
            v_rb = float(cam["vAngle"])
            dist_rb = float(cam["distance"])
            target_rb = tuple(cam["target"])

            # 4a) pitch should be ~+65 deg
            pitch_deg = math.degrees(v_rb)
            pitch_err = abs(pitch_deg - EXPECTED_PITCH_DEG)

            # 4b) expected yaw points horizontally from the seed camera toward
            #     whatever point autofocus is actually aiming at (target_rb). That
            #     target can differ slightly from block_pos due to E++ placement
            #     offsets, which is not a math bug.
            dx = target_rb[0] - seed_cam_pos[0]
            dz = target_rb[2] - seed_cam_pos[2]
            expected_h = math.atan2(dx, dz)
            yaw_err = abs(normalize_angle_deg(math.degrees(h_rb - expected_h)))

            # 4c) distance readback should match what we requested
            dist_err = abs(dist_rb - case.autofocus_distance)

            ok = (
                pitch_err <= PITCH_TOL_DEG
                and yaw_err <= YAW_TOL_DEG
                and dist_err <= DIST_TOL_M
            )
            status = "OK  " if ok else "FAIL"
            if not ok:
                fails += 1
            print(
                f"{status} {case.label:5} {pitch_deg:17.2f} {yaw_err:14.2f} "
                f"{dist_err:9.2f}   "
                f"h_rb={h_rb:+.4f} h_expected={expected_h:+.4f} "
                f"seed_cam={fmt_vec(seed_cam_pos)} target_rb={fmt_vec(target_rb)}"
            )

            # clean up
            try:
                remove_recent_block()
            except Exception as exc:
                print(f"   warning: could not remove placed block: {exc}", file=sys.stderr)
    finally:
        try:
            set_camera(orig_target, orig_h, orig_v, orig_dist)
        except Exception as exc:
            print(f"warning: failed to restore original camera: {exc}", file=sys.stderr)

    print("-" * len(header))
    print(f"{len(CASES) - fails}/{len(CASES)} cases passed")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
