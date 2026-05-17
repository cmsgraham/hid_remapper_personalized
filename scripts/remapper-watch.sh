#!/usr/bin/env bash
# Invoked by launchd whenever the HID Remapper enumerates on USB.
# Applies the given profile (default: name of this script's parent dir + "mac").
#
# Usage (manual test):
#   ./scripts/remapper-watch.sh mac
#
# All output is timestamped and appended to ~/Library/Logs/remapper-watch.log.

set -uo pipefail

PROFILE="${1:-mac}"

# Resolve repo root (parent of this script's directory) so the agent keeps
# working regardless of where the user puts the folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_TOOL="$REPO_DIR/remapper-profile"
LOG_FILE="$HOME/Library/Logs/remapper-watch.log"

log() {
    printf '%s [watch] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG_FILE"
}

log "trigger received; profile=$PROFILE pid=$$"

if [[ ! -x "$PROFILE_TOOL" ]]; then
    log "ERROR: $PROFILE_TOOL not found or not executable"
    exit 1
fi

# Give the device a moment to finish enumerating + present its feature reports.
sleep 0.5

# Retry up to 5 times in case the device isn't ready instantly.
attempt=0
while (( attempt < 5 )); do
    attempt=$((attempt + 1))
    if "$PROFILE_TOOL" "$PROFILE" >> "$LOG_FILE" 2>&1; then
        log "applied profile '$PROFILE' on attempt $attempt"
        exit 0
    fi
    log "attempt $attempt failed; retrying in 1s"
    sleep 1
done

log "ERROR: gave up applying profile '$PROFILE' after $attempt attempts"
exit 2
