#!/usr/bin/env bash
# 英文界面的检查：让编译器导出全部本地化的键（SwiftUI 的字面量、String(localized:)），和
# App/en.lproj/Localizable.strings 对一遍，列出缺翻译的、已经用不上的、格式符（%@ %lld …）对不上的；
# 再按导出的键重写 App/zh-Hans.lproj/Localizable.strings（原文对原文）。
#
# 为什么要 zh-Hans 那一份：开发语言是英文（日语、德语等系统上显示英文），系统在中文的 lproj 里找不到
# Localizable.strings 时会退回英文那份，中文用户就看到英文了。
#
# 用法：scripts/check-localization.sh（有问题时退出码 1）
set -euo pipefail
cd "$(dirname "$0")/.."
work="build/localization"
mkdir -p "$work/strings"
# 单独的构建目录：带导出参数的编译不和平时的 .build 混在一起。增量编译只给改过的文件重新导出，
# 没改的文件沿用上次的结果（源文件已经删掉的那些下面会跳过）
swift build --product MacWallpaperApp --scratch-path "$work/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$work/strings" >&2
python3 - "$work/strings" <<'PY'
import glob, json, os, re, subprocess, sys
keys = {}
for path in glob.glob(os.path.join(sys.argv[1], '*.stringsdata')):
    data = json.load(open(path))
    if not os.path.exists(data['source']):
        continue
    for table in data.get('tables', {}).values():
        for entry in table:
            if entry['key']:
                keys.setdefault(entry['key'], set()).add(os.path.relpath(data['source']))
english = json.loads(subprocess.run(
    ['plutil', '-convert', 'json', '-o', '-', 'App/en.lproj/Localizable.strings'],
    check=True, capture_output=True).stdout)
spec = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[a-zA-Z@%]')
missing = sorted(k for k in keys if k not in english)
unused = sorted(k for k in english if k not in keys)
mismatched = sorted(k for k, v in english.items() if sorted(spec.findall(k)) != sorted(spec.findall(v)))
for title, items in (('缺英文翻译', missing), ('用不上了', unused), ('格式符对不上', mismatched)):
    for key in items:
        where = ', '.join(sorted(keys.get(key, [])))
        print(f'{title}：{json.dumps(key, ensure_ascii=False)}' + (f'（{where}）' if where else ''))
def escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
lines = ['/* 中文界面：原文对原文（由 scripts/check-localization.sh 生成，不要手改）。',
         '   有这一份，系统才不会在中文环境下退回英文那份。*/', '']
lines += [f'"{escape(k)}" = "{escape(k)}";' for k in sorted(keys)]
open('App/zh-Hans.lproj/Localizable.strings', 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(f'{len(keys)} 个键：缺翻译 {len(missing)}，用不上 {len(unused)}，格式符对不上 {len(mismatched)}')
sys.exit(1 if missing or mismatched else 0)
PY
