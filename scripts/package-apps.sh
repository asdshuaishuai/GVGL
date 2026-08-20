#!/bin/bash
# Packages the GUI into a single .app bundle:
#   dist/GVGL.app — 审查台窗口 + 菜单栏监控 + 内嵌守护进程助手
# Then optionally installs it to /Applications.
#
# Usage: scripts/package-apps.sh [--install]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release 2>/dev/null | tail -1 || true

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> 生成图标"
swift scripts/make-icon.swift "$DIST" >/dev/null

write_plist() { # $1=app dir  $2=exec  $3=bundle id  $4=name  $5=display
    cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$4</string>
    <key>CFBundleDisplayName</key><string>$5</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>GVGL — 几何虚拟桌面</string>
</dict>
</plist>
EOF
}

echo "==> GVGL.app（审查台 + 菜单栏监控 + 守护进程助手）"
APP="$DIST/GVGL.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/gvglui "$APP/Contents/MacOS/gvglui"
cp .build/release/gvgl "$APP/Contents/Resources/gvgl"   # 内嵌守护进程助手
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
write_plist "$APP" gvglui com.gvgl.app GVGL "GVGL"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo ""
echo "已生成：$APP"

if [[ "${1:-}" == "--install" ]]; then
    echo ""
    echo "==> 安装到 /Applications（移除旧版拆分应用）"
    rm -rf "/Applications/GVGL.app" \
           "/Applications/GVGL Console.app" \
           "/Applications/GVGL Monitor.app"
    cp -R "$APP" /Applications/
    echo "已安装。TCC 一次性授权：系统设置 → 辅助功能 → 勾选「GVGL」（含其内嵌守护进程）。"
fi
