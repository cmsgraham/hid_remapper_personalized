# HID Remapper auto-profile watcher (Windows) - bulletproof edition.
#
# - Listens for USB arrival events for VID 0xCAFE / PID 0xBAF2.
# - Debounces the 4 back-to-back interface-enumeration events into one apply.
# - Waits for the config HID interface to actually be openable before writing.
# - Retries on failure with backoff.
# - Verifies set_config.py reached its SET_CONFIG_OK marker (not just exit 0).
# - Emits a heartbeat every 5 min and self-heals if the WMI subscription dies.
# - Runs via Scheduled Task at logon (see Install-RemapperWatch.ps1).
#
# Manual test:
#   powershell -ExecutionPolicy Bypass -File .\scripts\remapper-watch.ps1
#
# Logs to %LOCALAPPDATA%\remapper-watch.log.

param(
    [string]$Profile = 'win'
)

$ErrorActionPreference = 'Continue'

# --- Paths / interpreter ----------------------------------------------------

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir     = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$ConfigTool  = Join-Path $RepoDir 'config-tool'
$ProfileJson = Join-Path $RepoDir "profiles\$Profile.json"
$LogFile     = Join-Path $env:LOCALAPPDATA 'remapper-watch.log'

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

$VendorHex   = 'CAFE'
$ProductHex  = 'BAF2'
$DeviceLike  = "%VID_${VendorHex}&PID_${ProductHex}%"
$SourceId    = 'RemapperUsbArrival'
$WmiQuery    = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.DeviceID LIKE '$DeviceLike'"

# Tunables.
$DebounceSeconds      = 2      # collect arrival events for this long, then apply once
$ReadyTimeoutSeconds  = 20     # how long to wait for HID config iface to be openable
$ApplyMaxAttempts     = 6      # retry count on transient failures
$ApplyBackoffSeconds  = 2      # base backoff between retries (doubled each time, capped)
$HeartbeatSeconds     = 300    # log "alive" every N seconds and verify subscription
$PollIntervalSeconds  = 15     # fallback poll: detect device arrival when WMI event is missed

# --- Logging ----------------------------------------------------------------

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    "$ts [watch][$Level] $Message" | Out-File -Append -FilePath $LogFile -Encoding utf8
}

function Log-Info  { param([string]$m) Write-Log 'INFO'  $m }
function Log-Warn  { param([string]$m) Write-Log 'WARN'  $m }
function Log-Error { param([string]$m) Write-Log 'ERROR' $m }

# --- Device presence probe (lightweight) ------------------------------------

# Returns $true if the PnP entity is enumerated by Windows (no HID open needed).
function Test-DevicePresent {
    $null -ne (Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE '$DeviceLike'" -ErrorAction SilentlyContinue)
}

# --- HID readiness probe ----------------------------------------------------

# Returns $true if the config HID interface is enumerated and openable.
function Test-ConfigInterfaceReady {
    $probe = @'
import sys
try:
    import hid
    devs = [d for d in hid.enumerate() if d.get("usage_page") == 0xFF00 and d.get("usage") == 0x0020]
    if not devs:
        sys.exit(2)
    # Try to actually open it - enumeration can list a path that is not yet openable.
    h = hid.Device(path=devs[0]["path"])
    h.close()
    sys.exit(0)
except SystemExit:
    raise
except Exception as e:
    sys.stderr.write("probe error: %r\n" % (e,))
    sys.exit(3)
'@
    Push-Location $ConfigTool
    try {
        $probe | & $Python - *> $null 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        Pop-Location
    }
}

function Wait-ForDeviceReady {
    param([int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-ConfigInterfaceReady) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# --- Apply --------------------------------------------------------------------

function Invoke-SetConfig {
    if (-not (Test-Path $ProfileJson)) {
        Log-Error "profile JSON not found: $ProfileJson"
        return $false
    }

    Push-Location $ConfigTool
    try {
        $attempt = 0
        $delay   = $ApplyBackoffSeconds
        while ($attempt -lt $ApplyMaxAttempts) {
            $attempt++

            if (-not (Wait-ForDeviceReady -TimeoutSeconds $ReadyTimeoutSeconds)) {
                Log-Warn "attempt $attempt - config HID iface not ready within ${ReadyTimeoutSeconds}s"
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 16)
                continue
            }

            $stdoutFile = [IO.Path]::GetTempFileName()
            $stderrFile = [IO.Path]::GetTempFileName()
            try {
                # Pipe profile JSON to set_config.py and capture stdout/stderr separately
                # so we can both log them and inspect for the SET_CONFIG_OK marker.
                $proc = Start-Process -FilePath $Python `
                    -ArgumentList @('set_config.py') `
                    -WorkingDirectory $ConfigTool `
                    -RedirectStandardInput $ProfileJson `
                    -RedirectStandardOutput $stdoutFile `
                    -RedirectStandardError $stderrFile `
                    -NoNewWindow -PassThru -Wait
                $exit   = $proc.ExitCode
                $stdout = (Get-Content -Raw -ErrorAction SilentlyContinue $stdoutFile)
                $stderr = (Get-Content -Raw -ErrorAction SilentlyContinue $stderrFile)
            } finally {
                Remove-Item -ErrorAction SilentlyContinue $stdoutFile, $stderrFile
            }

            if ($stdout) {
                foreach ($line in ($stdout -split "`r?`n")) {
                    if ($line) { Log-Info "set_config stdout: $line" }
                }
            }
            if ($stderr) {
                foreach ($line in ($stderr -split "`r?`n")) {
                    if ($line) { Log-Info "set_config stderr: $line" }
                }
            }

            $okMarker = ($stderr -match 'SET_CONFIG_OK') -or ($stdout -match 'SET_CONFIG_OK')
            if ($exit -eq 0 -and $okMarker) {
                Log-Info "applied profile '$Profile' on attempt $attempt"
                return $true
            }

            if ($exit -eq 0 -and -not $okMarker) {
                Log-Warn "attempt $attempt - exit 0 but SET_CONFIG_OK marker missing; treating as failure"
            } else {
                Log-Warn "attempt $attempt - exit code $exit"
            }

            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 16)
        }
        Log-Error "gave up applying profile '$Profile' after $ApplyMaxAttempts attempts"
        return $false
    } finally {
        Pop-Location
    }
}

# --- WMI subscription -------------------------------------------------------

function Register-RemapperSubscription {
    Unregister-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
    Get-EventSubscriber -SourceIdentifier $SourceId -ErrorAction SilentlyContinue |
        ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
    try {
        # Important: NO -Action. Events are queued and we Wait-Event them in
        # the main loop. This avoids the silent runspace-death failure mode of
        # -Action callbacks.
        Register-WmiEvent -Query $WmiQuery -SourceIdentifier $SourceId | Out-Null
        Log-Info "WMI subscription registered"
        return $true
    } catch {
        Log-Error "failed to register WMI event: $_"
        return $false
    }
}

function Test-SubscriptionAlive {
    [bool](Get-EventSubscriber -SourceIdentifier $SourceId -ErrorAction SilentlyContinue)
}

# --- Main -------------------------------------------------------------------

Log-Info "watcher starting; repo=$RepoDir profile=$Profile python=$Python"

if (-not (Register-RemapperSubscription)) {
    throw 'Could not register WMI subscription; aborting.'
}

# If the device is already present at startup, apply once.
$existing = Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE '$DeviceLike'" -ErrorAction SilentlyContinue
if ($existing) {
    Log-Info "device already present at startup; applying once"
    [void](Invoke-SetConfig)
}

# Polling fallback state.
$pollDevicePresent = [bool]$existing
$lastPollCheck     = Get-Date

$lastHeartbeat = Get-Date

while ($true) {
    # Wait up to $PollIntervalSeconds for an arrival event. Short timeout lets
    # us poll for device presence and run heartbeat checks regularly.
    $evt = Wait-Event -SourceIdentifier $SourceId -Timeout $PollIntervalSeconds
    $appliedThisIteration = $false

    if ($evt) {
        # Drain everything currently queued.
        $count = 0
        do {
            $count++
            Remove-Event -EventIdentifier $evt.EventIdentifier
            $evt = Get-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue | Select-Object -First 1
        } while ($evt)

        Log-Info "USB arrival burst received ($count event(s)); debouncing ${DebounceSeconds}s"
        Start-Sleep -Seconds $DebounceSeconds

        # Drain any additional events that arrived during debounce.
        $more = 0
        while ($e = Get-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue | Select-Object -First 1) {
            Remove-Event -EventIdentifier $e.EventIdentifier
            $more++
        }
        if ($more -gt 0) {
            Log-Info "absorbed $more additional event(s) during debounce"
        }

        Log-Info "applying profile '$Profile'"
        [void](Invoke-SetConfig)
        $appliedThisIteration = $true
        $pollDevicePresent    = $true   # device is present
        $lastPollCheck        = Get-Date
    }

    # Polling fallback: catch device arrivals that the WMI subscription missed
    # (common with KVM switches that keep USB enumerated on the Windows side).
    if (-not $appliedThisIteration -and
        ((Get-Date) - $lastPollCheck).TotalSeconds -ge $PollIntervalSeconds) {
        $nowPresent = Test-DevicePresent
        if ($nowPresent -and -not $pollDevicePresent) {
            Log-Info "poll: device appeared without WMI event; applying profile '$Profile'"
            [void](Invoke-SetConfig)
        } elseif (-not $nowPresent -and $pollDevicePresent) {
            Log-Info "poll: device is no longer present"
        }
        $pollDevicePresent = $nowPresent
        $lastPollCheck     = Get-Date
    }

    # Heartbeat + subscription self-heal.
    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
        $alive = Test-SubscriptionAlive
        Log-Info "heartbeat; subscription_alive=$alive"
        if (-not $alive) {
            Log-Warn "subscription is dead; re-registering"
            [void](Register-RemapperSubscription)
        }
        $lastHeartbeat = Get-Date
    }
}
