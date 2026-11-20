# Removes only the current user's task pointing to this checkout. Keeps all logs and files.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This uninstaller requires Windows.' }

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = 'tm-crashwatch-' + $sid
$watchPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'watch.ps1'))
$powerShell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell\v1.0\powershell.exe')
if ($watchPath -match '["%\r\n]') { throw 'Watcher path cannot contain quotes, percent signs or newlines. Move this checkout to a supported path.' }
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
        throw "Refusing to stop or remove unrelated or modified task: \$taskName"
    }
}

$configMutex = [Threading.Mutex]::new($false, ('Global\tm-crashwatch-config-' + $sid))
$held = $false
try {
    try { $held = $configMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another crashwatch installer/uninstaller is running.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $existing = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $taskName })
    if ($existing.Count -gt 1) { throw 'Ambiguous scheduled task identity.' }
    if ($existing.Count -eq 0) { Write-Output "Not installed: \$taskName. Logs retained."; return }
    Assert-OwnedTask $existing[0]
    Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    Write-Output "Uninstalled: \$taskName. All logs and repository files retained."
} finally {
    if ($held) { $configMutex.ReleaseMutex() }
    $configMutex.Dispose()
}
