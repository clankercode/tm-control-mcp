#!/usr/bin/env python3
"""Live smoke: readiness → tag → place → assert → RemoveByTag.

Requires Trackmania + tm-control-mcp loaded. Exit 0 on full pass.

  python3 tools/smoke_tag_cleanup.py
  python3 tools/smoke_tag_cleanup.py --port 30006 --timeout 45
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import call as call_mod  # noqa: E402


def dig(d, *ks, default=None):
    cur = d
    for k in ks:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k, default)
    return cur


def tool_out(resp: dict) -> dict:
    out = call_mod.tool_result_output(resp)
    if isinstance(out, dict):
        return out
    return dig(resp, "data", "result", "output") or dig(resp, "data", "result") or {}


def tool_ok(resp: dict) -> bool:
    if not isinstance(resp, dict) or resp.get("ok") is False:
        return False
    r = dig(resp, "data", "result")
    if isinstance(r, dict) and r.get("success") is False:
        return False
    return True


def call_tool(host: str, port: int, timeout: float, tool: str, payload: dict | None = None) -> dict:
    return call_mod.send_request(
        host,
        port,
        timeout,
        {"route": "call", "tool": tool, "input": payload or {}},
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=30006)
    ap.add_argument("--timeout", type=float, default=5.0, help="per-request socket timeout")
    ap.add_argument("--wait-budget", type=float, default=45.0, help="seconds for editor readiness")
    ap.add_argument("--item-path", default="LightCube2m")
    ap.add_argument("--x", type=float, default=512.0)
    ap.add_argument("--y", type=float, default=80.0)
    ap.add_argument("--z", type=float, default=512.0)
    ap.add_argument("--skip-process-check", action="store_true")
    args = ap.parse_args()

    if not args.skip_process_check and not call_mod.find_trackmania_pids():
        print("FAIL  Trackmania.exe not running (use --skip-process-check to force)")
        return 2

    tag = f"smoke:{uuid.uuid4().hex[:10]}"
    steps: list[tuple[str, bool, str]] = []

    def step(name: str, cond: bool, detail: str = "") -> None:
        steps.append((name, cond, detail))
        print(("PASS" if cond else "FAIL") + f"  {name}" + (f" — {detail}" if detail else ""))

    # 1) readiness
    ready_resp = call_mod.wait_until_ready(
        args.host, args.port, args.timeout, "editor", args.wait_budget
    )
    rout = tool_out(ready_resp)
    ready = tool_ok(ready_resp) and (
        rout.get("ready") is True
        or rout.get("ok") is True
        or dig(ready_resp, "data", "result", "output", "ready") is True
    )
    # WaitUntil may nest readiness under output
    if not ready and isinstance(rout, dict):
        nested = rout.get("readiness")
        if isinstance(nested, dict):
            ready = nested.get("ready") is True or nested.get("mode") == "Editor"
        elif rout.get("mode") == "Editor":
            ready = True
    step("wait_until_ready editor", ready, json.dumps(rout)[:140])

    def call(tool: str, payload: dict | None = None) -> dict:
        return call_tool(args.host, args.port, args.timeout, tool, payload)

    # 2) tag
    r = call("SetAgentTag", {"tag": tag})
    step("SetAgentTag", tool_ok(r), tag)

    # 3) place
    place = call(
        "PlaceItemViaEditorPlusPlus",
        {
            "itemPath": args.item_path,
            "x": args.x,
            "y": args.y,
            "z": args.z,
            "yaw": 15,
            "autofocus": False,
        },
    )
    pout = tool_out(place)
    placed = tool_ok(place)
    step("PlaceItemViaEditorPlusPlus", placed, json.dumps(pout)[:160])

    time.sleep(0.4)

    # 4) assert
    assertion = call(
        "AssertPlacement",
        {
            "expectItemsDelta": 1,
            "near": {"x": args.x, "y": args.y, "z": args.z, "radius": 8},
            "itemPath": args.item_path,
            "tag": tag,
            "tagMinCount": 1,
        },
    )
    aout = tool_out(assertion)
    # AssertPlacement returns ok/passed style fields
    assert_pass = tool_ok(assertion) and aout.get("ok") is not False and aout.get("passed") is not False
    if "failed" in aout and aout.get("failed"):
        assert_pass = False
    step("AssertPlacement", assert_pass, json.dumps(aout)[:160])

    # 5) list tagged
    listed = call("ListTagged", {"tag": tag})
    lout = tool_out(listed)
    items = lout.get("items") or lout.get("tagged") or lout.get("entries") or []
    count = lout.get("count")
    if count is None:
        count = len(items) if isinstance(items, list) else 0
    step("ListTagged", tool_ok(listed) and int(count) >= 1, f"count={count}")

    # 6) remove
    removed = call("RemoveByTag", {"tag": tag, "addUndo": True})
    rout2 = tool_out(removed)
    step("RemoveByTag", tool_ok(removed), json.dumps(rout2)[:160])

    time.sleep(0.3)

    # 7) empty index for tag
    listed2 = call("ListTagged", {"tag": tag})
    l2 = tool_out(listed2)
    items2 = l2.get("items") or l2.get("tagged") or l2.get("entries") or []
    count2 = l2.get("count")
    if count2 is None:
        count2 = len(items2) if isinstance(items2, list) else 0
    step("ListTagged after cleanup", tool_ok(listed2) and int(count2) == 0, f"count={count2}")

    call("SetAgentTag", {"tag": ""})

    failed = [n for n, c, _ in steps if not c]
    print("----")
    print(f"smoke_tag_cleanup: {len(steps) - len(failed)}/{len(steps)} passed  tag={tag}")
    if failed:
        print("failed:", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
