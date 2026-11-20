# Windows PowerShell 5.1+. Run in the logged-on user's interactive session.
# Observes processes, top-level windows and crash-log metadata only.
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$PollSeconds = 2,
    [ValidateRange(1, 300)][int]$HeartbeatSeconds = 5,
    [ValidateRange(4096, 16777216)][int]$MaxBytes = 1048576
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This watcher requires Windows.' }
if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run watch.ps1 in an interactive logon session (use install.ps1), not SSH or session 0.'
}
if ($PollSeconds -gt $HeartbeatSeconds) { throw 'PollSeconds must not exceed HeartbeatSeconds.' }

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace TmCrashwatch {
    public sealed class WindowInfo {
        public int Pid;
        public string Handle;
        public string Title;
    }
    public static class Native {
        private delegate bool EnumProc(IntPtr window, IntPtr param);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumProc callback, IntPtr param);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetClassName(IntPtr window, StringBuilder value, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetWindowText(IntPtr window, StringBuilder value, int size);
        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetUserObjectInformation(IntPtr obj, int index,
            out UserObjectFlags flags, int size, out int needed);
        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint error);
        [StructLayout(LayoutKind.Sequential)]
        private struct UserObjectFlags { public int Inherit; public int Reserved; public uint Flags; }
        private static readonly Regex CrashTitle = new Regex("^Crash in \"[^\"]+\"$", RegexOptions.CultureInvariant);

        public static WindowInfo[] Scan(int[] gamePids) {
            // A noninteractive window station can enumerate an empty desktop successfully.
            // Refuse it so a misconfigured task cannot publish a healthy empty snapshot.
            UserObjectFlags flags;
            int needed;
            IntPtr station = GetProcessWindowStation();
            if (station == IntPtr.Zero || !GetUserObjectInformation(station, 1, out flags,
                    Marshal.SizeOf(typeof(UserObjectFlags)), out needed))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect window station");
            if ((flags.Flags & 1) == 0)
                throw new InvalidOperationException("Window station is not interactive");

            // Dictionary lives in mscorlib on .NET Framework; do not depend on
            // Add-Type implicitly referencing System.Core for HashSet<T> on PS 5.1.
            var games = new Dictionary<int, bool>();
            foreach (int gamePid in gamePids) games[gamePid] = true;
            var result = new List<WindowInfo>();
            Exception failure = null;
            EnumProc callback = delegate(IntPtr window, IntPtr param) {
                try {
                    uint pid;
                    if (GetWindowThreadProcessId(window, out pid) == 0) {
                        if (!IsWindow(window)) return true; // vanished during enumeration
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read window PID");
                    }
                    var title = new StringBuilder(32768);
                    SetLastError(0);
                    int length = GetWindowText(window, title, title.Capacity);
                    int error = Marshal.GetLastWin32Error();
                    if (length == 0 && error != 0) {
                        if (!IsWindow(window)) return true;
                        throw new Win32Exception(error, "Cannot read window title");
                    }
                    if (length == title.Capacity - 1)
                        throw new InvalidOperationException("Window title exceeds capture limit");
                    bool match = CrashTitle.IsMatch(title.ToString());
                    if (!match && games.ContainsKey((int)pid)) {
                        var cls = new StringBuilder(256);
                        if (GetClassName(window, cls, cls.Capacity) == 0) {
                            if (!IsWindow(window)) return true;
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read window class");
                        }
                        match = cls.ToString() == "#32770";
                    }
                    if (match) result.Add(new WindowInfo {
                        Pid = (int)pid, Handle = "0x" + window.ToInt64().ToString("x"), Title = title.ToString()
                    });
                    return true;
                } catch (Exception ex) { failure = ex; return false; }
            };
            bool success = EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            if (failure != null) throw failure;
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
            return result.ToArray();
        }
    }
}
'@

function Get-UtcTimestamp { [DateTime]::UtcNow.ToString('o') }
function Assert-RegularPath([string]$Path) {
    # Never rotate through a junction, symlink or other reparse point. Check ancestors too.
    $cursor = $Path
    while ($cursor) {
        try {
            # Exists() hides access errors and dangling links, so inspect attributes directly.
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse point: $cursor"
            }
        } catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if (-not $localAppData -or -not [IO.Path]::IsPathRooted($localAppData)) {
    throw 'Cannot resolve the per-user LocalApplicationData directory.'
}
$logRoot = [IO.Path]::Combine($localAppData, 'tm-crashwatch')
Assert-RegularPath $logRoot
[void][IO.Directory]::CreateDirectory($logRoot)
$script:EventsPath = [IO.Path]::Combine($logRoot, 'events.jsonl')
$lockPath = [IO.Path]::Combine($logRoot, 'watcher.lock')
Assert-RegularPath $lockPath
# A file lock spans terminal sessions. A Local\ mutex would allow two users' sessions
# for the same account to rotate the same log concurrently. Do not delete this file.
$writerLock = $null
try {
    $writerLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    if (($_.Exception.HResult -band 0xffff) -eq 32) { exit 0 } # already watched
    throw
}

try {
    $script:Utf8 = New-Object Text.UTF8Encoding($false)
    $script:SnapshotLine = $null
    $script:WatcherId = [Guid]::NewGuid().ToString()
    $script:HostName = [Environment]::MachineName.Split('.')[0].ToLowerInvariant()
    $nativeError = $null
    try { Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop }
    catch { $nativeError = $_.Exception.Message }

    function New-Record([string]$Event, [hashtable]$Fields) {
        $record = [ordered]@{
            schema_version = 1; event = $Event; ts = Get-UtcTimestamp
            host = $script:HostName; watcher_id = $script:WatcherId
        }
        foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
        return $record
    }

    function Write-Record($Record) {
        $line = ($Record | ConvertTo-Json -Depth 8 -Compress) + "`n"
        $bytes = $script:Utf8.GetByteCount($line)
        if ($bytes -gt $MaxBytes) { throw 'Record exceeds the configured JSONL size limit.' }
        # Preflight every exact path before rotating. No wildcard operations or recursive deletes.
        foreach ($suffix in @('', '.1', '.2', '.3')) {
            $path = $script:EventsPath + $suffix
            Assert-RegularPath $path
            if ([IO.Directory]::Exists($path)) { throw "Expected a file: $path" }
        }
        $size = 0L
        if ([IO.File]::Exists($script:EventsPath)) { $size = (Get-Item -LiteralPath $script:EventsPath).Length }
        if ($size + $bytes -gt $MaxBytes) {
            $seed = ''
            if ($Record.event -ne 'heartbeat' -and $script:SnapshotLine) { $seed = $script:SnapshotLine }
            if ($script:Utf8.GetByteCount($seed) + $bytes -gt $MaxBytes) {
                throw 'Heartbeat plus event exceeds the configured JSONL size limit.'
            }
            # Only the oldest of our three backups is removed; reader handles must share delete.
            $oldestDeleted = $false
            if ([IO.File]::Exists($script:EventsPath + '.3')) {
                [IO.File]::Delete($script:EventsPath + '.3')
                $oldestDeleted = $true
            }
            for ($i = 2; $i -ge 1; $i--) {
                if ([IO.File]::Exists($script:EventsPath + ".$i")) {
                    while ($true) {
                        try {
                            [IO.File]::Move($script:EventsPath + ".$i", $script:EventsPath + '.' + ($i + 1))
                            break
                        } catch {
                            # DeleteFile leaves an open .3 delete-pending until its last
                            # reader closes. Reusing that name can fail even with delete
                            # sharing. Retry only this first move after our own deletion;
                            # no append/growth or further rotation occurs while waiting.
                            $cause = $_.Exception
                            while ($cause.InnerException) { $cause = $cause.InnerException }
                            $code = $cause.HResult -band 0xffff
                            if ($i -ne 2 -or -not $oldestDeleted -or $code -notin @(5, 32, 80, 183)) { throw }
                            Start-Sleep -Milliseconds 50
                        }
                    }
                }
            }
            if ([IO.File]::Exists($script:EventsPath)) { [IO.File]::Move($script:EventsPath, $script:EventsPath + '.1') }
            [IO.File]::WriteAllText($script:EventsPath, $seed, $script:Utf8)
        }
        [IO.File]::AppendAllText($script:EventsPath, $line, $script:Utf8)
    }

    function Read-Games {
        $games = @{}
        $processes = [Diagnostics.Process]::GetProcessesByName('Trackmania')
        try {
            $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
            foreach ($process in $processes) {
                if ($process.SessionId -ne $session) { continue }
                $birth = $process.StartTime.ToUniversalTime().ToString('o')
                $identity = '{0}|{1}' -f $process.Id, $birth
                $games[$identity] = @{ pid = [int]$process.Id; birth = $birth }
            }
        } finally { foreach ($process in $processes) { $process.Dispose() } }
        return $games
    }

    function Read-Boxes([hashtable]$Games, [hashtable]$Previous) {
        if ($nativeError) { throw $nativeError }
        $pidBirths = @{}
        foreach ($game in $Games.Values) { $pidBirths[[int]$game.pid] = $game.birth }
        $boxes = @{}
        foreach ($window in [TmCrashwatch.Native]::Scan([int[]]@($pidBirths.Keys))) {
            # Re-read creation time at the window scan as well: a PID could have been reused
            # since the process scan. A failure invalidates this scan, preserving old boxes.
            $process = [Diagnostics.Process]::GetProcessById($window.Pid)
            try { $birth = $process.StartTime.ToUniversalTime().ToString('o') }
            finally { $process.Dispose() }
            if ($pidBirths.ContainsKey($window.Pid) -and $pidBirths[$window.Pid] -ne $birth) {
                throw 'Trackmania process identity changed during the window scan.'
            }
            $key = '{0}|{1}|{2}' -f $window.Pid, $birth, $window.Handle
            $firstSeen = Get-UtcTimestamp
            if ($Previous.ContainsKey($key)) { $firstSeen = $Previous[$key].first_seen }
            $boxes[$key] = @{
                pid = [int]$window.Pid; birth = $birth; window_id = $window.Handle
                title = $window.Title; first_seen = $firstSeen
            }
        }
        return $boxes
    }

    function Read-CrashLogs {
        $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if (-not $documents -or -not [IO.Path]::IsPathRooted($documents)) { throw 'Cannot resolve Documents.' }
        $folder = [IO.Path]::Combine($documents, 'Trackmania')
        $logs = @{}
        # A missing directory is a failed source, not proof that crash-log monitoring works.
        $names = [IO.Directory]::GetFiles($folder, 'LogCrash_*.txt', [IO.SearchOption]::TopDirectoryOnly)
        foreach ($name in $names) {
            $file = Get-Item -LiteralPath $name -ErrorAction Stop
            $logs[$file.Name] = @{
                name = $file.Name; size = [long]$file.Length; mtime = $file.LastWriteTimeUtc.ToString('o')
            }
        }
        return $logs
    }

    $goodGames = @{}
    $goodBoxes = @{}
    $goodLogs = @{}
    $logsBaselined = $false
    $heartbeatClock = [Diagnostics.Stopwatch]::StartNew()
    $firstScan = $true
    while ($true) {
        $errors = New-Object 'Collections.Generic.List[object]'
        $events = New-Object 'Collections.Generic.List[object]'
        $gamesOk = $false
        try {
            $games = Read-Games
            foreach ($key in $goodGames.Keys) {
                if (-not $games.ContainsKey($key)) { $events.Add((New-Record 'game_exit' $goodGames[$key])) }
            }
            $goodGames = $games
            $gamesOk = $true
        } catch { $errors.Add(@{ source = 'processes'; error = $_.Exception.Message }) }

        if ($gamesOk) {
            try {
                $boxes = Read-Boxes $goodGames $goodBoxes
                foreach ($key in $boxes.Keys) {
                    if (-not $goodBoxes.ContainsKey($key)) { $events.Add((New-Record 'crash_box' $boxes[$key])) }
                }
                foreach ($key in $goodBoxes.Keys) {
                    if (-not $boxes.ContainsKey($key)) { $events.Add((New-Record 'crash_box_closed' $goodBoxes[$key])) }
                }
                $goodBoxes = $boxes
            } catch { $errors.Add(@{ source = 'windows'; error = $_.Exception.Message }) }
        } else { $errors.Add(@{ source = 'windows'; error = 'Skipped: process collection failed; keeping last good boxes.' }) }

        try {
            $logs = Read-CrashLogs
            if ($logsBaselined) {
                foreach ($name in $logs.Keys) {
                    if (-not $goodLogs.ContainsKey($name)) { $events.Add((New-Record 'crash_log' $logs[$name])) }
                }
            }
            $goodLogs = $logs
            $logsBaselined = $true
        } catch { $errors.Add(@{ source = 'crash_logs'; error = $_.Exception.Message }) }

        $heartbeat = New-Record 'heartbeat' @{
            interval_seconds = $HeartbeatSeconds; active_boxes = @($goodBoxes.Values)
            games = @($goodGames.Values); errors = @($errors.ToArray())
        }
        # Seed a rotation with this completed scan, not an outdated snapshot. Errors mark
        # retained state as degraded rather than asserting that an old box has disappeared.
        $script:SnapshotLine = ($heartbeat | ConvertTo-Json -Depth 8 -Compress) + "`n"
        if ($firstScan -or $heartbeatClock.Elapsed.TotalSeconds -ge $HeartbeatSeconds) {
            Write-Record $heartbeat
            $heartbeatClock.Restart()
            $firstScan = $false
        }
        foreach ($record in $events) { Write-Record $record }
        foreach ($errorInfo in $errors) { Write-Record (New-Record 'watcher_error' $errorInfo) }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    if ($null -ne $writerLock) { $writerLock.Dispose() }
}
