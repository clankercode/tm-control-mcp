# Registers this checkout's watch.ps1. Keep the checkout at its current absolute path.
# No elevation, file copies, network access or game/desktop changes. Starts at next logon.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = 'tm-crashwatch-' + $sid
$watchPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'watch.ps1'))
$powerShell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell\v1.0\powershell.exe')
if (-not (Test-Path -LiteralPath $watchPath -PathType Leaf)) { throw "Missing watcher: $watchPath" }
if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { throw "Missing Windows PowerShell: $powerShell" }
if ($watchPath -match '["%\r\n]') { throw 'Watcher path cannot contain quotes, percent signs or newlines. Move this checkout to a supported path.' }
# Task Scheduler expands percent expressions even inside quotes; reject them above.
# This is an executable action, not cmd.exe: spaces, apostrophes, $, & and backticks
# are literal inside the double-quoted -File argument. The path ends in .ps1, not a slash.
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchPath + '"'
$description = 'tm-crashwatch per-user interactive watcher v1; owner=' + $sid + '; script=' + $watchPath

function Get-PrincipalSid([string]$UserId) {
    if ($UserId -match '^S-1-') { return ([Security.Principal.SecurityIdentifier]::new($UserId)).Value }
    return ([Security.Principal.NTAccount]::new($UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Assert-OwnedTask($Task) {
    $actions = @($Task.Actions)
    if ($Task.Description -cne $description -or (Get-PrincipalSid $Task.Principal.UserId) -ne $sid -or
        $Task.Principal.LogonType -ne 'Interactive' -or $Task.Principal.RunLevel -ne 'Limited' -or
        $actions.Count -ne 1 -or $actions[0].Execute -ine $powerShell -or $actions[0].Arguments -cne $arguments -or
        $actions[0].WorkingDirectory -ine $PSScriptRoot) {
        throw "Refusing to replace unrelated or modified task: \$taskName"
    }
}

# Cross-session guard shared with uninstall. Never -Force a task created in a race.
$configMutex = [Threading.Mutex]::new($false, ('Global\tm-crashwatch-config-' + $sid))
$held = $false
try {
    try { $held = $configMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another crashwatch installer/uninstaller is running.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $existing = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $taskName })
    if ($existing.Count -gt 1) { throw 'Ambiguous scheduled task identity.' }
    if ($existing.Count -eq 1) {
        Assert-OwnedTask $existing[0]
        $triggers = @($existing[0].Triggers)
        $settings = $existing[0].Settings
        if ($triggers.Count -ne 1 -or $triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' -or
            (Get-PrincipalSid $triggers[0].UserId) -ne $sid -or -not $triggers[0].Enabled -or
            -not $settings.Enabled -or -not $settings.Hidden -or -not $settings.StartWhenAvailable -or
            $settings.MultipleInstances -ne 'IgnoreNew' -or $settings.RestartCount -ne 999 -or
            $settings.RestartInterval -ne 'PT1M' -or $settings.ExecutionTimeLimit -ne 'PT0S' -or
            $settings.DisallowStartIfOnBatteries -or $settings.StopIfGoingOnBatteries) {
            throw 'Existing crashwatch task settings differ. Uninstall this task before reinstalling.'
        }
        Write-Output "Already installed: \$taskName. Use uninstall.ps1 before changing its definition or checkout path."
        return
    }
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
    # Interactive maps to TASK_LOGON_INTERACTIVE_TOKEN (XML InteractiveToken).
    # S4U/Password would run on a noninteractive desktop and cannot observe the game.
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description
    # No -Force: a preexisting colliding task must never be silently overwritten.
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task -ErrorAction Stop | Out-Null
    Write-Output "Installed: \$taskName. Runs hidden in this user's interactive session at next logon."
    Write-Output 'Logs: %LOCALAPPDATA%\tm-crashwatch\events.jsonl (current plus three backups).'
} finally {
    if ($held) { $configMutex.ReleaseMutex() }
    $configMutex.Dispose()
}
