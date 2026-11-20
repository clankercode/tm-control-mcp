"""Offline watcher transitions and gating, with no input, game or desktop actions."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import threading

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import crashwatch as reader
import crashwatch_core as core
import crashwatch_linux as linux

NOW = 1794050000.0
BOX = {"pid": 2203415, "birth": "boot:1234", "window_id": "0x0aa00006", "title": 'Crash in "Openplanet.dll"', "first_seen": core.iso_time(NOW)}
GAME = {"pid": BOX["pid"], "birth": BOX["birth"]}


def event(kind="heartbeat", **extra):
    fields = {"interval_seconds": 5, "active_boxes": [], "games": [GAME], "errors": []} if kind == "heartbeat" else {}
    return dict(schema_version=1, event=kind, ts=core.iso_time(NOW), host="xsm", watcher_id="test-session") | fields | extra


class MemoryWriter:
    def __init__(self):
        self.events = []

    def write(self, data):
        assert core.valid_event(data), data
        self.events.append(data)


def test_exact_crash_title_and_explorer_folder_fixture(monkeypatch):
    text = (Path(__file__).parent / "fixtures/crashwatch-wmctrl.txt").read_text()
    calls = []

    def command(args):
        calls.append(args)
        return text if args == ["wmctrl", "-lp"] else 'WM_CLASS(STRING) = "steam_app_2225070", "steam_app_2225070"'

    monkeypatch.setattr(linux, "command", command)
    boxes = linux.read_boxes({GAME["pid"]: GAME})
    assert len(boxes) == 1
    assert boxes[0]["title"] == 'Crash in "Openplanet.dll"'
    assert boxes[0]["pid"] == 2203415
    # PID 999 is explorer.exe with an identically named folder, never queried as game.
    assert not any("0x0bb00003" in args for args in calls)


def test_owned_standard_dialog_without_crash_title(monkeypatch):
    monkeypatch.setattr(linux, "command", lambda args: '0x00000003 0 2203415 xsm Message' if args[0] == "wmctrl" else 'WM_CLASS(STRING) = "#32770", "wine"')
    assert linux.read_boxes({GAME["pid"]: GAME})[0]["title"] == "Message"


def test_log_appearance_and_baseline_no_body_read(tmp_path, monkeypatch):
    (tmp_path / "LogCrash_old.txt").write_text("private crash body")
    out = MemoryWriter()
    watcher = linux.Watcher(out, "xsm", clock=lambda: NOW)
    monkeypatch.setattr(Path, "read_text", lambda *_a, **_k: pytest.fail("must not read log bodies"))
    watcher.poll(lambda: {}, lambda _: [], lambda: linux.read_logs(tmp_path))
    (tmp_path / "LogCrash_new.txt").write_bytes(b"1234")
    watcher.poll(lambda: {}, lambda _: [], lambda: linux.read_logs(tmp_path))
    logs = [e for e in out.events if e["event"] == "crash_log"]
    assert len(logs) == 1
    assert logs[0]["name"] == "LogCrash_new.txt" and logs[0]["size"] == 4
    assert "private" not in json.dumps(out.events)


def test_box_lifecycle_pid_reuse_and_game_exit():
    out = MemoryWriter()
    watcher = linux.Watcher(out, "xsm", clock=lambda: NOW)
    watcher.poll(lambda: {GAME["pid"]: GAME}, lambda _: [BOX], lambda: {})
    watcher.poll(lambda: {GAME["pid"]: GAME}, lambda _: [BOX], lambda: {})
    assert len([e for e in out.events if e["event"] == "crash_box"]) == 1
    successor = dict(GAME, birth="boot:9999")
    watcher.poll(lambda: {GAME["pid"]: successor}, lambda _: [], lambda: {}, True)
    assert [e for e in out.events if e["event"] == "game_exit"] == [event("game_exit", watcher_id=watcher.watcher_id, **GAME)]
    assert any(e["event"] == "crash_box_closed" for e in out.events)
    assert out.events[-1]["active_boxes"] == []


def failed():
    raise OSError("collector unavailable")


def test_failed_scans_preserve_last_good_state_and_are_unhealthy():
    out = MemoryWriter()
    watcher = linux.Watcher(out, "xsm", clock=lambda: NOW)
    watcher.poll(lambda: {GAME["pid"]: GAME}, lambda _: [BOX], lambda: {})
    watcher.poll(failed, lambda _: failed(), failed, True)
    assert not any(e["event"] in {"game_exit", "crash_box_closed"} for e in out.events)
    state = core.summarize(out.events, "xsm", NOW)
    assert state["active_boxes"] and len(state["errors"]) == 3 and not state["ok"]


def test_failure_between_heartbeats_is_unhealthy():
    records = [event(), event("watcher_error", source="windows", error="display lost")]
    assert not core.summarize(records, "xsm", NOW)["ok"]


def test_staleness_missing_future_and_since_does_not_hide_active_box():
    heartbeat = event(active_boxes=[BOX])
    state = core.summarize([heartbeat], "xsm", NOW + 16, since=NOW + 100)
    assert state["stale"] and state["active_boxes"] and not state["ok"]
    assert core.summarize([], "xsm", NOW)["stale"]
    assert core.summarize([event()], "xsm", NOW - 10)["stale"]
    assert core.summarize([event()], "xsm", NOW + 10)["ok"]
    assert core.summarize([event()], "x-lappy", NOW)["stale"]


def test_post_heartbeat_transitions_and_restart_snapshot():
    records = [event(), event("crash_box", **BOX)]
    assert core.summarize(records, "xsm", NOW)["active_boxes"]
    records.append(event("crash_box_closed", **BOX))
    assert core.summarize(records, "xsm", NOW)["ok"]
    records.append(event(watcher_id="new-watcher", active_boxes=[BOX]))
    assert core.summarize(records, "xsm", NOW)["active_boxes"]


def test_restart_crash_before_first_heartbeat_blocks_old_all_clear():
    records = [event(), event("crash_box", watcher_id="new-watcher", **BOX)]
    state = core.summarize(records, "xsm", NOW)
    assert state["stale"] and state["active_boxes"] and not state["ok"]


@pytest.mark.parametrize("change", [{"schema_version": 2}, {"ts": "yesterday"}, {"ts": "2026-11-07T12:00:00"}, {"active_boxes": [{}]}, {"interval_seconds": float("nan")}, {"games": [{"pid": 1}]}, {"errors": ["oops"]}])
def test_jsonl_schema_rejects_invalid_heartbeat(change):
    assert not core.valid_event(event(**change))


def test_schema_all_event_kinds_and_partial_utf8_line():
    records = [event(), event("crash_box", **BOX), event("crash_box_closed", **BOX), event("game_exit", **GAME),
               event("crash_log", name="LogCrash_001.txt", size=10, mtime=core.iso_time(NOW)),
               event("watcher_error", source="windows", error="unavailable")]
    assert all(core.valid_event(e) for e in records)
    payload = b"".join((json.dumps(e) + "\n").encode() for e in records)
    result, errors = core.decode_events(payload + b'{"title":"\xc3')
    assert result == records and not errors
    assert core.decode_events(payload + b'garbage\n')[1]


def test_rotation_is_size_bounded_and_snapshot_survives(tmp_path):
    path = tmp_path / "events.jsonl"
    unrelated = tmp_path / "keep.txt"
    unrelated.write_text("keep")
    writer = core.EventWriter(path, max_bytes=4096)
    for _ in range(200):
        writer.write(event(active_boxes=[BOX]))
    files = list(tmp_path.glob("events.jsonl*"))
    assert len(files) == 4 and all(p.stat().st_size <= 4096 for p in files)
    records, errors = reader.read_events("xsm", path)
    assert not errors and records and core.summarize(records, "xsm", NOW)["active_boxes"]
    assert unrelated.read_text() == "keep"


def test_writer_refuses_symlink_and_directory_backups(tmp_path):
    unrelated = tmp_path / "private.txt"
    unrelated.write_text("keep")
    path = tmp_path / "events.jsonl"
    Path(f"{path}.3").symlink_to(unrelated)
    with pytest.raises(ValueError, match="symlink"):
        core.EventWriter(path, max_bytes=4096)
    assert unrelated.read_text() == "keep"
    Path(f"{path}.3").unlink()
    Path(f"{path}.3").mkdir()
    with pytest.raises(ValueError, match="regular file"):
        core.EventWriter(path, max_bytes=4096)


def test_rotation_keeps_snapshot_during_many_events_between_heartbeats(tmp_path):
    path = tmp_path / "events.jsonl"
    writer = core.EventWriter(path, max_bytes=4096)
    writer.snapshot = event(active_boxes=[BOX])
    writer.write(writer.snapshot)
    for index in range(200):
        writer.write(event("crash_log", name=f"LogCrash_{index:04}.txt", size=index, mtime=core.iso_time(NOW)))
    records, errors = reader.read_events("xsm", path)
    state = core.summarize(records, "xsm", NOW, read_errors=errors)
    assert not state["stale"] and state["active_boxes"]


@pytest.mark.parametrize("incomplete", [None, b"", b'{"schema_version":1'])
def test_rotation_gap_cannot_fall_back_to_an_old_healthy_backup(tmp_path, monkeypatch, incomplete):
    monkeypatch.setattr(reader.time, "time", lambda: NOW)
    path = tmp_path / "events.jsonl"
    writer = core.EventWriter(path, max_bytes=4096)
    writer.write(event())
    Path(f"{path}.1").write_bytes(path.read_bytes())
    writer.write(event("crash_box", **BOX))
    original_read = Path.read_bytes

    def read_then_rotate(file):
        data = original_read(file)
        if file == Path(f"{path}.1"):
            path.replace(Path(f"{path}.1"))
            if incomplete is not None:
                path.write_bytes(incomplete)
        return data

    monkeypatch.setattr(Path, "read_bytes", read_then_rotate)
    state = reader.get_status("xsm", path=path)
    assert not state["ok"] and state["errors"]


def test_real_rotation_barrier_never_reports_old_all_clear(tmp_path, monkeypatch):
    monkeypatch.setattr(reader.time, "time", lambda: NOW)
    path = tmp_path / "events.jsonl"
    writer = core.EventWriter(path, max_bytes=4096)
    Path(f"{path}.1").write_text(json.dumps(event()) + "\n")
    writer.write(event("crash_box", **BOX))
    next_record = event("crash_log", name="LogCrash_new.txt", size=1, mtime=core.iso_time(NOW))
    record_size = len((json.dumps(next_record, separators=(",", ":")) + "\n").encode())
    while path.stat().st_size + record_size <= 4096:
        writer.write(next_record)
    writer.snapshot = event(active_boxes=[BOX])
    in_gap, finish = threading.Event(), threading.Event()
    original_read, original_write = Path.read_bytes, Path.write_bytes
    failures = []

    def pause_seed(file, data):
        if file == path:
            in_gap.set()
            assert finish.wait(5)
        return original_write(file, data)

    def rotate():
        try:
            writer.write(next_record)
        except BaseException as exc:
            failures.append(exc)

    worker = threading.Thread(target=rotate)

    def read_then_rotate(file):
        data = original_read(file)
        if file == Path(f"{path}.1"):
            worker.start()
            assert in_gap.wait(5)
        return data

    with monkeypatch.context() as patch:
        patch.setattr(Path, "read_bytes", read_then_rotate)
        patch.setattr(Path, "write_bytes", pause_seed)
        try:
            state = reader.get_status("xsm", path=path)
        finally:
            finish.set()
            worker.join(5)
    assert not worker.is_alive() and not failures
    assert not state["ok"] and state["errors"]
    assert reader.get_status("xsm", path=path)["active_boxes"]


def test_schema_rejects_box_without_process_birth_field():
    box = {k: v for k, v in BOX.items() if k != "birth"}
    assert not core.valid_event(event(active_boxes=[box]))


def test_ssh_is_single_attempt_and_handles_records_larger_than_8kb(monkeypatch):
    monkeypatch.setattr(reader.socket, "gethostname", lambda: "other")
    payload = (json.dumps(event(active_boxes=[dict(BOX, title="é" * 12000)])) + "\n").encode()
    calls = []

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, 0, payload)

    monkeypatch.setattr(reader.subprocess, "run", run)
    records, errors = reader.read_events("xsm")
    assert len(records[0]["active_boxes"][0]["title"]) == 12000 and not errors
    assert len(calls) == 1
    assert "ConnectionAttempts=1" in calls[0][0] and calls[0][1]["timeout"] == 15
    assert "-T" in calls[0][0]
    script = base64.b64decode(reader.remote_command("x-lappy").split()[-1]).decode("utf-16-le")
    assert "ReadToEnd" in script and "Console]::Write" in script
    assert "[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete" in script
    assert len(reader.remote_command("x-lappy")) < 8192


def test_ssh_failure_no_retry(monkeypatch):
    monkeypatch.setattr(reader.socket, "gethostname", lambda: "other")
    calls = []

    def run(*args, **kwargs):
        calls.append(args)
        raise subprocess.TimeoutExpired("ssh", 15)

    monkeypatch.setattr(reader.subprocess, "run", run)
    state = reader.get_status("x-lappy")
    assert not state["ok"] and state["stale"] and len(calls) == 1


def test_cli_status_tail_and_exit_codes(tmp_path, monkeypatch, capsys):
    path = tmp_path / "events.jsonl"
    writer = core.EventWriter(path)
    monkeypatch.setattr(reader.time, "time", lambda: NOW)
    writer.write(event())
    assert reader.main(["status", "--host", "xsm", "--events", str(path)]) == 0
    assert json.loads(capsys.readouterr().out)["status"]["ok"]
    writer.write(event("crash_box", **BOX))
    assert reader.main(["tail", "--host", "xsm", "--events", str(path), "--since", core.iso_time(NOW + 1)]) == 1
    assert json.loads(capsys.readouterr().out)["status"]["active_boxes"]
    monkeypatch.setattr(reader.time, "time", lambda: NOW + 20)
    writer.write(event(active_boxes=[]))
    assert reader.main(["status", "--host", "xsm", "--events", str(path)]) == 2


def test_process_birth_exact_argv0_and_explorer_exclusion(tmp_path):
    (tmp_path / "sys/kernel/random").mkdir(parents=True)
    (tmp_path / "sys/kernel/random/boot_id").write_text("boot-uuid")
    for pid, argv in [(10, b"C:\\Games\\Trackmania.exe\0"), (11, b"explorer.exe\0Trackmania"), (12, b"python3\0Trackmania.exe")]:
        folder = tmp_path / str(pid)
        folder.mkdir()
        (folder / "cmdline").write_bytes(argv)
        (folder / "stat").write_text(f"{pid} (Main Thread (wine)) " + " ".join(["0"] * 19 + ["1234"]))
    assert linux.read_games(tmp_path) == {10: {"pid": 10, "birth": "boot-uuid:1234"}}


def test_call_integration_reader_first_fallback_and_remote_isolation(monkeypatch, capsys):
    import call
    import platform
    monkeypatch.setattr(platform, "node", lambda: "xsm")
    calls = []
    monkeypatch.setattr(call, "get_crashwatch_status", lambda host: calls.append(("reader", host)) or {"active_boxes": [BOX], "stale": False})
    monkeypatch.setattr(call, "find_game_dialogs", lambda pids: calls.append(("fallback", pids)) or [])
    assert call.socket_failure("timeout", False, [2203415], "127.0.0.1") == 14
    assert calls == [("reader", "xsm")]
    assert json.loads(capsys.readouterr().out)["crashwatch"]["active_boxes"]
    calls.clear()
    monkeypatch.setattr(call, "get_crashwatch_status", lambda host: calls.append(("reader", host)) or {"active_boxes": [], "stale": True})
    assert call.socket_failure("timeout", False, [2203415], "localhost") == 4
    assert calls[0][0] == "reader" and calls[1][0] == "fallback"
    calls.clear()
    assert call.socket_failure("timeout", False, [2203415], "unrelated") == 4
    assert calls == []
