#!/bin/bash
# 构建 fanctl 命令行工具和 FanBar 菜单栏应用
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build (release)…"
swift build -c release --product fanctl
swift build -c release --product FanBar

APP="build/FanBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FanBar "$APP/Contents/MacOS/FanBar"
cp .build/release/fanctl "$APP/Contents/Resources/fanctl"
chmod +x "$APP/Contents/MacOS/FanBar" "$APP/Contents/Resources/fanctl"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.macfancontrol.fanbar</string>
    <key>CFBundleName</key><string>MacFanControl</string>
    <key>CFBundleDisplayName</key><string>MacFanControl 风扇控制</string>
    <key>CFBundleExecutable</key><string>FanBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

# 优先用固定证书签名(TCC 授权才能跨构建保持),证书不存在则退回临时签名
cp build-resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force --sign "Local Dev Tools" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 构建完成:"
echo "   菜单栏应用: $(pwd)/$APP"
echo "   命令行工具: $(pwd)/.build/release/fanctl"
echo ""
echo "下一步: 打开 $APP,点菜单栏 🌡 图标,安装守护进程即可"
echo "       (或手动:sudo $(pwd)/.build/release/fanctl install)"
