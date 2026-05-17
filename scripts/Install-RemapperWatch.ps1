# Install the HID Remapper auto-profile watcher as a Scheduled Task that
# launches at user logon and stays running.
#
# Run this once in an *elevated* PowerShell window on the Windows machine:
#   powershell -ExecutionPolicy Bypass -File .\scripts\Install-RemapperWatch.ps1
#
# Uninstall:
#   Unregister-ScheduledTask -TaskName 'RemapperWatch' -Confirm:$false

$ErrorActionPreference = 'Stop'

$TaskName = 'RemapperWatch'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatchScript = Join-Path $ScriptDir 'remapper-watch.ps1'

if (-not (Test-Path $WatchScript)) {
    throw "Watch script not found: $WatchScript"
}

$Action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchScript`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 5

$Principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description 'Apply HID Remapper Windows profile when device connects.' | Out-Null

Write-Host "Installed scheduled task '$TaskName'."

# Start it now so we don't have to wait for next logon.
Start-ScheduledTask -TaskName $TaskName
Write-Host 'Task started. Log: %LOCALAPPDATA%\remapper-watch.log'
