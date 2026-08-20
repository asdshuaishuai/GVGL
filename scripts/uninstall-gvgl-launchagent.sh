#!/bin/bash
# Uninstall the gvgl LaunchAgent.
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.gvgl.daemon.plist"

if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $PLIST"
else
    echo "no LaunchAgent installed at $PLIST"
fi
echo "done (socket file at ~/.gvgl/gvgl.sock is left in place)"
