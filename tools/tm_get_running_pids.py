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
import re
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


def _query_timeout(deadline):
    if deadline is None:
        return 5.0
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired("window inspection", 2.0)
    return min(0.5, remaining)


def _xdotool(*args, deadline=None):
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    return subprocess.run(
        ["xdotool", *args], check=True,
        capture_output=True, text=True, timeout=_query_timeout(deadline), env=env,
    ).stdout.strip()


def get_window_pid(xid, deadline=None):
    """Return the window's reported PID, or None when ownership is unavailable."""
    try:
        kwargs = {"deadline": deadline} if deadline is not None else {}
        pid = int(_xdotool("getwindowpid", str(xid), **kwargs))
        return pid if pid > 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def _window_properties(xid, deadline=None):
    """Read advisory window-manager metadata without capturing pixels or focus."""
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    try:
        text = subprocess.run(
            ["xprop", "-id", str(xid), "_NET_WM_WINDOW_TYPE", "WM_TRANSIENT_FOR"],
            check=True, capture_output=True, text=True, timeout=_query_timeout(deadline), env=env,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    transient = re.search(r"WM_TRANSIENT_FOR[^\n]*?(0x[0-9a-fA-F]+)", text)
    return {"dialogType": "_NET_WM_WINDOW_TYPE_DIALOG" in text,
            "transientFor": int(transient[1], 16) if transient else None}


def _x11_windows(pid, properties=False, deadline=None):
    """List only windows whose X11 PID property matches this process."""
    wins = {}
    kwargs = {"deadline": deadline} if deadline is not None else {}
    try:
        xids = [int(x) for x in _xdotool("search", "--pid", str(pid), **kwargs).split()]
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    for xid in xids:
        if deadline is not None and time.monotonic() >= deadline:
            break
        if get_window_pid(xid, **kwargs) != pid:
            continue
        try:
            name = _xdotool("getwindowname", str(xid), **kwargs)
            shell = _xdotool("getwindowgeometry", "--shell", str(xid), **kwargs)
            geo = dict(kv.split("=", 1) for kv in shell.split() if "=" in kv)
            wins[xid] = {
                "xid": xid,
                "name": name,
                "x": int(geo.get("X", -1)),
                "y": int(geo.get("Y", -1)),
                "width": int(geo["WIDTH"]),
                "height": int(geo["HEIGHT"]),
            }
            if properties and wins[xid]["width"] >= 40 and wins[xid]["height"] >= 40:
                wins[xid].update(_window_properties(xid, **kwargs))
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            continue
    out = sorted(wins.values(), key=lambda w: w["width"] * w["height"], reverse=True)
    # Largest client areas first; keep small helpers available for explicit selection.
    return [w for w in out if w["width"] > 8 and w["height"] > 8] + \
           [w for w in out if w["width"] <= 8 or w["height"] <= 8]


def classify_dialogs(windows):
    """Candidates are evidence of a window, never proof that a process crashed."""
    sizeable = sorted((w for w in windows if w["width"] >= 40 and w["height"] >= 40),
                      key=lambda w: w["width"] * w["height"], reverse=True)
    dialogs = []
    for index, win in enumerate(sizeable):
        if index == 0:
            continue  # Largest owned window is the main window, not a dialog.
        title = win.get("name", "")
        crash = bool(re.search(r"\b(crash|exception|assert(?:ion)?)\b", title, re.I))
        error_title = bool(re.search(r"\berror\b", title, re.I))
        message = win.get("dialogType") or win.get("transientFor") or error_title
        evidence = []
        if crash or error_title:
            evidence.append("title")
        if win.get("dialogType"):
            evidence.append("dialog-type")
        if win.get("transientFor"):
            evidence.append("transient-for")
        dialogs.append(dict(win, kind="crash" if crash else "message" if message else "candidate",
                            evidence=evidence or ["secondary-window"]))
    return sorted(dialogs, key=lambda w: {"crash": 0, "message": 1, "candidate": 2}[w["kind"]])


def find_game_dialogs(pids):
    deadline = time.monotonic() + 2.0
    dialogs = []
    for pid in pids:
        if time.monotonic() >= deadline:
            break
        dialogs.extend(dict(dialog, pid=pid) for dialog in classify_dialogs(
            _x11_windows(pid, properties=True, deadline=deadline)))
    return dialogs


def find_instances():
    instances = []
    deadline = time.monotonic() + 2.0
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
        windows = _x11_windows(pid, properties=True, deadline=deadline)
        instances.append({
            "game": game,
            "pid": pid,
            "argv0": argv[0] if argv else "",
            "started_epoch_s": started_s,
            "started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started_s)),
            "windows": windows,
            "dialogs": classify_dialogs(windows),
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
