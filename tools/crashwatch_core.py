"""Shared crashwatch JSONL protocol, bounded writer and fail-closed reader state."""
from datetime import datetime, timezone
import json
import math
from pathlib import Path

SCHEMA_VERSION = 1
MAX_BYTES = 1024 * 1024
BACKUPS = 3
EVENTS = {"heartbeat", "crash_box", "crash_box_closed", "crash_log", "game_exit", "watcher_error"}


def iso_time(epoch=None):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z") if epoch is not None else datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp requires a timezone")
    return parsed.timestamp()


def _number(value):
    return type(value) in (int, float) and math.isfinite(value)


def _game(value):
    return (isinstance(value, dict) and type(value.get("pid")) is int and value["pid"] > 0
            and isinstance(value.get("birth"), str) and bool(value["birth"]))


def _box(value):
    if not isinstance(value, dict):
        return False
    return (type(value.get("pid")) is int and value["pid"] >= 0
            and isinstance(value.get("title"), str) and isinstance(value.get("window_id"), str)
            and bool(value["window_id"]) and isinstance(value.get("first_seen"), str)
            and "birth" in value and (value["birth"] is None or isinstance(value["birth"], str))
            and math.isfinite(parse_time(value["first_seen"])))


def valid_event(event):
    try:
        if (not isinstance(event, dict) or type(event.get("schema_version")) is not int
                or event["schema_version"] != SCHEMA_VERSION or event.get("event") not in EVENTS
                or not isinstance(event.get("host"), str) or not event["host"]
                or not isinstance(event.get("watcher_id"), str) or not event["watcher_id"]
                or not math.isfinite(parse_time(event["ts"]))):
            return False
        kind = event["event"]
        if kind == "heartbeat":
            return (_number(event.get("interval_seconds")) and event["interval_seconds"] > 0
                    and isinstance(event.get("active_boxes"), list) and all(_box(b) for b in event["active_boxes"])
                    and isinstance(event.get("games"), list) and all(_game(g) for g in event["games"])
                    and isinstance(event.get("errors"), list)
                    and all(isinstance(e, dict) and isinstance(e.get("source"), str)
                            and isinstance(e.get("error"), str) for e in event["errors"]))
        if kind in {"crash_box", "crash_box_closed"}:
            return _box(event)
        if kind == "game_exit":
            return _game(event)
        if kind == "crash_log":
            return (isinstance(event.get("name"), str) and event["name"].startswith("LogCrash_")
                    and event["name"].endswith(".txt") and "/" not in event["name"] and "\\" not in event["name"]
                    and type(event.get("size")) is int and event["size"] >= 0
                    and math.isfinite(parse_time(event["mtime"])))
        return isinstance(event.get("source"), str) and isinstance(event.get("error"), str)
    except (KeyError, ValueError, TypeError, AttributeError, OverflowError):
        return False


def assert_regular_path(path):
    """Do not append/rotate through links or overwrite a directory by mistake."""
    path = Path(path).absolute()
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise ValueError(f"refusing symlink: {candidate}")
    if path.exists() and not path.is_file():
        raise ValueError(f"expected a regular file: {path}")


class EventWriter:
    """Only rotates this watcher's current file and numbered backups. One writer required."""

    def __init__(self, path, max_bytes=MAX_BYTES, backups=BACKUPS):
        self.path = Path(path)
        self.max_bytes = max_bytes
        self.backups = backups
        self.snapshot = None
        if max_bytes < 4096 or not 1 <= backups <= BACKUPS:
            raise ValueError("max_bytes must be >=4096; backups must be 1..3")
        for index in range(self.backups + 1):
            assert_regular_path(Path(f"{self.path}.{index}") if index else self.path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    def write(self, event):
        if not valid_event(event):
            raise ValueError("invalid crashwatch event")
        line = (json.dumps(event, ensure_ascii=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
        if len(line) > self.max_bytes:
            raise ValueError("event exceeds rotation bound")
        for index in range(self.backups + 1):
            assert_regular_path(Path(f"{self.path}.{index}") if index else self.path)
        if event["event"] == "heartbeat":
            self.snapshot = event
        if self.path.exists() and self.path.stat().st_size + len(line) > self.max_bytes:
            seed = b""
            if event["event"] != "heartbeat" and self.snapshot is not None:
                if not valid_event(self.snapshot) or self.snapshot["event"] != "heartbeat":
                    raise ValueError("invalid rotation snapshot")
                seed = (json.dumps(self.snapshot, ensure_ascii=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
                if len(seed) + len(line) > self.max_bytes:
                    raise ValueError("snapshot plus event exceeds rotation bound")
            for index in range(self.backups, 0, -1):
                source = self.path if index == 1 else Path(f"{self.path}.{index - 1}")
                if source.exists():
                    source.replace(Path(f"{self.path}.{index}"))
            if seed:
                self.path.write_bytes(seed)
        with self.path.open("ab") as output:
            output.write(line)


def decode_events(data):
    """Ignore only a concurrently appended incomplete final line; flag all complete corruption."""
    events, errors = [], []
    for line in data.splitlines(keepends=True):
        if not line.endswith(b"\n"):
            continue
        try:
            event = json.loads(line)
            if not valid_event(event):
                raise ValueError("schema mismatch")
            events.append(event)
        except (ValueError, UnicodeDecodeError):
            errors.append("invalid JSONL record")
    return events, errors


def summarize(events, host, now, since=None, stale_after=None, read_errors=()):
    events = [e for e in events if e["host"].lower() == host.lower()]
    watcher_id = events[-1]["watcher_id"] if events else None
    heartbeats = [e for e in events if e["event"] == "heartbeat" and e["watcher_id"] == watcher_id]
    # File order, rather than wall-clock maximum, identifies the current watcher on restart.
    heartbeat = heartbeats[-1] if heartbeats else None
    age = now - parse_time(heartbeat["ts"]) if heartbeat else None
    threshold = stale_after if stale_after is not None else max(15, 3 * heartbeat["interval_seconds"]) if heartbeat else 15
    stale = age is None or age > threshold or age < -5
    boxes = heartbeat["active_boxes"] if heartbeat else []
    errors = list(read_errors) + (heartbeat["errors"] if heartbeat else [])
    # A crash observed after the last heartbeat must block immediately, not one heartbeat later.
    active = {(b["pid"], b["birth"], b["window_id"]): b for b in boxes}
    start = max(i for i, e in enumerate(events) if e is heartbeat) if heartbeat else -1
    for event in events[start + 1:]:
        if event["watcher_id"] != watcher_id:
            continue
        key = (event.get("pid"), event.get("birth"), event.get("window_id"))
        if event["event"] == "crash_box":
            active[key] = {k: event[k] for k in ("pid", "birth", "window_id", "title", "first_seen")}
        elif event["event"] == "crash_box_closed":
            active.pop(key, None)
        elif event["event"] == "watcher_error":
            error = {k: event[k] for k in ("source", "error")}
            if error not in errors:
                errors.append(error)
    boxes = list(active.values())
    logs = [e for e in events if e["event"] == "crash_log" and (since is None or parse_time(e["ts"]) >= since)]
    return {"host": host, "ok": not stale and not boxes and not errors, "stale": stale,
            "heartbeat_age_seconds": round(age, 3) if age is not None else None,
            "stale_after_seconds": threshold, "watcher_id": watcher_id,
            "active_boxes": boxes, "new_crash_logs": logs, "errors": errors}
