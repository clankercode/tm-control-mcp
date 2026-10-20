#!/usr/bin/env python3
"""Capture the Trackmania (or other Nadeo game) window to PNG.

Resolves the game's X11 (XWayland) window through tm-get-running-pids first,
then grabs that exact window with ImageMagick `import` — this avoids the two
common failure modes: spectacle grabbing whatever window has focus (terminal /
desktop), and desktop-wide grabs that need cropping. Works for Wine/Proton
games on Wayland because they are XWayland clients.

Only PID-owned windows are eligible. Multiple instances require a unique
selector; multiple windows for one instance require --xid (see --list).

Usage:
  tm-capture                          one frame -> /tmp/tm-capture-<ts>-00.png
  tm-capture -o shot.png              one frame -> shot.png
  tm-capture --frames 6 --interval-ms 400   animation study
  tm-capture --list                   show game instances and exit
  tm-capture --name Turbo             pick instance by window/game-name substring
  tm-capture --pid 1234               select a specific game process
  tm-capture --pid 1234 --xid 5678     select one of its verified X11 windows
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tm_get_running_pids import find_instances, get_window_pid  # noqa: E402


def pick_window(name_sub, pid=None, xid=None):
    instances = find_instances()
    if not instances:
        sys.exit("no running Nadeo game instances (see tm-get-running-pids)")
    if pid is not None:
        instances = [i for i in instances if i["pid"] == pid]
        if not instances:
            sys.exit("no running game instance matches --pid %d" % pid)
    if name_sub:
        needle = name_sub.lower()
        instances = [i for i in instances if needle in i["game"].lower()
                     or any(needle in w["name"].lower() for w in i["windows"])]
        if not instances:
            sys.exit("no instance matches --name %r" % name_sub)
    if xid is not None:
        instances = [i for i in instances if any(w["xid"] == xid for w in i["windows"])]
        if not instances:
            sys.exit("--xid %d has no verified PID ownership among matching instances" % xid)
    if len(instances) > 1:
        print("multiple instances; select one with --pid or a unique --name/--xid; candidates:", file=sys.stderr)
        for i in instances:
            print("  %s pid=%d" % (i["game"], i["pid"]), file=sys.stderr)
        sys.exit("ambiguous game instance; cannot capture")
    inst = instances[0]
    windows = [w for w in inst["windows"] if xid is None or w["xid"] == xid]
    if not windows:
        sys.exit("instance %s pid=%d has no X11 window with verified PID ownership "
                 "(cannot capture)" % (inst["game"], inst["pid"]))
    if len(windows) > 1:
        sys.exit("multiple X11 windows for pid=%d; select --xid from %s" %
                 (inst["pid"], ", ".join(str(w["xid"]) for w in windows)))
    return inst, windows[0]


def grab(xid, out, pid):
    if get_window_pid(xid) != pid:
        sys.exit("window xid=%d no longer has verified ownership by pid=%d (cannot capture)" % (xid, pid))
    r = subprocess.run(["import", "-silent", "-window", str(xid), "png:" + out], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("import failed: %s%s" % (r.stdout, r.stderr))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", help="output png (default /tmp/tm-capture-<ts>.png)")
    ap.add_argument("--name", help="pick instance by game/window-name substring")
    ap.add_argument("--pid", type=int, help="select a game process by PID")
    ap.add_argument("--xid", type=int, help="select a window with verified game PID ownership")
    ap.add_argument("--frames", type=int, default=1, help="number of frames (default 1)")
    ap.add_argument("--interval-ms", type=int, default=500, help="ms between frames (default 500)")
    ap.add_argument("--list", action="store_true", help="list instances and exit")
    args = ap.parse_args()
    if args.frames < 1:
        ap.error("--frames must be at least 1")
    if args.interval_ms < 0:
        ap.error("--interval-ms must be nonnegative")
    if args.pid is not None and args.pid < 1:
        ap.error("--pid must be positive")
    if args.xid is not None and args.xid < 1:
        ap.error("--xid must be positive")

    if args.list:
        return subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "tm_get_running_pids.py")]).returncode

    inst, win = pick_window(args.name, args.pid, args.xid)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = args.out
    for f in range(args.frames):
        if base and args.frames == 1:
            out = base
        else:
            path = Path(base or "/tmp/tm-capture-%s.png" % stamp)
            out = str(path.with_name("%s-%02d%s" % (path.stem, f, path.suffix or ".png")))
        grab(win["xid"], out, inst["pid"])
        print("%s  (%s pid=%d xid=%d)" % (out, inst["game"], inst["pid"], win["xid"]))
        if f < args.frames - 1:
            time.sleep(args.interval_ms / 1000.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
