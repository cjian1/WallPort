#!/usr/bin/env bash
# 由 App/AppIcon.svg 生成 App/AppIcon.icns（改了 SVG 以后重新跑一次，生成的 .icns 一起提交）。
# 先用 WebKit 画一张 1024 点的透明底母版，再缩出 iconset 要的各个尺寸，最后用 iconutil 打包。
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swiftc -O scripts/svg2png.swift -o "$work/svg2png" 2>/dev/null
"$work/svg2png" App/AppIcon.svg "$work/master.png" 1024 >/dev/null

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/master.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/master.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o App/AppIcon.icns
echo "App/AppIcon.icns"
