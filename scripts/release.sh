#!/usr/bin/env bash
# 发布用的打包：签名 + Hardened Runtime +（有证书时）苹果公证 + .dmg，产物放在 build/release，
# 然后用 scripts/publish-github.sh 发到 GitHub Releases（开发时用 build-app.sh）。
#
#   BUNDLE_ID=io.github.你的用户名.wallport VERSION=1.0.0 scripts/release.sh
#
# 有 Apple 开发者证书时再加上（别人下载后打开不会被 macOS 拦）：
#   SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" NOTARY_PROFILE=wallport
#
# 环境变量：
#   BUNDLE_ID       必填：你拥有的域名倒写，例如 com.example.wallport（发布以后不要再改，系统授权认它）
#   VERSION         必填：给用户看的版本号，例如 1.0.0
#   BUILD           内部版本号，每次发布都要比上一次大（自动更新靠它判断新旧）；默认用 git 提交数
#   SIGN_IDENTITY   Developer ID Application 证书（security find-identity -v -p codesigning 里能看到）。
#                   不填时用临时签名、跳过公证：只能自己测，别人下载会被 macOS 拦住
#   NOTARY_PROFILE  notarytool 存在钥匙串里的配置名（一次性：xcrun notarytool store-credentials wallport
#                   --apple-id <Apple ID> --team-id <TEAMID>，按提示填 App 专用密码）
#   GITHUB_REPO     发布在哪个 GitHub 仓库（"用户名/仓库名"）；不填时从 git 的 origin 远端认。写进 App：
#                   启动后、之后每天检查一次这个仓库最新的 Release，有新版本提示去下载；帮助菜单里的
#                   "访问壁坞网站""反馈问题…"默认打开仓库主页和 Issues
#   PUBLISHER       发布者（个人名字、GitHub 用户名或公司名），写进隐私政策、使用条款和版权信息；默认是仓库所属的用户名
#   CONTACT         联系方式（邮箱或网址），写进隐私政策和使用条款；默认是仓库的 Issues 页面
#   GOVERNING_LAW   使用条款的适用法律（例如"中华人民共和国"）；不填时条款里不写这一句
#                   ——发布者、联系方式在发到 GitHub（认出了仓库）或正式签名时必须有，免得把带占位的条款发出去
#   COPYRIGHT       "关于"窗口里的版权行；默认"© 今年 PUBLISHER"
#   WEBSITE_URL     项目主页（https），不填就是 GitHub 仓库页
#   SUPPORT_URL     反馈问题的地址（https 网页或 mailto:），不填就是 GitHub 仓库的 Issues
#
# 只编 Apple 芯片（arm64）：图层混合模式的着色器直接读帧缓冲（Metal 的 programmable blending），Intel / AMD 显卡不支持
set -euo pipefail

cd "$(dirname "$0")/.."
: "${BUNDLE_ID:?请设置 BUNDLE_ID，例如 com.你的域名.wallport}"
: "${VERSION:?请设置 VERSION，例如 1.0.0}"
build="${BUILD:-$(git rev-list --count HEAD)}"
identity="${SIGN_IDENTITY:--}"

# 发布在哪个仓库：没给就从 origin 远端认（git@github.com:用户/仓库.git 或 https://github.com/用户/仓库）
if [ -z "${GITHUB_REPO:-}" ]; then
    remote="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" =~ github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
        GITHUB_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    fi
fi
if [ -n "${GITHUB_REPO:-}" ]; then
    if ! [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "GITHUB_REPO 要写成 用户名/仓库名：$GITHUB_REPO" >&2
        exit 1
    fi
    export PUBLISHER="${PUBLISHER:-${GITHUB_REPO%%/*}}"
    export CONTACT="${CONTACT:-https://github.com/$GITHUB_REPO/issues}"
else
    echo "⚠️ 不知道发布在哪个 GitHub 仓库（设置 GITHUB_REPO 或 origin 远端）：这一版不会检查更新" >&2
fi

# 地址写错了的话，装出去的 App 会一直连不上（App 只认 https），在这里先拦住
check_url() {
    local name="$1" value="${!1:-}" allowed="$2"
    [ -z "$value" ] && return 0
    if ! [[ "$value" =~ ^($allowed): ]]; then
        echo "$name 要以 ${allowed//|/: 或 }: 开头：$value" >&2
        exit 1
    fi
}
check_url WEBSITE_URL https
check_url SUPPORT_URL 'https|mailto'
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️ 工作区有没提交的改动：这一版和任何一次提交都对不上，出了问题不好查" >&2
fi

out="build/release"
app="$out/WallPort.app"
rm -rf "$out"
mkdir -p "$out"

swift build -c release --arch arm64 --product MacWallpaperApp
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MacWallpaperApp" "$app/Contents/MacOS/WallPort"
cp App/Info.plist "$app/Contents/Info.plist"
info="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$info"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$info"
plutil -replace CFBundleVersion -string "$build" "$info"
copyright="${COPYRIGHT:-}"
if [ -z "$copyright" ] && [ -n "${PUBLISHER:-}" ]; then copyright="© $(date +%Y) $PUBLISHER"; fi
if [ -n "$copyright" ]; then plutil -replace NSHumanReadableCopyright -string "$copyright" "$info"; fi
if [ -n "${GITHUB_REPO:-}" ]; then plutil -replace WallPortGitHubRepo -string "$GITHUB_REPO" "$info"; fi
if [ -n "${WEBSITE_URL:-}" ]; then plutil -replace WallPortWebsiteURL -string "$WEBSITE_URL" "$info"; fi
if [ -n "${SUPPORT_URL:-}" ]; then plutil -replace WallPortSupportURL -string "$SUPPORT_URL" "$info"; fi
cp -R App/zh-Hans.lproj App/en.lproj "$app/Contents/Resources/"
cp -R App/CompatFonts "$app/Contents/Resources/"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
GITHUB_REPO="${GITHUB_REPO:-}" scripts/make-credits.sh "$app/Contents/Resources/Credits.html"
# 隐私政策、使用条款：正式签名时发布者、联系方式、适用法律必须填好
if [ "$identity" = "-" ] && [ -z "${GITHUB_REPO:-}" ]; then
    scripts/fill-legal.sh "$app/Contents/Resources/Legal"
else
    scripts/fill-legal.sh "$app/Contents/Resources/Legal" --strict
fi

# 签名：开 Hardened Runtime；有证书时带时间戳（公证要求）
timestamp=()
if [ "$identity" != "-" ]; then timestamp=(--timestamp); fi
codesign --force --options runtime ${timestamp[@]+"${timestamp[@]}"} --entitlements App/WallPort.entitlements \
    --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# 先给 App 本身公证并钉上票据：用户把它拖进「应用程序」以后第一次打开时，断网也能通过系统检查
notarize=false
if [ "$identity" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize=true
    zip="$out/WallPort-notarize.zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

# .dmg：App 加一个"应用程序"的快捷方式，用户拖进去就装好了
dmg="$out/WallPort-$VERSION.dmg"
stage="$out/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "WallPort $VERSION" -srcfolder "$stage" -ov -format UDZO "$dmg" > /dev/null
rm -rf "$stage"

if [ "$identity" = "-" ]; then
    echo "⚠️ 临时签名、没有公证：只能在这台 Mac 上自己测。正式发布要设置 SIGN_IDENTITY 和 NOTARY_PROFILE" >&2
else
    codesign --force --timestamp --sign "$identity" "$dmg"
    if $notarize; then
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    else
        echo "⚠️ 没有设置 NOTARY_PROFILE，没有公证：别人下载后 macOS 会拦住" >&2
    fi
fi
# 校验文件：放在 Release 里，下载的人可以核对文件没被改过（shasum -a 256 -c WallPort-版本.dmg.sha256）
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "下一步：把代码推到 GitHub，然后 VERSION=$VERSION scripts/publish-github.sh" >&2
echo "$dmg"
