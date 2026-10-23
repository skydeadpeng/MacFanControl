#!/bin/bash
# 生成应用图标:1024px 渐变底 + 白色温度计 → 全尺寸 icns
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build-resources"
mkdir -p "$OUT"
TMP=$(mktemp -d)

cat > "$TMP/render.swift" <<'EOF'
import AppKit
let size = CGFloat(1024)
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: size-192, height: size-192),
                      xRadius: 234, yRadius: 234)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.75, blue: 0.71, alpha: 1)])!
gradient.draw(in: bg, angle: -70)

let config = NSImage.SymbolConfiguration(pointSize: 465, weight: .medium)
if let symbol = NSImage(systemSymbolName: "thermometer.high", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSGraphicsContext.current?.compositingOperation = .sourceAtop
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill()
    tinted.unlockFocus()
    let w = symbol.size.width, h = symbol.size.height
    tinted.draw(in: NSRect(x: (size-w)/2, y: (size-h)/2 - 14, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 0.96)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

swift "$TMP/render.swift" "$TMP/icon1024.png"
mkdir -p "$TMP/icon.iconset"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$TMP/icon1024.png" --out "$TMP/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon1024.png" --out "$TMP/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/icon.iconset" -o "$OUT/AppIcon.icns"
rm -rf "$TMP"
echo "✅ 图标已生成: $OUT/AppIcon.icns"
