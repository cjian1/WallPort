#!/usr/bin/env bash
# 生成 App 里的 Credits.html（"关于壁坞"窗口自动显示它）：声明和 Wallpaper Engine 的关系，附上随 App 分发的
# 第三方库的许可证原文（直接从 Vendor/ 里读，库升级后不会和原文对不上）。
# 用法：scripts/make-credits.sh <输出文件>
set -euo pipefail

cd "$(dirname "$0")/.."
output="${1:?用法：scripts/make-credits.sh <输出文件>}"

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"; }

license() {
    local title="$1" source="$2" file="$3"
    printf '<h3>%s</h3>\n<p class="source">%s</p>\n<pre>' "$title" "$source"
    escape "$file"
    printf '</pre>\n'
}

{
    cat <<'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
body { font: 11px -apple-system, sans-serif; color: CanvasText; }
h3 { font-size: 12px; margin: 14px 0 2px; }
.source { color: GrayText; margin: 0 0 4px; }
pre { font: 10px ui-monospace, Menlo, monospace; white-space: pre-wrap; margin: 0; }
</style></head><body>
<p>壁坞（WallPort）是独立开发的软件，<b>不是 Wallpaper Engine 的官方产品</b>，与 Wallpaper Engine 及其开发者没有关联。
"Wallpaper Engine"是其权利人的商标。壁坞不提供、不托管任何壁纸；壁纸和 Wallpaper Engine 自带素材由用户自行提供，
版权属于各自的作者。</p>
<p>WallPort is independent software. It is <b>not</b> an official Wallpaper Engine product and is not affiliated with
Wallpaper Engine or its developers. "Wallpaper Engine" is a trademark of its respective owner. WallPort does not
provide or host any wallpapers; wallpapers and Wallpaper Engine assets are supplied by the user and belong to their
respective authors.</p>
<p>隐私政策和使用条款：打开壁纸库后，在"帮助"菜单里；或者菜单栏图标 → 首次使用提示。<br>
Privacy Policy and Terms of Use: in the Help menu (open the Library first), or menu bar icon → Getting Started.</p>
HTML
    # 壁坞自己是 MIT 许可证的开源软件；发布脚本给了 GITHUB_REPO 时附上仓库地址
    if [[ "${GITHUB_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        source_line=" <a href=\"https://github.com/$GITHUB_REPO\">github.com/$GITHUB_REPO</a>"
    else
        source_line=""
    fi
    printf '<p>壁坞是开源软件，源代码按 MIT 许可证提供 / WallPort is open-source software under the MIT License.%s</p>\n' \
        "$source_line"
    printf '<h2 style="font-size: 13px">第三方软件 / Third-party software</h2>\n'
    license "glslang" "https://github.com/KhronosGroup/glslang" Vendor/glslang/LICENSE.txt
    license "SPIRV-Cross" "https://github.com/KhronosGroup/SPIRV-Cross" Vendor/SPIRV-Cross/LICENSE
    license "Zstandard (zstd)" "https://github.com/facebook/zstd" Vendor/zstd/LICENSE
    printf '<h3>LZMA SDK</h3>\n<p class="source">https://www.7-zip.org/sdk.html</p>\n'
    printf '<pre>LzmaDec.c -- LZMA Decoder: Igor Pavlov: Public domain.\nThe LZMA SDK is placed in the public domain.</pre>\n'
    # 兼容字体（App/CompatFonts）：每个字体的版权声明，许可证原文各附一份（OFL 和 Apache 2.0）
    printf '<h2 style="font-size: 13px">字体 / Fonts</h2>\n'
    printf '<p>没有导入 Wallpaper Engine 自带素材时使用的字体，来源见 App 里的 CompatFonts/README.md。</p>\n'
    for file in App/CompatFonts/licenses/*-OFL.txt; do
        name="$(basename "$file" -OFL.txt)"
        printf '<h3>%s</h3>\n<pre>' "$name"
        # 版权声明：许可证正文（"This Font Software is licensed…"）之前的几行
        sed -n '/This Font Software is licensed/q;p' "$file" | sed -e 's/^[[:space:]]*//' | grep -v '^$' \
            | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
        printf '</pre>\n'
    done
    printf '<h3>Permanent Marker</h3>\n<pre>Copyright (c) 2010 by Font Diner, Inc. Licensed under the Apache License, Version 2.0.</pre>\n'
    license "SIL Open Font License 1.1" "https://openfontlicense.org" App/CompatFonts/licenses/Poppins-OFL.txt
    license "Apache License 2.0" "https://www.apache.org/licenses/LICENSE-2.0" \
        App/CompatFonts/licenses/PermanentMarker-Apache-2.0.txt
    printf '</body></html>\n'
} > "$output"
