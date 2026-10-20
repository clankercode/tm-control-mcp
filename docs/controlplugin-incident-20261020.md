# ControlPlugin guard incident and verification

The October 19 report described a ControlPlugin load that never returned, followed
by persistent `reentrant_tool` even for status, while unrelated tools/socket status
remained usable. This investigation reproduced a root cause deterministically:

1. ControlPlugin is admitted and yields.
2. An independent WaitUntil request is admitted.
3. ControlPlugin completes first; global `PopCallStack()` removes WaitUntil.
4. ControlPlugin remains in the global array and all later same-name requests fail.

The production AngelScript regression failed with
`completed ControlPlugin must not remain reentrant` before the fix. Independent
coroutines are not a LIFO call stack. A VM-killed coroutine also skips the trailing
pop; a try/catch alone cannot guarantee that cleanup occurs.

The fix supervises dispatch in retained workers, removes admissions by unique ID,
observes worker termination independently of callers, and publishes tool/age/owner
status. Wall deadlines return a terminal error; still-running workers remain
quarantined until they stop or a genuine bridge reload destroys their execution.
Direct status and instance-checked recovery bypass tool admission. A native
self-reload probe found that initiating self-reload inside the worker drops the
socket response; its nonyielding acknowledgement now runs on the caller stack.

ControlPlugin now supports `action=status`. Loading reacquires the Meta plugin
handle after yielding, instead of trusting a pre-yield handle. Plugin log-tail
collection seeks to the last 512KiB before reading; it no longer reads an entire
potentially large session just to truncate it afterward.

## Historical evidence limits

Both retained logs (`Openplanet.log` and `Openplanet-Old.log`) now have October 20
session headings. A bounded archive/tmp search did not recover the October 19
session. The reported 12:22:34 start, 12:23:05 completion and failed ~16:05 reload
remain reported history. No evidence establishes that guard state survived a
successful genuine reload; failed reload, wrong bytes and immediate re-wedge
cannot be distinguished retrospectively.

Old admission rejection returned before the start/done trace, explaining why
later rejected calls could leave no such entries. That does not establish why
all logs reportedly stopped after 13:32. New call events persist separately in the
rotating plugin-storage request log regardless of payload tracing, and status
reports instance/source identity so future reloads can be proven.

The older branch ending at `bf4dff7` contains an earlier explicit-owner registry
attempt. `bf4dff7` itself raises the manifest timeout from 15s to 60s. This change
supersedes that branch's guard approach and timeout workaround: the manifest stays
at 15s; known bridge-owned dispatch covers legacy imports as well, and a wall-time
deadline is distinct from the VM execution limit. The old clone was read-only.

## Live verification on xsm, October 20

Openplanet **1.29.14 (next, Public, 6fd4200f)**; game engine build
**2026-02-03 03:51:19**, Linux/Proton. Loaded source:
`C:/users/steamuser/OpenplanetNext/Plugins/tm-control-mcp/`, matching both
`~/OpenplanetNext` and `~/win/OpenplanetNext` symlinks.

- Dev build loaded successfully in-game; LSP warnings only. Game compilation also
  reports existing signed/unsigned warnings in PackUpdatePolicy and SplitPackToolName
  that the initial LSP report did not include. The full transcripts are retained
  locally; no new guard compile warnings/errors occurred.
- Caught error, outside-catch worker death, recursive same-tool rejection and
  interleaved completion all passed. An actual 15-second CPU watchdog stall was
  not induced; outside-catch death exercises the observed termination path.
- Forever-yield probe timed out, status showed its running expired worker, tool
  calls refused safely, stale instance recovery refused, and valid recovery
  produced a new instance with empty active/expired lists. No game restart.
- Repeated harmless TitlePack load/rebuild/status/unload/load with an overlapping
  WaitUntil passed three times; the target was left loaded.
- Recovery with populated required dependents followed by restoration passed.
  A TitlePack.ListPackCandidates -> imported CallTool(ControlFids) call passed.
- Ordinary self-reload first reproduced a dropped response, then passed with
  `queued:true` after the caller-stack acknowledgement fix. Nested self-reload
  now refuses with `tool_busy` while any invocation is active; a DEV nested
  call confirmed refusal without changing the healthy instance.
- Spectacle active-window capture visibly included Openplanet settings and the
  Dips++ CustomMap Editor. See [window capture](window-screenshots.md).

The bridge reload unloads required dependents; preserve/restore the prior loaded
set as described in [call recovery](call-recovery.md). A pre-existing `bosslike`
placeholder cannot compile because BetterRoomManager is absent; it was already
reported that way at session startup. No unrelated dependencies were enabled.
The `tm-mcp-pack-car` unload reports a pre-existing native-memory ownership error,
also present before this change. Those sibling-plugin issues are outside this fix.
