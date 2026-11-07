# Trackmania crashwatch

Crashwatch watches the desktop and crash-log directory continuously, without a
socket connection to the game. It uses no network listener, game calls, input,
focus changes, window changes, dismissal, termination or restart. It detects the
`Crash in "Openplanet.dll"` failure seen in #27 and #36, and supplies continuous
evidence before the on-timeout dialog probe added in #17.

The Python reader requires Python 3.10+. Linux additionally needs `wmctrl` and
`xprop`, access to the game's X11/XWayland display, and its Wine prefix. Native
Windows uses the bundled PowerShell watcher and Windows Task Scheduler, with no
Python dependency for the watcher. Windows **must run in the logged-on user's
interactive session**: SSH's service session cannot enumerate the game desktop.

## Linux/Wine

Run from this checkout, in the desktop user's session:

```bash
python3 tools/crashwatch_linux.py
# Override the Wine pfx, or the complete Documents/Trackmania directory:
python3 tools/crashwatch_linux.py --prefix /path/to/compatdata/2225070/pfx
python3 tools/crashwatch_linux.py --documents /path/to/Documents/Trackmania
```

The default prefix is
`~/.local/share/Steam/steamapps/compatdata/2225070/pfx`; output is
`~/.local/state/tm-crashwatch/events.jsonl`. Polling defaults to two seconds and
heartbeat to five seconds (`--poll`, `--heartbeat`). A file lock prevents two
watchers writing the same events path. `--duration 30 --events /path/to/smoke/events.jsonl`
runs a bounded smoke and stops only the watcher.

To install the provided **user** unit, run these commands from the checkout in
the graphical session. They copy only the watcher and its shared module:

```bash
install -d -m 700 "$HOME/.local/lib/tm-crashwatch" "$HOME/.config/systemd/user"
install -m 600 tools/crashwatch_linux.py tools/crashwatch_core.py "$HOME/.local/lib/tm-crashwatch/"
install -m 600 tools/crashwatch/tm-crashwatch.service "$HOME/.config/systemd/user/"
systemctl --user import-environment DISPLAY XAUTHORITY
systemctl --user daemon-reload
systemctl --user enable --now tm-crashwatch.service
systemctl --user status tm-crashwatch.service
```

For a nondefault prefix, add `Environment=...`/an overridden `ExecStart` using
`systemctl --user edit tm-crashwatch.service` with the complete `--prefix` or
`--documents` argument. The unit starts with `graphical-session.target`, so it
does not attempt to inspect a nonexistent desktop before login. Desktop
environment variables must be imported into the user manager; unavailable
display tools or inaccessible directories produce unhealthy heartbeats.
Stop with `systemctl --user disable --now tm-crashwatch.service`; logs are kept.

Only an exact `Trackmania.exe` argv[0] is a game. An `explorer.exe` folder named
`Trackmania` never qualifies. Linux process birth is the boot UUID plus process
start ticks from `/proc/PID/stat`, so PID reuse is distinguishable. Crash titles
qualify independently of the process name; other game-owned dialogs qualify by
`#32770` in `WM_CLASS` or X11's `_NET_WM_WINDOW_TYPE_DIALOG` (Wine often masks the
native class behind a Steam app class). Generic dialogs are candidates for
inspection; their presence alone does not prove an exception.

## Windows: install only after approval

Copy `tools/crashwatch/windows/` to a reviewed location on x-lappy. In a
PowerShell console **as Max, without elevation**, run:

```powershell
Set-Location (Join-Path $env:USERPROFILE 'src\tm-control-mcp')
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\crashwatch\windows\install.ps1
Get-ScheduledTask -TaskName tm-crashwatch*
```

The installer registers `\tm-crashwatch-<current-user-SID>` and points directly
to this checkout's absolute `tools\crashwatch\windows\watch.ps1` path. Keep that
checkout at this location; the installer copies no scripts and starts no task.
It refuses to replace a task with different ownership or settings.
Paths containing percent signs, quotes or newlines are refused; Task Scheduler
expands percent expressions even inside quoted arguments.
The task runs hidden with an interactive per-user logon principal and restarts
on failure. It first starts at the next logon. It uses
`%LOCALAPPDATA%\tm-crashwatch\events.jsonl`. Task Scheduler
launches it inside the interactive desktop; starting the watcher directly from
SSH would invalidate window detection. A running process in an SSH service
session with `MainWindowTitle=N/A` or `Responding=Unknown` is not crash evidence.

To uninstall, run the provided `uninstall.ps1` as the same user. This stops and
unregisters only the watcher task and preserves event logs. See the installer
and uninstaller for their exact ownership checks and installed script paths.
Neither requires administrator rights or opens a port. For an approved immediate
start after installation, use this **interactive-session** console command:

```powershell
$taskName = 'tm-crashwatch-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Start-ScheduledTask -TaskPath '\' -TaskName $taskName
Get-ScheduledTaskInfo -TaskPath '\' -TaskName $taskName
```

To remove the watcher later, run the uninstaller from the same checkout and account:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\crashwatch\windows\uninstall.ps1
```

The running watcher creates only `%LOCALAPPDATA%\tm-crashwatch\`, `watcher.lock`,
`events.jsonl` and its three numbered backups. Uninstall leaves these logs and
the checkout intact. Do not run these scripts
as part of an agent's read-only inspection assignment.

## Reader and gating

```bash
python3 tools/crashwatch.py status --host xsm
python3 tools/crashwatch.py tail --host x-lappy --since 2026-11-07T09:00:00Z
# A local smoke or a copied Windows event set:
python3 tools/crashwatch.py status --host xsm --events /path/to/events.jsonl
```

Both commands print JSON. `status` prints a `status` object containing heartbeat
age, active crash/dialog boxes and retained new `LogCrash_*.txt` names. `tail`
prints up to 50 retained events (`--limit`) followed by the same status object;
it is a bounded read, not a follow loop. `--since` requires an ISO timestamp
with a timezone and filters history only. An older active box and a stale
heartbeat are never hidden by that filter.

Exit codes are **0** for live, healthy monitoring with no box; **1** for an
active box (including a box retained in a stale snapshot); **2** for missing or
stale heartbeat, corrupt complete JSONL records, failed reads or collector
errors. Heartbeats are stale after `max(15, 3 * interval_seconds)` seconds,
overridable with `--stale-after`. A future heartbeat more than five seconds away
is unhealthy too: clocks on the reader and watcher need to agree. A stale box
means “last observed active”, not proof it is still present now.

The reader uses the local files when the machine's short hostname matches
`--host`; otherwise it makes **one** SSH invocation, with `BatchMode=yes`,
`ConnectionAttempts=1`, a five-second connection timeout and a 15-second total
read deadline. There is no retry or PTY. The short encoded PowerShell command
on Windows and quoted Python command on Linux return complete UTF-8 content;
records spanning multiple 8 KB SSH reads are reassembled before JSON parsing.
Windows read handles explicitly share writes and deletes so polling cannot
block the watcher from appending or rotating. A missing or incomplete current
file is unhealthy, even if older backups contain a fresh all-clear heartbeat.
On Windows, deletion of an open oldest backup can keep its name occupied until
the last reader closes. Rotation waits for that name to become reusable before
continuing, without appending beyond the size bound. An unusually long wait
ages the heartbeat and makes status unhealthy; it never produces an all-clear.
Only the two named hosts are accepted. `--events` always means a local file.

`tools/call.py` consults this reader before its existing #17 desktop probe when
socket contact fails. Confirmed watcher boxes use exit 14 and include
`crashwatch` in the error JSON. Missing, stale, or unhealthy watcher data is
reported there and the existing local probe remains available. Other socket
hosts never inherit the local desktop's evidence. For SSH-forwarded sockets,
run the reader explicitly with the real game host; the localhost socket name
alone cannot identify the far end of a tunnel.

## Event schema and retention

Both backends write UTF-8 JSONL with common fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1` |
| `event` | One of the event types below |
| `ts` | ISO timestamp with UTC timezone |
| `host` | Lowercase short hostname |
| `watcher_id` | Unique ID for this watcher run |

| Event | Additional fields |
| --- | --- |
| `heartbeat` | `interval_seconds`, `active_boxes`, `games`, `errors` |
| `crash_box`, `crash_box_closed` | `pid`, `birth` (nullable), `window_id`, `title`, `first_seen` |
| `crash_log` | `name`, `size` in bytes, `mtime` (ISO UTC); **no body** |
| `game_exit` | `pid`, `birth` (OS process creation identity) |
| `watcher_error` | `source`, `error` |

Heartbeat `active_boxes` contains the full box fields; `games` contains
`{pid,birth}`; `errors` contains `{source,error}`. Birth distinguishes process
incarnations; first-seen is retained until a successful scan sees the box close.
A failed scan keeps the last good snapshot and reports the failing source,
without inventing exits or closed boxes. A fresh good heartbeat clears previous
collection errors. The reader validates the event schema before using evidence.
An incomplete final line during append is ignored; a malformed complete line
makes status unhealthy.

Existing `LogCrash_*.txt` names are baselined at the first successful directory
scan. Only names appearing afterwards generate events. Modified existing logs
are not new logs. Restarting the watcher rebaselines; it cannot recover events
while it was down, but the heartbeat exposes the outage. Rotation retains
`events.jsonl` plus `.1`, `.2`, `.3`, each at most 1 MiB by default. This is
bounded recent history, not an archive. Heartbeat snapshots preserve current
active boxes even after their original detection event rotates away. Copy
evidence promptly when an incident is detected.

## Agent response

1. Record the reader's output, PID **and birth**, window ID/title and exception
   details. If monitoring is stale or degraded, report that uncertainty and
   inspect the approved evidence sources; never infer that the game is healthy.
2. Before any termination or restart, back up `LogCrash_*.txt`, `Openplanet.log`
   and the game's autosaves to the incident's approved backup location. Keep
   original files intact, and do not put private log bodies into watcher JSONL.
3. Report the exception and evidence paths to the coordinator/Max. Only the
   approved actor may end the crashed PID, after checking its birth to avoid
   killing a reused PID. Crashwatch never performs recovery.
4. On **xsm**, relaunch is allowed as part of the approved recovery workflow.
   On **x-lappy**, follow that lane's approved restart procedure. An assignment
   that forbids killing or relaunching still takes precedence over this general
   procedure; during such an assignment, preserve evidence and report only.

## Verification

Run the fixture suite without a game:

```bash
python3 -m pytest tests/test_crashwatch.py tests/test_crashwatch_windows.py -q
```

Fixtures cover the exact Openplanet crash title, a harmless folder named
Trackmania, game-owned dialogs, process birth/PID reuse, log appearance,
failed collectors, heartbeat age, JSONL schema, rotation, timeout integration
and a single-attempt SSH read with records larger than 8 KB. Windows checks
validate structure and use the PowerShell parser if `pwsh` is available. Static
checks do not establish native desktop or Task Scheduler behavior; that requires
an approved interactive installation and live validation on x-lappy.
