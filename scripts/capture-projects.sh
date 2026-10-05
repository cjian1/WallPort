#!/usr/bin/env bash
# 逐个把壁纸项目放到主显示器上运行，收集日志、截图（仅网页壁纸）和资源占用，用于批量验收。
# 用法：scripts/capture-projects.sh <输出目录> <项目文件夹>...
#
# 运行期间会临时改写壁纸设置，结束后恢复。输出里的截图含有壁纸作者的内容，不要放进仓库。
set -euo pipefail

cd "$(dirname "$0")/.."
out="$1"
shift
app="build/MacWallpaper.app"
binary="$app/Contents/MacOS/MacWallpaper"
log="$HOME/Library/Logs/MacWallpaper/desktop.log"
mkdir -p "$out"

uuid=$(swift -e 'import CoreGraphics; import ColorSync
print(CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())!.takeRetainedValue())!)' 2>/dev/null)
saved="$out/saved-defaults.plist"
defaults export local.macwallpaper "$saved"

restore() {
    pkill -f "$binary" || true
    defaults import local.macwallpaper "$saved"
}
trap restore EXIT

webkit_pids() { pgrep -f "com.apple.WebKit" | sort; }

for project in "$@"; do
    id=$(basename "$project")
    mkdir -p "$out/$id"
    pkill -f "$binary" || true
    sleep 1

    defaults write local.macwallpaper displayAssignments -dict "$uuid" "project:$project"
    before=$(webkit_pids)
    start=$(date '+%F %T')
    open --env MACWALLPAPER_CAPTURE_DIR="$out/$id" "$app"
    sleep 14

    awk -v s="$start" '$0 >= s' "$log" > "$out/$id/log.txt"
    # 启动后新出现的 WebKit 进程就是这个壁纸的
    ours=$(comm -13 <(echo "$before") <(webkit_pids) | tr '\n' ',' | sed 's/,$//')
    app_pid=$(pgrep -f "$binary" || true)
    top -l 2 -s 3 -stats pid,command,cpu,mem -pid "${app_pid:-0}" ${ours:+$(printf -- '-pid %s ' ${ours//,/ })} \
        | awk '/^PID/{n++} n==2' | tail -n +2 > "$out/$id/cpu.txt"
    echo "$id 完成"
done
