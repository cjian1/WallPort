#!/usr/bin/env bash
# 把 scripts/release.sh 打好的 .dmg 发到 GitHub Releases。
# 要先装 GitHub CLI 并登录一次：brew install gh && gh auth login；代码要先推到 GitHub（Release 的标签打在当前提交上）。
#
#   VERSION=1.0.0 RELEASE_NOTES="第一个公开版本" scripts/publish-github.sh
#
# 环境变量：
#   VERSION             必填：和 release.sh 用的一样。标签是 v$VERSION——已经装了的壁坞按它判断有没有新版本
#   GITHUB_REPO         发到哪个仓库（"用户名/仓库名"）；不填时从 git 的 origin 远端认
#   RELEASE_NOTES       更新说明（壁坞提示新版本时会显示开头一段）；也可以用 RELEASE_NOTES_FILE 指定文件，
#                       都不填时 GitHub 按提交记录自动生成
#   PRERELEASE=1        发成预发布：已经装了的壁坞不会提示更新，适合先给少数人测
#   DRAFT=1             先存成草稿，到网页上看过再点发布
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?请设置 VERSION，和 release.sh 用的一样，例如 1.0.0}"
dmg="build/release/WallPort-$VERSION.dmg"
[ -f "$dmg" ] || { echo "找不到 $dmg：先用同一个 VERSION 跑 scripts/release.sh" >&2; exit 1; }
command -v gh > /dev/null || { echo "先装 GitHub CLI：brew install gh，再运行 gh auth login" >&2; exit 1; }

if [ -z "${GITHUB_REPO:-}" ]; then
    remote="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" =~ github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
        GITHUB_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    fi
fi
[ -n "${GITHUB_REPO:-}" ] || { echo "不知道发到哪个仓库：设置 GITHUB_REPO=用户名/仓库名，或者先 git remote add origin …" >&2; exit 1; }

# 包里写的仓库要和发布的仓库一致，不然装了的人收不到这个仓库的更新
packaged="$(/usr/libexec/PlistBuddy -c 'Print :WallPortGitHubRepo' build/release/WallPort.app/Contents/Info.plist 2>/dev/null || true)"
if [ "$packaged" != "$GITHUB_REPO" ]; then
    echo "包里写的仓库是「${packaged:-没有}」，要发到的是「$GITHUB_REPO」：用 GITHUB_REPO=$GITHUB_REPO 重新跑 release.sh" >&2
    exit 1
fi
packaged_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/release/WallPort.app/Contents/Info.plist)"
[ "$packaged_version" = "$VERSION" ] || { echo "包里的版本是 $packaged_version，不是 $VERSION" >&2; exit 1; }

head="$(git rev-parse HEAD)"
if ! git branch -r --contains "$head" 2>/dev/null | grep -q .; then
    echo "当前提交 ${head:0:7} 还没推到 GitHub：先 git push，Release 的标签要打在已经推上去的提交上" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️ 工作区有没提交的改动：发布的包可能和标签对应的代码不一样" >&2
fi

notes=(--generate-notes)
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    notes=(--notes-file "$RELEASE_NOTES_FILE")
elif [ -n "${RELEASE_NOTES:-}" ]; then
    notes=(--notes "$RELEASE_NOTES")
fi
flags=()
[ "${PRERELEASE:-}" = "1" ] && flags+=(--prerelease)
[ "${DRAFT:-}" = "1" ] && flags+=(--draft)

gh release create "v$VERSION" "$dmg" "$dmg.sha256" --repo "$GITHUB_REPO" --target "$head" \
    --title "壁坞 WallPort $VERSION" "${notes[@]}" ${flags[@]+"${flags[@]}"}
echo "已发布：https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
