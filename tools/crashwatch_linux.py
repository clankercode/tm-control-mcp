#!/usr/bin/env python3
"""Read-only Linux/Wine crash watcher. Never sends game, input or window-control commands."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
import uuid

from crashwatch_core import EventWriter, assert_regular_path, iso_time

DEFAULT_PREFIX = Path.home() / ".local/share/Steam/steamapps/compatdata/2225070/pfx"
DEFAULT_EVENTS = Path.home() / ".local/state/tm-crashwatch/events.jsonl"


def parse_wmctrl(text):
    windows = []
    for line in text.splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5 and re.fullmatch(r"0x[0-9a-fA-F]+", fields[0]) and fields[2].isdigit():
            windows.append({"window_id": fields[0].lower(), "pid": int(fields[2]), "title": fields[4]})
    return windows


def read_games(proc=Path("/proc")):
    boot_id = (proc / "sys/kernel/random/boot_id").read_text().strip()
    games = {}
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue  # Per-user watcher; other users' protected /proc entries are irrelevant.
            argv0 = (entry / "cmdline").read_bytes().split(b"\0", 1)[0].decode(errors="replace").replace("\\", "/").lower()
            if argv0.rsplit("/", 1)[-1] != "trackmania.exe":
                continue
            ticks = (entry / "stat").read_text().rsplit(")", 1)[1].split()[19]
            birth = f"{boot_id}:{ticks}"
            games[int(entry.name)] = {"pid": int(entry.name), "birth": birth}
        except (FileNotFoundError, ProcessLookupError):
            continue
        # Permissions or malformed process metadata are collection failures, not game exits.
    return games


def command(args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=3).stdout


def read_boxes(games):
    boxes = []
    for window in parse_wmctrl(command(["wmctrl", "-lp"])):
        title_crash = re.search(r'^Crash in ".+"', window["title"], re.I)
        is_dialog = False
        if window["pid"] in games and not title_crash:
            try:
                props = command(["xprop", "-id", window["window_id"], "WM_CLASS", "_NET_WM_WINDOW_TYPE"])
            except subprocess.CalledProcessError:
                # A disappeared window is a normal enumeration race. Verify next poll.
                raise RuntimeError("window properties unavailable during enumeration")
            is_dialog = '"#32770"' in props or "_NET_WM_WINDOW_TYPE_DIALOG" in props
        if title_crash or is_dialog:
            boxes.append(dict(window, birth=games.get(window["pid"], {}).get("birth")))
    return boxes


def read_logs(documents):
    # Missing/inaccessible Documents is a failed source, not an empty log directory.
    result = {}
    for path in documents.iterdir():
        if path.name.startswith("LogCrash_") and path.name.endswith(".txt") and path.is_file():
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            result[path.name] = {"name": path.name, "size": stat.st_size, "mtime": iso_time(stat.st_mtime)}
    return result


class Watcher:
    def __init__(self, writer, host, heartbeat=5, clock=time.time):
        self.writer, self.host, self.interval, self.clock = writer, host, heartbeat, clock
        self.watcher_id = str(uuid.uuid4())
        self.games, self.boxes, self.logs = {}, {}, None
        self.last_heartbeat = None
        self.pending = []

    def record(self, event, **fields):
        return dict(schema_version=1, event=event, ts=iso_time(self.clock()),
                    host=self.host, watcher_id=self.watcher_id, **fields)

    def emit(self, event, **fields):
        self.pending.append(self.record(event, **fields))

    def poll(self, game_source, box_source, log_source, force_heartbeat=False):
        self.pending = []
        errors = []
        try:
            games = game_source()
            for pid, previous in self.games.items():
                if games.get(pid) != previous:
                    self.emit("game_exit", **previous)
            self.games = games
        except (OSError, ValueError, IndexError, subprocess.SubprocessError) as exc:
            errors.append({"source": "processes", "error": str(exc)})
        try:
            boxes = {}
            for box in box_source(self.games):
                key = (box["pid"], box["birth"], box["window_id"])
                boxes[key] = dict(box, first_seen=self.boxes.get(key, {}).get("first_seen", iso_time(self.clock())))
                if key not in self.boxes:
                    self.emit("crash_box", **boxes[key])
            for key in self.boxes.keys() - boxes.keys():
                self.emit("crash_box_closed", **self.boxes[key])
            self.boxes = boxes
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            errors.append({"source": "windows", "error": str(exc)})
        try:
            logs = log_source()
            if self.logs is not None:
                for name in sorted(logs.keys() - self.logs.keys()):
                    self.emit("crash_log", **logs[name])
            self.logs = logs
        except (OSError, ValueError) as exc:
            errors.append({"source": "logs", "error": str(exc)})
        # A heartbeat with source errors is live but unhealthy, and never claims all-clear.
        heartbeat = self.record("heartbeat", interval_seconds=self.interval, active_boxes=list(self.boxes.values()),
                                games=list(self.games.values()), errors=errors)
        # A burst of events can rotate every older heartbeat within one poll.
        # Seed each rotation from this completed scan before flushing transitions.
        self.writer.snapshot = heartbeat
        if force_heartbeat or self.last_heartbeat is None or self.clock() - self.last_heartbeat >= self.interval:
            self.pending.append(heartbeat)
            self.last_heartbeat = self.clock()
        for error in errors:
            self.emit("watcher_error", **error)
        for event in self.pending:
            self.writer.write(event)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=DEFAULT_PREFIX, help="Wine pfx directory")
    parser.add_argument("--documents", type=Path, help="Override Documents/Trackmania directory")
    parser.add_argument("--events", type=Path, default=DEFAULT_EVENTS)
    parser.add_argument("--host", default=socket.gethostname().split(".")[0].lower())
    parser.add_argument("--poll", type=float, default=2)
    parser.add_argument("--heartbeat", type=float, default=5)
    parser.add_argument("--duration", type=float, help="Stop after this many seconds (smoke only)")
    parser.add_argument("--max-bytes", type=int, default=1024 * 1024)
    args = parser.parse_args(argv)
    if not (0.1 <= args.poll <= 60 and 0.1 <= args.heartbeat <= 3600) or (args.duration is not None and not 0 < args.duration <= 86400):
        parser.error("invalid timing options")
    documents = args.documents or args.prefix / "drive_c/users/steamuser/Documents/Trackmania"
    writer = EventWriter(args.events, args.max_bytes)
    assert_regular_path(Path(f"{args.events}.lock"))
    with Path(f"{args.events}.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(2, "another watcher owns this events path\n")
        watcher = Watcher(writer, args.host, args.heartbeat)
        stop = False

        def stopped(*_):
            nonlocal stop
            stop = True

        signal.signal(signal.SIGTERM, stopped)
        signal.signal(signal.SIGINT, stopped)
        end = time.monotonic() + args.duration if args.duration is not None else float("inf")
        while not stop and time.monotonic() < end:
            watcher.poll(read_games, read_boxes, lambda: read_logs(documents))
            time.sleep(min(args.poll, max(0, end - time.monotonic())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
