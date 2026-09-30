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
echo "socket: $(launchctl print gui/$(id -u)/com.gvgl.daemon 2>/dev/null | grep -m1 socket || echo 'default ~/.gvgl/gvgl.sock')"
echo ""

# --- TCC: actually check, don't just remind -------------------------------
# A passive "one-time step" note gets ignored, and the failure mode is silent:
# without it the daemon starts fine and every frame just reports
# permission_denied, which reads like "the desktop is empty".
#
# The check runs the binary that was just installed, because TCC identity is
# per binary path — a different path (or a rebuild) is a different identity.
#
# Guard on flag support first: an older binary does not know --check-permission
# and would ignore it and start a daemon instead, hanging this script forever.
if "$BINARY" --help 2>&1 | grep -q -- '--check-permission'; then
    PERMISSION_STATE=granted
    "$BINARY" --check-permission >/dev/null 2>&1 || PERMISSION_STATE=denied
else
    echo "note: this gvgl binary predates --check-permission; cannot verify TCC automatically." >&2
    PERMISSION_STATE=unknown
fi

if [[ "$PERMISSION_STATE" == "granted" ]]; then
    echo "TCC: accessibility permission granted."
    echo "自检：$BINARY --check-permission"
    exit 0
fi

if [[ "$PERMISSION_STATE" == "unknown" ]]; then
    cat >&2 <<EOF

  ############################################################
  #  辅助功能权限未自动验证 — 请手动确认                     #
  ############################################################

  系统设置 › 隐私与安全性 › 辅助功能 中启用：
      $BINARY
EOF
    exit 0
fi

cat >&2 <<EOF

  ############################################################
  #  辅助功能权限未授予 — 桌面内容将全部报告 permission_denied  #
  ############################################################

  系统设置 › 隐私与安全性 › 辅助功能 中启用：
      $BINARY

  自检命令（授权后应输出 granted / 退出码 0）：
      $BINARY --check-permission

  注意：授权绑定到这个二进制路径。重新 swift build 之后可能需要
  重新授权一次 —— 重新构建后请再跑一次上面的自检。
EOF
if [[ "${GVGL_NO_OPEN_SETTINGS:-0}" != "1" ]]; then
    read -r -p "  现在打开系统设置吗？[Y/n] " reply
    case "${reply:-Y}" in
        [nN]*) ;;
        *) open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true ;;
    esac
fi
exit 3
