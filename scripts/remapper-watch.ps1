# HID Remapper auto-profile watcher (Windows).
#
# Listens for the HID Remapper enumerating on USB (VID 0xCAFE, PID 0xBAF2)
# and writes profiles\win.json to the device whenever it arrives.
#
# Run via Scheduled Task at logon (see Install-RemapperWatch.ps1).
# Manual test:
#   powershell -ExecutionPolicy Bypass -File .\scripts\remapper-watch.ps1
#
# Logs to %LOCALAPPDATA%\remapper-watch.log.

param(
    [string]$Profile = 'win'
)

$ErrorActionPreference = 'Continue'

# Resolve repo root (parent of this script's directory).
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$ConfigTool = Join-Path $RepoDir 'config-tool'
$ProfileJson = Join-Path $RepoDir "profiles\$Profile.json"
$LogFile = Join-Path $env:LOCALAPPDATA 'remapper-watch.log'

# Pick a Python: prefer the repo's venv if present, else system 'py'/'python'.
$VenvPy = Join-Path $RepoDir '.venv-remapper\Scripts\python.exe'
if (Test-Path $VenvPy) {
    $Python = $VenvPy
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $Python = 'py'
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $Python = 'python'
} else {
    throw 'No Python interpreter found. Install Python 3 or create .venv-remapper.'
}

function Write-Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    "$ts [watch] $msg" | Out-File -Append -FilePath $LogFile -Encoding utf8
}

function Apply-Profile {
    if (-not (Test-Path $ProfileJson)) {
        Write-Log "ERROR: profile JSON not found: $ProfileJson"
        return
    }
    Write-Log "applying profile '$Profile' via $Python"
    Push-Location $ConfigTool
    try {
        $attempt = 0
        while ($attempt -lt 5) {
            $attempt++
            try {
                Get-Content -Raw $ProfileJson | & $Python set_config.py *>> $LogFile
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "applied profile '$Profile' on attempt $attempt"
                    return
                }
                Write-Log "attempt $attempt exit code $LASTEXITCODE; retrying in 1s"
            } catch {
                Write-Log "attempt $attempt threw: $_"
            }
            Start-Sleep -Seconds 1
        }
        Write-Log "ERROR: gave up after $attempt attempts"
    } finally {
        Pop-Location
    }
}

Write-Log "watcher starting; repo=$RepoDir profile=$Profile"

# Subscribe to WMI device-arrival events filtered to our VID/PID.
$VendorHex  = 'CAFE'
$ProductHex = 'BAF2'
$Query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.DeviceID LIKE '%VID_${VendorHex}&PID_${ProductHex}%'"

try {
    Register-WmiEvent -Query $Query -SourceIdentifier 'RemapperUsbArrival' -Action {
        Apply-Profile
    } | Out-Null
    Write-Log 'WMI subscription registered'
} catch {
    Write-Log "ERROR: failed to register WMI event: $_"
    throw
}

# If the device is already attached when we start, apply immediately so the
# first session is correct without waiting for the next replug.
$existing = Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE '%VID_${VendorHex}&PID_${ProductHex}%'" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log 'device already present at startup; applying once'
    Apply-Profile
}

# Stay alive forever (the Action runs in the background on the event).
while ($true) { Start-Sleep -Seconds 3600 }
