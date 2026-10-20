#!/usr/bin/env python3
"""Clear confirmations, optionally aim the editor camera, and capture a new shot.

Example: tm_shot.py --target 32,11,40 --distance 12 --vangle -25 --hangle 170
--screenshot-dir (or TM_SCREENSHOT_DIR) maps the game's screenshot folder to
a host directory. It is read only: TakeScreenshot chooses where the game writes.
With no directory configured, use call.py's detected host path when available,
otherwise the game-side path from a confirmed native capture. Never return a
previous screenshot when a capture times out.
"""
import argparse
import math
import os
from pathlib import Path
import sys
import time

from tm_dialog_guard import HelperError, call, clear_dialogs, positive_seconds


def finite_number(value):
    number = float(value)
    if not math.isfinite(number):
        raise argparse.ArgumentTypeError("must be finite")
    return number


def nonnegative_seconds(value):
    number = finite_number(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return number


def target_position(value):
    try:
        values = [finite_number(part) for part in value.split(",")]
    except (ValueError, argparse.ArgumentTypeError) as exc:
        raise argparse.ArgumentTypeError("target must be three finite numbers: x,y,z") from exc
    if len(values) != 3:
        raise argparse.ArgumentTypeError("target must be three finite numbers: x,y,z")
    return dict(zip(("x", "y", "z"), values))


def file_stamp(path):
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    if not path.is_file() or stat.st_size <= 0:
        return None
    return (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)


def snapshot(folder):
    if not folder.is_dir():
        raise HelperError("screenshot directory does not exist or is not a directory")
    return {path: file_stamp(path) for path in folder.iterdir() if path.is_file()}


def capture_path(output, folder=None, before=None, timeout=5.0):
    """Require native freshness evidence and, when mapped, a changed host file."""
    if output.get("timedOut") or output.get("pollError"):
        raise HelperError("TakeScreenshot timed out or failed while polling")
    name = output.get("fullName")
    size = output.get("sizeBytes")
    if (output.get("requested") is not True or output.get("detected") is not True
            or not isinstance(name, str) or not name.strip()
            or type(size) is not int or size <= 0
            or name == output.get("fullNameBefore")):
        raise HelperError("TakeScreenshot did not confirm a new nonempty screenshot")
    # Native detection compares ScreenShotFullName with its pre-capture value
    # and checks file existence/size. No 'out' parameter exists on this tool.
    basename = name.replace("\\", "/").rsplit("/", 1)[-1]
    if not basename or basename in (".", ".."):
        raise HelperError("TakeScreenshot returned an invalid filename")
    if folder is not None:
        if not isinstance(before, dict):
            raise HelperError("mapped capture requires a pre-capture file snapshot")
        candidate = folder / basename
        deadline = time.monotonic() + timeout
        while True:
            stamp = file_stamp(candidate)
            if stamp is not None and stamp[-1] == size and stamp != before.get(candidate):
                return candidate
            if time.monotonic() >= deadline:
                raise HelperError("no new screenshot appeared in the configured directory")
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))

    detected = output.get("detectedScreenshot")
    if isinstance(detected, dict) and detected.get("detected") is True:
        host_name = detected.get("linuxPath")
        if not isinstance(host_name, str) or not host_name:
            raise HelperError("client reported a capture without a host path")
        candidate = Path(host_name)
        stamp = file_stamp(candidate)
        if candidate.name != basename or stamp is None or stamp[-1] != size:
            raise HelperError("client screenshot path does not match the confirmed capture")
        return candidate
    return name


def take_shot(args):
    # Validate the mapping before any dialog/camera actions. No directories or
    # files are created by this wrapper.
    folder = Path(args.screenshot_dir).expanduser().resolve() if args.screenshot_dir else None
    if folder is not None and not folder.is_dir():
        raise HelperError("screenshot directory does not exist or is not a directory")
    if not clear_dialogs(timeout=args.call_timeout):
        raise HelperError("dialog guard is blocked; screenshot aborted")
    if args.target:
        call("SetEditorOrbitalTarget", args.target, timeout=args.call_timeout)
    camera = {}
    for option, field in (("distance", "distance"), ("vangle", "vAngle"), ("hangle", "hAngle")):
        value = getattr(args, option)
        if value is not None:
            camera[field] = value
    if camera:
        call("SetEditorCamera", camera, timeout=args.call_timeout)
    if args.target or camera:
        time.sleep(args.settle)
    # Camera settling may allow a new confirmation to appear.
    if not clear_dialogs(timeout=args.call_timeout):
        raise HelperError("dialog guard is blocked; screenshot aborted")
    before = snapshot(folder) if folder is not None else None
    output = call("TakeScreenshot", {"currentView": True}, timeout=args.call_timeout)
    return capture_path(output, folder, before, args.capture_timeout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=target_position, help="editor orbital target x,y,z")
    parser.add_argument("--distance", type=positive_seconds, help="editor camera distance in meters")
    parser.add_argument("--vangle", type=finite_number)
    parser.add_argument("--hangle", type=finite_number)
    parser.add_argument("--settle", type=nonnegative_seconds, default=1.5, help="camera settle seconds")
    parser.add_argument("--screenshot-dir", default=os.environ.get("TM_SCREENSHOT_DIR"),
                        help="existing host directory containing the game's screenshots")
    parser.add_argument("--call-timeout", type=positive_seconds, default=20.0,
                        help="deadline in seconds for each call.py subprocess")
    parser.add_argument("--capture-timeout", type=nonnegative_seconds, default=5.0,
                        help="additional seconds to wait for a mapped host screenshot")
    args = parser.parse_args(argv)
    try:
        print(take_shot(args))
        return 0
    except (HelperError, OSError) as exc:
        print(f"[shot] ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
