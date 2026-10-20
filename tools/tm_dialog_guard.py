#!/usr/bin/env python3
"""Cancel only identified BasicDialogs FrameAskYesNo confirmation dialogs.

One shot prints CLEAR only after a successful inspection. Other dialogs are
left alone and reported as blocked. Ordinary ActiveMenus pages are not dialogs.
--watch repeats this policy until stopped; transport/tool/unknown-state errors
stop the guard with a nonzero exit status. Stop the guard before intentional
saves: it cancels every identified FrameAskYesNo, regardless of prompt text.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
import time


CALL = [sys.executable, str(Path(__file__).resolve().with_name("call.py"))]
DEFAULT_CALL_TIMEOUT = 20.0


class HelperError(RuntimeError):
    """The bridge failed or could not establish the requested state."""


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def call(tool, payload, timeout=DEFAULT_CALL_TIMEOUT):
    """Run the sibling client with a deadline; return a validated tool output."""
    try:
        proc = subprocess.run(
            CALL + [tool, json.dumps(payload, allow_nan=False)],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise HelperError(f"{tool}: client failed: {exc}") from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()[:300]
        raise HelperError(f"{tool}: client exited {proc.returncode}: {detail}")
    try:
        reply = json.loads(proc.stdout)
    except (ValueError, TypeError) as exc:
        raise HelperError(f"{tool}: client returned malformed JSON") from exc
    if not isinstance(reply, dict) or reply.get("ok") is not True or reply.get("error"):
        raise HelperError(f"{tool}: bridge failure: {reply!r}")
    data = reply.get("data")
    result = data.get("result") if isinstance(data, dict) else None
    if not isinstance(result, dict) or result.get("success") is not True or result.get("error"):
        raise HelperError(f"{tool}: tool failure: {result!r}")
    output = result.get("output")
    if not isinstance(output, dict) or output.get("error"):
        raise HelperError(f"{tool}: missing or failed output")
    return output


def dialog_state(output):
    """Return clear/confirm/blocked; unknown data is always an error."""
    if not isinstance(output, dict) or output.get("available") is not True:
        raise HelperError("dialog state unavailable")
    has_frame = output.get("hasFrame")
    kind = output.get("dialogKind")
    if type(has_frame) is not bool or kind not in ("none", "message", "wait"):
        raise HelperError("malformed dialog state")
    frame = output.get("frameIdName", "")
    if not isinstance(frame, str) or (has_frame and not frame) or (not has_frame and frame):
        raise HelperError("inconsistent dialog frame identity")
    if has_frame and frame == "FrameAskYesNo":
        return "confirm"
    if has_frame or kind != "none":
        return "blocked"

    # RespondDialog.cancel targets BasicDialogs, so a menu-only modal must
    # remain blocked. Never interpret a normal menu page as a confirmation.
    menus = output.get("activeMenus", [])
    if not isinstance(menus, list):
        raise HelperError("malformed menu frame state")
    for menu in menus:
        if not isinstance(menu, dict):
            raise HelperError("malformed menu frame entry")
        name = menu.get("frameIdName", "")
        if not isinstance(name, str):
            raise HelperError("malformed menu frame identity")
        if name == "FrameAskYesNo" or name.startswith("FrameDialog"):
            return "blocked"
    return "clear"


def dismiss_once(dialog, timeout=DEFAULT_CALL_TIMEOUT):
    if dialog_state(dialog) != "confirm":
        raise HelperError("refusing to cancel an unidentified confirmation")
    output = call("RespondDialog", {"action": "cancel"}, timeout=timeout)
    if output.get("responded") is not True or output.get("action") != "cancel":
        raise HelperError("confirmation cancellation was not acknowledged")
    if dialog_state(output.get("before")) != "confirm":
        raise HelperError("dialog changed before cancellation; state is unknown")
    # The tool yields a frame before reporting after. A success envelope alone
    # does not prove cancellation cleared a dialog.
    return dialog_state(output.get("after")) == "clear"


def clear_dialogs(max_rounds=5, settle=0.8, timeout=DEFAULT_CALL_TIMEOUT):
    """Cancel at most max_rounds confirmations, then confirm a clear snapshot."""
    for attempt in range(max_rounds + 1):
        dialog = call("GetDialog", {}, timeout=timeout)
        state = dialog_state(dialog)
        if state == "clear":
            return True
        if state == "blocked" or attempt == max_rounds:
            return False
        dismiss_once(dialog, timeout=timeout)
        if settle:
            time.sleep(settle)
    return False


def watch(interval=2.0, timeout=DEFAULT_CALL_TIMEOUT):
    print(f"[guard] watching every {interval}s; cancels BasicDialogs FrameAskYesNo", flush=True)
    while True:
        if not clear_dialogs(timeout=timeout):
            raise HelperError("dialog remains blocked; left untouched")
        time.sleep(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true", help="repeat until stopped or an error occurs")
    parser.add_argument("--interval", type=positive_seconds, default=2.0)
    parser.add_argument("--call-timeout", type=positive_seconds, default=DEFAULT_CALL_TIMEOUT,
                        help="deadline in seconds for each call.py subprocess")
    args = parser.parse_args(argv)
    try:
        if args.watch:
            watch(args.interval, args.call_timeout)
            return 0
        ok = clear_dialogs(timeout=args.call_timeout)
        print("CLEAR" if ok else "STILL_BLOCKED")
        return 0 if ok else 1
    except HelperError as exc:
        print(f"[guard] ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
