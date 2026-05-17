#!/usr/bin/env bash
# Install the HID Remapper auto-profile watcher LaunchAgent on macOS.
# Idempotent: re-running reinstalls cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/com.cmadriga.remapper-watch.plist.template"
LABEL="com.cmadriga.remapper-watch"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
UID_GUI="gui/$(id -u)"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: template not found at $TEMPLATE" >&2
    exit 1
fi

if [[ ! -x "$REPO_DIR/remapper-profile" ]]; then
    echo "error: $REPO_DIR/remapper-profile is missing or not executable" >&2
    exit 1
fi

mkdir -p "$PLIST_DIR"
mkdir -p "$HOME/Library/Logs"

# Bootout any previous instance so we can replace it cleanly.
if launchctl print "$UID_GUI/$LABEL" >/dev/null 2>&1; then
    echo "removing existing $LABEL..."
    launchctl bootout "$UID_GUI/$LABEL" || true
fi

# Render the plist with the resolved paths.
sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$TEMPLATE" > "$PLIST"

chmod 644 "$PLIST"

echo "installing $PLIST"
launchctl bootstrap "$UID_GUI" "$PLIST"
launchctl enable "$UID_GUI/$LABEL"

echo
echo "done. agent installed and active."
echo "  label : $LABEL"
echo "  plist : $PLIST"
echo "  log   : $HOME/Library/Logs/remapper-watch.log"
echo
echo "Test it: unplug and re-plug the HID Remapper, then run:"
echo "  tail -n 20 ~/Library/Logs/remapper-watch.log"
echo "  $REPO_DIR/remapper-profile status"
