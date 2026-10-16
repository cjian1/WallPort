#!/usr/bin/env bash
# 把 SwiftPM 编出来的 libWallPortSaver.dylib 包成壁坞的屏幕保护程序 WallPort.saver（不签名：调用方按自己的方式签，
# 要在签 App 之前签）。build-app.sh 和 release.sh 用它，放进 App 的 Contents/Library/Screen Savers/，
# 菜单里「屏幕保护程序用当前画面…」再把它装到 ~/Library/Screen Savers。
#
# 用法：scripts/make-saver.sh <swift build 的产物目录> <输出的 .saver 路径> [Bundle ID] [版本号] [内部版本号]
#
# 为什么要屏保：电脑空闲时系统启动的是屏幕保护程序，和桌面壁纸分开设置（默认是系统自带壁纸的动画），
# 锁屏叠在它上面。它显示壁坞同步给系统的当前画面，见 Sources/WallPortSaver
set -euo pipefail

cd "$(dirname "$0")/.."
bin_dir="$1"
saver="$2"

rm -rf "$saver"
mkdir -p "$saver/Contents/MacOS" "$saver/Contents/Resources"
# 动态库当 bundle 的可执行文件：系统按 NSPrincipalClass 用 NSBundle 载入（dlopen 动态库和 MH_BUNDLE 都认）
cp "$bin_dir/libWallPortSaver.dylib" "$saver/Contents/MacOS/WallPort"
cp App/Saver/Info.plist "$saver/Contents/Info.plist"
cp -R App/Saver/zh-Hans.lproj App/Saver/en.lproj "$saver/Contents/Resources/"

info="$saver/Contents/Info.plist"
if [ -n "${3:-}" ]; then plutil -replace CFBundleIdentifier -string "$3" "$info"; fi
if [ -n "${4:-}" ]; then plutil -replace CFBundleShortVersionString -string "$4" "$info"; fi
if [ -n "${5:-}" ]; then plutil -replace CFBundleVersion -string "$5" "$info"; fi
echo "$saver"
