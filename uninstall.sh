#!/bin/bash
# Stop UC Doctor, remove it from login, and delete the app. Pass --logs to delete its logs too.
set -uo pipefail

LABEL="io.github.davidesqalv.ucdoctor"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x ucdoctor 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/UC Doctor.app"
defaults delete "$LABEL" 2>/dev/null

if [[ "${1:-}" == "--logs" ]]; then
    rm -rf "$HOME/Library/Logs/UC Doctor"
    echo "UC Doctor and its logs are removed."
else
    echo "UC Doctor is removed. Its logs are still in ~/Library/Logs/UC Doctor (run with --logs to delete them)."
fi
