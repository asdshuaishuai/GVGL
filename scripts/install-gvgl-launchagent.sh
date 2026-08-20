#!/bin/bash
# Install gvgl as a per-user LaunchAgent (auto-start at login, keep-alive).
#
# Usage: scripts/install-gvgl-launchagent.sh [--binary PATH] [--socket PATH] [--reconcile SECONDS]
#
# TCC note: launchd-launched processes get their OWN accessibility identity.
# After installing, open System Settings > Privacy & Security > Accessibility
# and enable the gvgl binary itself (the path shown below). One-time step.

set -euo pipefail

DEFAULT_BINARY="$(cd "$(dirname "$0")/.." && pwd)/.build/release/gvgl"
BINARY="$DEFAULT_BINARY"
SOCKET=""
RECONCILE="3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --socket) SOCKET="$2"; shift 2 ;;
        --reconcile) RECONCILE="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -x "$BINARY" ]]; then
    echo "gvgl binary not found at: $BINARY" >&2
    echo "build it first: swift build -c release" >&2
    exit 1
fi
BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"

LAUNCH_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/.gvgl/logs"
PLIST="$LAUNCH_DIR/com.gvgl.daemon.plist"
mkdir -p "$LAUNCH_DIR" "$LOG_DIR"

ARGS=(--reconcile "$RECONCILE")
if [[ -n "$SOCKET" ]]; then
    ARGS+=(--socket "$SOCKET")
fi

# Build the <string> list for ProgramArguments.
ARG_XML="<string>$BINARY</string>"
for a in "${ARGS[@]}"; do
    ARG_XML+="
        <string>$a</string>"
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gvgl.daemon</string>
    <key>ProgramArguments</key>
    <array>
        ${ARG_XML}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/gvgl.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/gvgl.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl kickstart -k "gui/$(id -u)/com.gvgl.daemon" 2>/dev/null || true

echo "installed: $PLIST"
echo "binary:    $BINARY"
echo "logs:      $LOG_DIR"
echo ""
echo ">>> TCC (one-time): System Settings > Privacy & Security > Accessibility"
echo "    -> enable: $BINARY"
echo "socket: $(launchctl print gui/$(id -u)/com.gvgl.daemon 2>/dev/null | grep -m1 socket || echo 'default ~/.gvgl/gvgl.sock')"
