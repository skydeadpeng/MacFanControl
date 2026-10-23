#!/bin/bash
# 编译桌面小组件扩展(WidgetKit,macOS 14+)并组装 FanWidget.appex
# 不走 SwiftPM:包平台是 macOS 13,而桌面小组件需要 14+,直接 swiftc 编译
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
OUT="build/widget"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> swiftc 编译小组件(universal)…"
SRCS=(Sources/Widget/FanWidget.swift Sources/SMCKit/*.swift Sources/FanBar/SystemStats.swift)
FLAGS=(-O -whole-module-optimization -parse-as-library -sdk "$SDK"
       -framework WidgetKit -framework SwiftUI -framework IOKit)
swiftc "${FLAGS[@]}" -target arm64-apple-macos14.0 "${SRCS[@]}" -o "$OUT/FanWidget-arm64"
swiftc "${FLAGS[@]}" -target x86_64-apple-macos14.0 "${SRCS[@]}" -o "$OUT/FanWidget-x86_64"
lipo -create -output "$OUT/FanWidget" "$OUT/FanWidget-arm64" "$OUT/FanWidget-x86_64"
rm -f "$OUT/FanWidget-arm64" "$OUT/FanWidget-x86_64"

APPEX="$OUT/FanWidget.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$OUT/FanWidget" "$APPEX/Contents/MacOS/FanWidget"

cat > "$APPEX/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.macfancontrol.fanbar.widget</string>
    <key>CFBundleName</key><string>FanWidget</string>
    <key>CFBundleDisplayName</key><string>FanBar 小组件</string>
    <key>CFBundleExecutable</key><string>FanWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF
sed -i '' "s/VERSION_PLACEHOLDER/${WIDGET_VERSION:-3.0}/" "$APPEX/Contents/Info.plist"

echo "✅ 小组件已构建: $APPEX"
