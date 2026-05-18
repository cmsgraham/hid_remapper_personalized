# HID Remapper — Auto-Profile Watchers

This folder contains scripts that **automatically apply the right profile** to the
HID Remapper dongle the moment it shows up on the USB bus.

- **Mac** → applies [`profiles/mac.json`](../profiles/mac.json) via a `launchd`
  LaunchAgent that listens to IOKit USB-attach events.
- **Windows** → applies [`profiles/win.json`](../profiles/win.json) via a
  long-running PowerShell watcher launched by a per-user Scheduled Task at
  logon, listening to WMI `__InstanceCreationEvent` notifications.

Both watchers match the dongle by **VID `0xCAFE` / PID `0xBAF2`** (the
HID Remapper, nicknamed "GG9O" in this repo). Both are event-driven — **no
polling, no CPU usage when idle**.

The Windows watcher specifically is hardened against the failure modes
we've actually seen in the field:

- Debounces the 4 back-to-back PnP arrival events Windows fires (one per HID
  interface) into a single apply.
- Waits for the config HID interface to actually be openable before writing
  (fixes a race where the device appears in PnP but isn't yet usable).
- Verifies success via both the process exit code **and** a `SET_CONFIG_OK`
  marker emitted by `set_config.py` after `PERSIST_CONFIG + RESUME`.
- Logs `set_config.py` stdout/stderr line by line. Retries with exponential
  backoff (up to 6 attempts).
- Emits a heartbeat every 5 minutes and auto-recovers if the WMI subscription
  dies.

Repo layout this README assumes:

```
hid-remapper/
├── config-tool/            # upstream python tools (set_config.py, get_config.py)
├── profiles/
│   ├── mac.json
│   └── win.json
├── remapper-profile        # bash CLI (status / list / apply)
├── remapper-profile-status.py
└── scripts/                # <-- you are here
    ├── remapper-watch.sh                       # Mac: trigger handler
    ├── com.cmadriga.remapper-watch.plist.template
    ├── install-watch-mac.sh
    ├── uninstall-watch-mac.sh
    ├── remapper-watch.ps1                      # Windows: long-running watcher
    └── Install-RemapperWatch.ps1
```

---

## Prerequisites (both OSes)

1. Repository cloned somewhere stable (it must stay at that path because the
   watcher scripts reference it by absolute path).
2. Python 3.9+ available.
3. The `hid` Python package (binds to `hidapi`) installed inside a virtualenv
   named `.venv-remapper/` at the repo root. The watcher auto-discovers it.

---

## macOS install

### One-time setup

```bash
cd /path/to/hid-remapper

# 1. hidapi (native lib) and the python binding
brew install hidapi
python3 -m venv .venv-remapper
.venv-remapper/bin/pip install hid

# 2. Mark scripts executable (only needed once after a fresh clone)
chmod +x scripts/*.sh remapper-profile

# 3. Install the LaunchAgent
./scripts/install-watch-mac.sh
```

`install-watch-mac.sh` does the following:

- Renders [`scripts/com.cmadriga.remapper-watch.plist.template`](com.cmadriga.remapper-watch.plist.template)
  by substituting `__REPO_DIR__` and `__HOME__` with the current repo path and
  `$HOME`, writing the result to
  `~/Library/LaunchAgents/com.cmadriga.remapper-watch.plist`.
- Calls `launchctl bootout` on any previous instance (idempotent).
- Calls `launchctl bootstrap gui/$(id -u) <plist>` and `launchctl enable`
  to register and activate it.
- `RunAtLoad=true` fires it once immediately so the profile is set even if the
  dongle is already plugged in.

### How the trigger works

The plist contains:

```xml
<key>LaunchEvents</key>
<dict>
  <key>com.apple.iokit.matching</key>
  <dict>
    <key>com.cmadriga.remapper-usb-arrival</key>
    <dict>
      <key>IOProviderClass</key><string>IOUSBDevice</string>
      <key>idVendor</key>      <integer>51966</integer>   <!-- 0xCAFE -->
      <key>idProduct</key>     <integer>47858</integer>   <!-- 0xBAF2 -->
    </dict>
  </dict>
</dict>
```

When `launchd` sees any matching USB device attach event it launches
[`remapper-watch.sh`](remapper-watch.sh) with arg `mac`, which calls
`remapper-profile mac`, which pipes `profiles/mac.json` into
`config-tool/set_config.py` and persists it to the dongle. The shell script
retries up to 5× with 1 s back-off because the device may not be ready to
answer feature reports for the first ~0.5 s after enumeration.

### Verify

```bash
# Confirm the agent is loaded
launchctl print "gui/$(id -u)/com.cmadriga.remapper-watch" | head -5

# Live-tail the log while you unplug + replug the dongle
tail -f ~/Library/Logs/remapper-watch.log

# Confirm the device fingerprint matches the mac profile
./remapper-profile status
```

Expected log entries each time you plug in:

```
2026-05-16T19:00:45 [watch] trigger received; profile=mac pid=14939
applying profile: mac (/path/to/hid-remapper/profiles/mac.json)
done. active profile: mac
2026-05-16T19:00:47 [watch] applied profile 'mac' on attempt 1
```

### Uninstall (Mac)

```bash
./scripts/uninstall-watch-mac.sh
```

Removes the plist and runs `launchctl bootout`.

### Common Mac gotchas

| Symptom | Fix |
|---|---|
| `command not found: launchctl bootstrap` | macOS too old. Use `launchctl load -w <plist>` instead. |
| Agent shows `state = not running` and never fires | Check `~/Library/Logs/remapper-watch.log` for path errors; re-run `install-watch-mac.sh` after moving the repo. |
| Trigger fires but `remapper-profile` errors with "No HID device found" | The `.venv-remapper` is missing or `hid` not installed — recreate per step 1. |
| Repo path changed | Re-run `./scripts/install-watch-mac.sh`; the absolute paths in the plist get re-rendered. |

---

## Windows install

### One-time setup

Open **PowerShell** (regular, not Admin) at the repo root.

```powershell
cd C:\path\to\hid-remapper

# 1. Python venv + hid (hidapi.dll ships inside the wheel on Windows)
py -m venv .venv-remapper
.venv-remapper\Scripts\pip install hid

# 2. The repo's symlink config-tool-web\profiles works only on Mac/Linux.
#    Replace it with a real directory copy so the web UI can serve them.
if (Test-Path config-tool-web\profiles) { Remove-Item config-tool-web\profiles -Force -Recurse }
Copy-Item profiles config-tool-web\profiles -Recurse

# 3. Register the Scheduled Task that hosts the watcher
powershell -ExecutionPolicy Bypass -File .\scripts\Install-RemapperWatch.ps1
```

`Install-RemapperWatch.ps1` registers a per-user Scheduled Task named
`RemapperWatch` with:

- **Trigger**: `At log on of <current user>`.
- **Action**: `powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File <repo>\scripts\remapper-watch.ps1`.
- **Settings**: `AllowStartIfOnBatteries`, `ExecutionTimeLimit = 0` (never kill),
  restart 5× with 1 minute interval if it crashes.
- Immediately calls `Start-ScheduledTask -TaskName RemapperWatch` so you don't
  have to log out / back in.

### How the trigger works

[`remapper-watch.ps1`](remapper-watch.ps1) is a single long-running PowerShell
process. It was deliberately built to be **bulletproof** against the failure
modes we hit in practice (runspace death, enumeration races, silent partial
writes). High-level flow:

1. **Resolves the Python interpreter:**
   `.venv-remapper\Scripts\python.exe` if present, else `py`, else `python`.
2. **Registers a WMI subscription** (no `-Action` callback — events are
   queued and consumed by the main loop instead, which avoids the silent
   runspace-death failure mode of `Register-WmiEvent -Action`):
   ```sql
   SELECT * FROM __InstanceCreationEvent WITHIN 2
   WHERE TargetInstance ISA 'Win32_PnPEntity'
     AND TargetInstance.DeviceID LIKE '%VID_CAFE&PID_BAF2%'
   ```
3. **If the dongle is already attached at startup**, it applies the profile
   once immediately.
4. **Main loop** uses `Wait-Event` with a 30 s timeout:
   - On an arrival event: drains all queued events, sleeps a **2 s debounce
     window**, drains any further events that arrived during it, then applies
     the profile once. This collapses the 4 back-to-back PnP events that
     Windows fires (one per HID interface) into a single apply.
   - Every **5 minutes** it logs a heartbeat (`subscription_alive=True/False`)
     and **re-registers the WMI subscription** automatically if it has died.
5. **`Invoke-SetConfig` (apply with verification)**:
   - Runs an inline Python **readiness probe** that calls `hid.enumerate()`
     *and actually opens* the config HID interface. Retries for up to 20 s
     before giving up on that attempt — fixes the race where the device is
     in PnP but not yet usable.
   - Pipes `profiles\win.json` into `config-tool\set_config.py`, capturing
     stdout **and** stderr separately and writing them to the log.
   - Treats success as **exit 0 AND** the `SET_CONFIG_OK version=… mappings=…`
     marker printed by `set_config.py` after `PERSIST_CONFIG + RESUME`. A
     bare exit 0 without the marker is treated as failure and retried.
   - Retries with exponential backoff (2 → 4 → 8 → 16 s, capped at 16 s),
     up to 6 attempts.
6. **Logging:** structured `[INFO] / [WARN] / [ERROR]` lines so failures are
   never silent.

### Verify

```powershell
Get-ScheduledTask -TaskName RemapperWatch | Get-ScheduledTaskInfo

# Live-tail the log
Get-Content -Wait "$env:LOCALAPPDATA\remapper-watch.log"

# Status check (same fingerprint logic as the Mac CLI)
py .\remapper-profile-status.py
```

Unplug / replug the dongle — within a few seconds you should see a block like:

```
[INFO] USB arrival burst received (4 event(s)); debouncing 2s
[INFO] absorbed 0 additional event(s) during debounce
[INFO] applying profile 'win'
[INFO] set_config stderr: SET_CONFIG_OK version=18 mappings=9 macros=32 expressions=8 quirks=0
[INFO] applied profile 'win' on attempt 1
```

And, while idle, a heartbeat every 5 minutes:

```
[INFO] heartbeat; subscription_alive=True
```

### Uninstall (Windows)

```powershell
Stop-ScheduledTask  -TaskName RemapperWatch -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName RemapperWatch -Confirm:$false
```

### Common Windows gotchas

| Symptom | Fix |
|---|---|
| `Cannot be loaded because running scripts is disabled` | Always invoke with `-ExecutionPolicy Bypass`, as the installer does. Do **not** globally change the system policy. |
| Watcher never fires | Open Task Scheduler → `RemapperWatch` → History tab. Look for the last run's exit code. Most common cause: repo moved, paths now wrong — re-run `Install-RemapperWatch.ps1`. |
| Log stops at startup, no heartbeats | Process died. Check the History tab and restart with `Stop-ScheduledTask -TaskName RemapperWatch; Start-ScheduledTask -TaskName RemapperWatch`. |
| Apply log shows `exit 0 but SET_CONFIG_OK marker missing` | `set_config.py` crashed late (often a stale HID handle mid-enumeration). The watcher will retry automatically; if it persists, re-plug the dongle. |
| `python: command not found` inside watcher log | Create the `.venv-remapper` (step 1) or install Python from python.org and re-register the task. |
| Profile applied but keystrokes still wrong | Verify it's the `win` profile that was applied: `Get-Content "$env:LOCALAPPDATA\remapper-watch.log" -Tail 10`. Then sanity-check `profiles\win.json` matches what you want. |
| Symlink `config-tool-web\profiles` shows as a broken file | Run step 2 above to replace it with a real folder copy. |

---

## Cross-machine sync of profile JSONs

The two profile files are the source of truth on each machine. To keep them
in sync between Mac and Windows you have three good options:

1. **git** (recommended — what this repo is set up for):
   ```bash
   git add profiles/*.json && git commit -m "update profile" && git push
   ```
   Then `git pull` on the other machine.
2. **iCloud Drive / OneDrive / Dropbox**: place the repo (or just the
   `profiles/` directory) inside the synced folder. Watchers will pick up
   the new content on the next USB-attach event without restart.
3. **Manual copy** via scp / USB stick — fine for one-off changes.

When you regenerate a profile on either side (e.g. by saving from the web UI
or running `./remapper-profile save <name>`), commit + push. The other machine
picks up the new mappings the next time you `git pull` and re-plug the dongle.

---

## Quick reference

| Task | Mac | Windows |
|---|---|---|
| Install watcher | `./scripts/install-watch-mac.sh` | `powershell -ExecutionPolicy Bypass -File .\scripts\Install-RemapperWatch.ps1` |
| Uninstall watcher | `./scripts/uninstall-watch-mac.sh` | `Unregister-ScheduledTask -TaskName RemapperWatch -Confirm:$false` |
| Watcher log | `~/Library/Logs/remapper-watch.log` | `%LOCALAPPDATA%\remapper-watch.log` |
| Apply profile manually | `./remapper-profile mac` | `Get-Content profiles\win.json \| .venv-remapper\Scripts\python config-tool\set_config.py` |
| Status / fingerprint | `./remapper-profile status` | `py .\remapper-profile-status.py` |
| Web UI | `cd config-tool-web && python3 -m http.server 8765` → http://localhost:8765/ | same |

---

## What to change if you fork this for a new device

1. Replace VID/PID `51966` / `47858` in
   [`com.cmadriga.remapper-watch.plist.template`](com.cmadriga.remapper-watch.plist.template)
   and the WMI filter `VID_CAFE&PID_BAF2` in
   [`remapper-watch.ps1`](remapper-watch.ps1).
2. Update [`profiles/`](../profiles/) with your own JSON dumps.
3. Re-run the install scripts.
