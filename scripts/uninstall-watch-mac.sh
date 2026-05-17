#!/usr/bin/env bash
# Uninstall the HID Remapper auto-profile watcher LaunchAgent on macOS.

set -euo pipefail

LABEL="com.cmadriga.remapper-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_GUI="gui/$(id -u)"

if launchctl print "$UID_GUI/$LABEL" >/dev/null 2>&1; then
    echo "booting out $LABEL..."
    launchctl bootout "$UID_GUI/$LABEL" || true
fi

if [[ -f "$PLIST" ]]; then
    echo "removing $PLIST"
    rm -f "$PLIST"
fi

echo "done. agent uninstalled."
echo "(log file kept at ~/Library/Logs/remapper-watch.log)"
