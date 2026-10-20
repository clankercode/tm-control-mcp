#!/usr/bin/env python3
"""List running Nadeo game instances with everything capture/control needs.

Covers Trackmania.exe (TM2020), Maniaplanet.exe, TrackmaniaTurbo.exe and
Shootmania.exe. For each instance reports pid, argv0, start time, and the
X11 (XWayland) windows for that pid (id, name, geometry). Wine/Proton games
are XWayland clients, so their windows are addressable with X11 tools
(xdotool / import) even on a Wayland session.

Detection notes (why not /proc/comm): under Proton the game process's comm is
unreliable ("MainThread") and exe resolves to wine-preloader. The stable
signature is argv[0] ending with the game exe name (the Windows-side path,
e.g. Z:\\...\\Trackmania.exe). Proton/steam.exe wrappers have a different
argv0 and are excluded.

Usage:
  tm-get-running-pids            human-readable
  tm-get-running-pids --json     machine-readable
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

GAME_EXES = [
    "Trackmania.exe",
    "Maniaplanet.exe",
    "TrackmaniaTurbo.exe",
    "Shootmania.exe",
]


def _boot_time_s():
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime"):
            return int(line.split()[1])
    return 0


def _start_time_s(pid_dir):
    # field 22 (1-based) of /proc/<pid>/stat is starttime in clock ticks;
    # the comm field may contain spaces/parens, so split after the last ')'.
    stat = (pid_dir / "stat").read_text()
    ticks = int(stat.rsplit(")", 1)[1].split()[19])
    hz = os.sysconf("SC_CLK_TCK") or 100
    return _boot_time_s() + ticks // hz


def _cmdline(pid_dir):
    try:
        return (pid_dir / "cmdline").read_bytes().decode("utf-8", "replace").split("\0")
    except (OSError, ProcessLookupError):
        return []


def _argv0_matches(argv, game):
    if not argv:
        return False
    argv0 = argv[0].replace("\\", "/").lower()
    return argv0.endswith(game.lower()) or argv0.endswith(game.lower()[:-4])  # with/without .exe


def _xdotool(*args):
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    return subprocess.run(
        ["xdotool", *args], check=True,
        capture_output=True, text=True, timeout=5, env=env,
    ).stdout.strip()


def get_window_pid(xid):
    """Return the window's reported PID, or None when ownership is unavailable."""
    try:
        pid = int(_xdotool("getwindowpid", str(xid)))
        return pid if pid > 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def _x11_windows(pid):
    """List only windows whose X11 PID property matches this process."""
    wins = {}
    try:
        xids = [int(x) for x in _xdotool("search", "--pid", str(pid)).split()]
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    for xid in xids:
        if get_window_pid(xid) != pid:
            continue
        try:
            name = _xdotool("getwindowname", str(xid))
            shell = _xdotool("getwindowgeometry", "--shell", str(xid))
            geo = dict(kv.split("=", 1) for kv in shell.split() if "=" in kv)
            wins[xid] = {
                "xid": xid,
                "name": name,
                "x": int(geo.get("X", -1)),
                "y": int(geo.get("Y", -1)),
                "width": int(geo["WIDTH"]),
                "height": int(geo["HEIGHT"]),
            }
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            continue
    out = sorted(wins.values(), key=lambda w: w["width"] * w["height"], reverse=True)
    # Largest client areas first; keep small helpers available for explicit selection.
    return [w for w in out if w["width"] > 8 and w["height"] > 8] + \
           [w for w in out if w["width"] <= 8 or w["height"] <= 8]


def find_instances():
    instances = []
    for pid_dir in Path("/proc").iterdir():
        if not pid_dir.name.isdigit():
            continue
        argv = _cmdline(pid_dir)
        game = next((g for g in GAME_EXES if _argv0_matches(argv, g)), None)
        if game is None:
            continue
        pid = int(pid_dir.name)
        try:
            started_s = _start_time_s(pid_dir)
        except (OSError, ValueError, IndexError):
            # Processes can exit or become inaccessible after reading cmdline.
            continue
        instances.append({
            "game": game,
            "pid": pid,
            "argv0": argv[0] if argv else "",
            "started_epoch_s": started_s,
            "started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started_s)),
            "windows": _x11_windows(pid),
        })
    instances.sort(key=lambda i: (i["game"], i["started_epoch_s"]))
    return instances


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="JSON output")
    args = ap.parse_args()

    instances = find_instances()
    if args.json:
        print(json.dumps({"count": len(instances), "instances": instances}, indent=1))
        return 0

    if not instances:
        print("no running Nadeo game instances (%s)" % ", ".join(GAME_EXES))
        return 1
    for inst in instances:
        print("%s  pid=%d  started=%s" % (inst["game"], inst["pid"], inst["started"]))
        print("  argv0: %s" % inst["argv0"])
        if not inst["windows"]:
            print("  windows: no X11 windows with verified PID ownership "
                  "(missing PID property, inaccessible, headless or native Wayland?)")
        for i, w in enumerate(inst["windows"]):
            tag = " [largest]" if i == 0 else ""
            print("  window xid=%d%s  %dx%d+%d+%d  name=%r"
                  % (w["xid"], tag, w["width"], w["height"], w["x"], w["y"], w["name"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
