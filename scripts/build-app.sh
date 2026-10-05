#!/usr/bin/env bash
# 把 SwiftPM 的产物打包成 WallPort.app，装进统一文件夹（默认 ~/WallPort，可用 WALLPORT_DIR 指定），并做签名。
# 用法：scripts/build-app.sh [release|debug]（默认 release：debug 版的粒子模拟慢好几倍，CPU 占用会高很多）
# App 正在运行时先让它正常退出（退出时会恢复系统壁纸），装好以后不自动打开
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"

swift build -c "$config" --product MacWallpaperApp
bin_dir="$(swift build -c "$config" --show-bin-path)"

# App 名字：壁坞 / WallPort（中文系统显示"壁坞"，见 App/*.lproj/InfoPlist.strings）。
# Bundle ID 仍是 local.macwallpaper：改了的话用户的设置、系统授权都要重来
folder="${WALLPORT_DIR:-$HOME/WallPort}"
app="$folder/WallPort.app"
staging="$folder/.WallPort.app.new"
mkdir -p "$folder"
rm -rf "$staging" build/MacWallpaper.app
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$bin_dir/MacWallpaperApp" "$staging/Contents/MacOS/WallPort"
cp App/Info.plist "$staging/Contents/Info.plist"
cp -R App/zh-Hans.lproj App/en.lproj "$staging/Contents/Resources/"
# 没导入 WE 自带素材时用的兼容字体（来源和许可证见 App/CompatFonts/README.md）
cp -R App/CompatFonts "$staging/Contents/Resources/"
# 应用图标：由 App/AppIcon.svg 生成（scripts/make-icon.sh），改了 SVG 要重新生成
cp App/AppIcon.icns "$staging/Contents/Resources/AppIcon.icns"
# "关于壁坞"窗口显示的声明和第三方库许可证（从 Vendor/ 里的原文生成）
scripts/make-credits.sh "$staging/Contents/Resources/Credits.html"
# 隐私政策、使用条款（开发版的发布者、联系方式是"未填写"；正式版由 release.sh 填）
scripts/fill-legal.sh "$staging/Contents/Resources/Legal"

# 系统的隐私授权（例如访问"文稿"文件夹）认的是签名身份。临时签名（-）每次构建都会变，
# 于是每次都要重新授权；有 Apple Development 证书时就用它。也可以用 CODESIGN_IDENTITY 指定。
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${identity:--}" "$staging"
echo "签名身份：${identity:-临时签名（每次构建都要重新授权文件访问）}" >&2

# 正在运行的话先正常退出，再换上新的（不要删正在运行的 App）
if pgrep -f "$app/Contents/MacOS/WallPort" > /dev/null || pgrep -x WallPort > /dev/null; then
    osascript -e 'tell application id "local.macwallpaper" to quit' || true
    for _ in $(seq 1 50); do pgrep -f "$app/Contents/MacOS/WallPort" > /dev/null || break; sleep 0.2; done
    # 10 秒还没退（例如开着提示框，退出请求要等它关掉）：不动正在运行的 App，让用户退出后再装。
    # 只看从要替换的这个位置跑的那份：别处的 WallPort（正式版之类）还开着不妨碍替换
    if pgrep -f "$app/Contents/MacOS/WallPort" > /dev/null; then
        echo "WallPort 还在运行（可能开着提示框），没有替换 $app；退出 WallPort 后重新运行本脚本" >&2
        exit 1
    fi
fi
rm -rf "$app"
mv "$staging" "$app"

echo "$app"
