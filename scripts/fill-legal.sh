#!/usr/bin/env bash
# 把 App/Legal 里的隐私政策、使用条款拷到 <输出目录>，填上占位：
#   PUBLISHER        发布者（个人名字或公司名）
#   CONTACT          联系方式（邮箱或网址）
#   GOVERNING_LAW    适用法律（例如"中华人民共和国"）
#   EFFECTIVE_DATE   生效日期（默认今天）
# 用法：scripts/fill-legal.sh <输出目录> [--strict]
# --strict（正式发布用）：上面前三项没填就报错退出，免得把带占位的条款发出去
set -euo pipefail

cd "$(dirname "$0")/.."
output="${1:?用法：scripts/fill-legal.sh <输出目录> [--strict]}"
strict="${2:-}"

if [ "$strict" = "--strict" ]; then
    missing=()
    for name in PUBLISHER CONTACT GOVERNING_LAW; do
        [ -n "${!name:-}" ] || missing+=("$name")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "隐私政策 / 使用条款还缺：${missing[*]}（见 scripts/release.sh 开头的说明）" >&2
        exit 1
    fi
fi

export PUBLISHER="${PUBLISHER:-（开发版未填写）}"
export CONTACT="${CONTACT:-（开发版未填写）}"
export GOVERNING_LAW="${GOVERNING_LAW:-（开发版未填写）}"
export EFFECTIVE_DATE="${EFFECTIVE_DATE:-$(date +%Y-%m-%d)}"

mkdir -p "$output"
for file in App/Legal/*.html; do
    # 用 perl 按环境变量替换：值里有 / & 之类也不会出错；顺手转义 HTML 特殊字符
    perl -pe '
        BEGIN { sub esc { my $v = shift; $v =~ s/&/&amp;/g; $v =~ s/</&lt;/g; $v =~ s/>/&gt;/g; $v } }
        s/\{\{(PUBLISHER|CONTACT|GOVERNING_LAW|EFFECTIVE_DATE)\}\}/esc($ENV{$1})/ge
    ' "$file" > "$output/$(basename "$file")"
done
if grep -l '{{' "$output"/*.html > /dev/null; then
    echo "还有没填上的占位：$(grep -l '{{' "$output"/*.html | tr '\n' ' ')" >&2
    exit 1
fi
