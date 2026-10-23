#!/bin/bash
# 打包分发版:通用二进制(Apple Silicon + Intel)+ DMG 安装包
set -euo pipefail
cd "$(dirname "$0")"
VERSION="2.2"

echo "==> 编译通用二进制(arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 --product FanBar
swift build -c release --arch arm64 --arch x86_64 --product fanctl

DIST="dist/MacFanControl"
rm -rf "$DIST"
mkdir -p "$DIST"
APP="$DIST/FanBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN=".build/out/Products/Release"
[ -d "$BIN" ] || BIN=".build/apple/Products/Release"
[ -d "$BIN" ] || { echo "❌ 找不到构建产物目录(.build/out 或 .build/apple)"; exit 1; }
cp "$BIN/FanBar" "$APP/Contents/MacOS/FanBar"
cp "$BIN/fanctl" "$APP/Contents/Resources/fanctl"
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
    <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/" "$APP/Contents/Info.plist"

cp build-resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force --sign "Local Dev Tools" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> 架构检查"
lipo -info "$APP/Contents/MacOS/FanBar"

cat > "$DIST/使用说明.txt" <<'EOF'
MacFanControl 风扇控制 v2.2 —— 免费开源的 Mac 风扇温度控制与系统监控

【安装】
1. 把 FanBar.app 拖到"应用程序"文件夹
2. 首次打开:如果提示"无法验证开发者",在图标上右键 → 打开 → 再点"打开"
   (自制软件没有苹果商店认证,属正常现象,只需一次)
3. 菜单栏出现温度图标即成功

【功能】
- 菜单栏标题自定义:温度/CPU/GPU/内存/网速/电池/功率任意组合(面板里勾选)
- 左键点开面板:全部温度传感器、风扇转速、CPU(每核+Top5占用进程,右击可结束)、
  GPU、内存(含压力与 Swap)、电池(实时充放电功率+今日用电量)、硬盘、网速、今日流量
- 今日峰值记录:最高温/CPU 峰值/放电峰值/用电 Wh
- 风扇控制:多点温度曲线可拖拽编辑,支持「插电/电池」两套曲线自动切换
- 定时夜间模式:设定时间窗(如 23:00–07:00)自动改用安静预设,夜间降噪
- 7 天小时级趋势图(温度/CPU/GPU 切换),数据可导出 CSV
- 高温报警、电池充满提醒、风扇故障告警(转速骤降为 0 时通知)
- 右键菜单栏图标:快捷全速/恢复/预设/复制状态/导出 CSV

【启用风扇控制(需要管理员密码,仅一次)】
点菜单栏图标 → "安装守护进程" → 输入密码。
不装也能用:全部监控功能不需要任何权限。
MacBook Air 无风扇,仅监控可用。

【卸载】
面板 → 恢复系统控制 → 卸载守护进程 → 退出应用,删掉 app 即可。

【支持的机型】
Apple Silicon(M1/M2/M3/M4/M5)与 Intel Mac,macOS 13 及以上。
M3/M4 机型首次接管风扇可能需要几秒钟。

【说明】
本软件按"原样"提供,使用风险自负。长时间高负载时请留意温度显示。
EOF

ln -sf /Applications "$DIST/Applications"
echo "==> 生成 DMG…"
hdiutil create -volname "MacFanControl" -srcfolder "$DIST" -ov -format UDZO "dist/MacFanControl-v${VERSION}.dmg" >/dev/null
echo ""
echo "✅ 分发包: $(pwd)/dist/MacFanControl-v${VERSION}.dmg"
echo "   发这个 .dmg 文件给别人即可(微信/网盘均可)"
