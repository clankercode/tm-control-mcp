#!/usr/bin/env python3
"""Read crashwatch status or retained events locally or with one non-retrying SSH read."""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time

from crashwatch_core import BACKUPS, decode_events, parse_time, summarize

HOSTS = ("xsm", "x-lappy")


def open_event_file(path):
    """Windows readers must share append AND rename/delete with the watcher."""
    if os.name != "nt":
        return Path(path).open("rb")
    import ctypes
    from ctypes import wintypes
    import msvcrt
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    close = kernel.CloseHandle
    close.argtypes = [wintypes.HANDLE]
    close.restype = wintypes.BOOL
    handle = create(str(path), 0x80000000, 0x7, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        close(handle)
        raise
    # open_osfhandle transfers ownership; closing this stream closes the handle.
    return os.fdopen(descriptor, "rb")


def read_event_bytes(path):
    if os.name != "nt":
        return path.read_bytes()
    with open_event_file(path) as stream:
        return stream.read()


def local_events_path(host):
    if host == "x-lappy":
        return Path(os.environ["LOCALAPPDATA"]) / "tm-crashwatch/events.jsonl"
    return Path.home() / ".local/state/tm-crashwatch/events.jsonl"


def read_local(path):
    chunks = []
    for index in range(BACKUPS, -1, -1):
        file = Path(f"{path}.{index}") if index else path
        try:
            # Keep each file's partial final line isolated from the next file.
            data = read_event_bytes(file)
            if index == 0 and b"\n" not in data:
                raise OSError("current events file has no complete record (startup or rotation in progress)")
            chunks.append(data[:data.rfind(b"\n") + 1])
        except FileNotFoundError:
            if index == 0:
                raise  # Never substitute an older all-clear backup for a missing current file.
            continue
    return b"".join(chunks)


def remote_command(host):
    if host == "x-lappy":
        # EncodedCommand is small, avoids cmd.exe quoting, and writes UTF-8 bytes.
        # ReadToEnd/Console.Write does not truncate records at SSH's 8 KB reads.
        # Explicit delete sharing lets the writer rotate while these handles are open.
        script = r"""$ErrorActionPreference='Stop'; [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false); $p=Join-Path $env:LOCALAPPDATA 'tm-crashwatch\events.jsonl'; foreach($i in 3,2,1,0){$f=$p;if($i -gt 0){$f=$p+'.'+$i};if(Test-Path -LiteralPath $f){$stream=[IO.File]::Open($f,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));try{$r=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8);try{$s=$r.ReadToEnd()}finally{$r.Dispose()}}finally{$stream.Dispose()};$n=$s.LastIndexOf("`n");if($i -eq 0 -and $n -lt 0){throw 'Current events incomplete'};if($n -ge 0){[Console]::Write($s.Substring(0,$n+1))}}elseif($i -eq 0){throw 'Current events missing'}}"""
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return f"powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {encoded}"
    script = "from pathlib import Path; import sys; p=Path.home()/'.local/state/tm-crashwatch/events.jsonl'; "
    script += "\nfor i in (3,2,1,0):\n f=Path(str(p)+'.'+str(i)) if i else p\n try:\n  d=f.read_bytes()\n  if i==0 and b'\\n' not in d: raise OSError('Current events incomplete')\n  sys.stdout.buffer.write(d[:d.rfind(b'\\n')+1])\n except FileNotFoundError:\n  if i==0: raise\n"
    return "python3 -c " + shlex.quote(script)


def read_events(host, path=None):
    local = socket.gethostname().split(".")[0].lower() == host
    if path is not None:
        return decode_events(read_local(Path(path)))
    if local:
        return decode_events(read_local(local_events_path(host)))
    # Exactly one invocation, no retry and no PTY. Capture all chunks before JSON parsing.
    result = subprocess.run(
        ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
         host, remote_command(host)], capture_output=True, timeout=15, check=True,
    )
    return decode_events(result.stdout)


def get_status(host, since=None, path=None, stale_after=None):
    try:
        events, errors = read_events(host, path)
    except (OSError, subprocess.SubprocessError, KeyError) as exc:
        events, errors = [], [f"event read failed: {exc}"]
    return summarize(events, host, time.time(), since, stale_after, errors)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "tail"))
    parser.add_argument("--host", choices=HOSTS, required=True)
    parser.add_argument("--since", help="ISO timestamp with timezone; filters history, never liveness or active boxes")
    parser.add_argument("--events", type=Path, help="Explicit local file (also useful for copied Windows events)")
    parser.add_argument("--stale-after", type=float, help="Override default max(15, 3 * heartbeat interval) seconds")
    parser.add_argument("--limit", type=int, default=50, help="Maximum history records for tail (default 50)")
    args = parser.parse_args(argv)
    try:
        since = parse_time(args.since) if args.since else None
    except (ValueError, AttributeError, OverflowError):
        parser.error("--since must be an ISO timestamp with timezone")
    if args.stale_after is not None and not 0 < args.stale_after <= 86400:
        parser.error("--stale-after must be between 0 and 86400")
    if not 1 <= args.limit <= 10000:
        parser.error("--limit must be 1..10000")
    try:
        events, errors = read_events(args.host, args.events)
    except (OSError, subprocess.SubprocessError, KeyError) as exc:
        events, errors = [], [f"event read failed: {exc}"]
    state = summarize(events, args.host, time.time(), since, args.stale_after, errors)
    if args.command == "tail":
        for event in [e for e in events if e["host"].lower() == args.host and (since is None or parse_time(e["ts"]) >= since)][-args.limit:]:
            print(json.dumps(event, ensure_ascii=True, separators=(",", ":")))
    # Both modes finish with a status object; tail is bounded, not a remote follow loop.
    print(json.dumps({"status": state}, ensure_ascii=True, separators=(",", ":")))
    return 1 if state["active_boxes"] else 2 if not state["ok"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
