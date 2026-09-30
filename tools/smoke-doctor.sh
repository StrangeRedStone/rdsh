#!/usr/bin/env bash
# =============================================================================
# smoke-doctor.sh —— doctor.sh（B2 只读体检）的隔离功能冒烟
#
# 隔离要点（同 smoke-state.sh，上一批的教训）：
#   1) 把 doctor.sh / Rdsh.sh **复制**进临时 BASE 的 dsh/ 下运行（否则 MANAGE_ROOT 的自定位
#      回退会指回真机目录）；
#   2) RDSH_CONFIG 指向临时 BASE 下**不存在**的文件（环境里注入的真配置含绝对路径）；
#   3) 跑测前后对**真机** state 资产做 md5 快照比对。
#
# 本脚本另外两条硬断言：
#   * **doctor 全程只读** —— 跑测前后整个临时 BASE 的内容逐字节一致；
#   * **零检查必须报错** —— 没有任何检出时退出码必须是 2（不许"零检查却报全绿"）。
#
# 用法: bash smoke-doctor.sh [doctor.sh 路径]（默认 ../doctor.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac

SRC="${1:-$(dirname "$(readlink -f "$0")")/../doctor.sh}"
[ -f "$SRC" ] || { echo "找不到 doctor.sh: $SRC" >&2; exit 2; }
RD_SH="$(dirname "$(readlink -f "$SRC")")/Rdsh.sh"

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh-backup" "$B/.dsh-suite"
cp -p "$SRC" "$B/dsh/doctor.sh"
[ -f "$RD_SH" ] && cp -p "$RD_SH" "$B/dsh/Rdsh.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/doctor.sh" "$@" </dev/null; }
# 造检出 + 数据 home（版本号避开真机在跑版本，防止宿主状态混入）
mkck() { # <目录名> <版本>
  local d="$B/dsh/$1" h="$B/.dsh/$2"
  mkdir -p "$d" "$h" && chmod 700 "$h"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  mkdir -p "$d/node_modules" "$d/.git/info"; printf 'objects\n.installed\n' > "$d/.git/info/exclude"
  printf '# echo\nkey=%s\nrole=current\n' "$2" > "$d/.installed"
  printf 'x\n' > "$h/settings.yaml"
  printf 'a\n' > "$h/lessons.md"
}
mkck ck-a 9.9.7-rc.2
mkck ck-b 9.9.6-beta.1
# 稳定根 + 一条正常的软链（指向稳定根）
mkdir -p "$B/.dsh-shared"; printf 'a\n' > "$B/.dsh-shared/lessons.md"
rm -f "$B/.dsh/9.9.7-rc.2/lessons.md"; ln -s "$B/.dsh-shared/lessons.md" "$B/.dsh/9.9.7-rc.2/lessons.md"
# 账本：两个对象，其中 ck-b 是 baseline
mkdir -p "$B/.dsh-suite/state"
{
  printf '# rdsh state —— 测试账本\n'
  printf '# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note\n'
  printf '9.9.7-rc.2|9.9.7-rc.2|current||2026-09-01T00:00:00+08:00|local:x||2026-09-01T00:00:00+08:00|||%s|%s|\n' "$B/dsh/ck-a" "$B/.dsh/9.9.7-rc.2"
  printf '9.9.6-beta.1|9.9.6-beta.1|baseline||2026-09-02T00:00:00+08:00|local:y||2026-09-02T00:00:00+08:00|||%s|%s|\n' "$B/dsh/ck-b" "$B/.dsh/9.9.6-beta.1"
} > "$B/.dsh-suite/state/versions.kv"
printf '# rdsh journal\n2026-09-29T00:00:00+08:00|init|9.9.7-rc.2|test\n' > "$B/.dsh-suite/state/journal.log"
printf '<!-- rdsh-generated —— 测试 -->\n# 回退基线\n' > "$B/.dsh-backup/回退基线.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

# 真机 state 资产快照（跑测全程必须不变）
REAL="$HOME/Mapp/.dsh-suite"
snap_real() { local f; for f in "$REAL/backup/回退基线.md" "$REAL/state/versions.kv" "$REAL/state/journal.log"; do
                [ -f "$f" ] && md5sum "$f"; done; }
# 临时 BASE 内容快照（doctor 只读 → 必须一致）
snap_tmp() { find "$B" -type f -o -type l | sort | while IFS= read -r f; do
               printf '%s ' "$f"; if [ -L "$f" ]; then readlink "$f"; else md5sum "$f" | cut -d' ' -f1; fi
             done; }
REAL_BEFORE="$(snap_real)"

echo '--- 1) 健康环境：应零 error ---'
out="$(run 2>&1)"; rc=$?
has "$out" '检查了：' '打印"检查了几个对象"'
rc_is "$rc" 0 '健康环境退出码 0'
has "$out" '软链' '报出软链条数'
hasnt "$out" '没有任何对象是 baseline' '有 baseline 时不报"缺基线"（健康环境）'

echo '--- 2) 断链（模拟 09-19 事故）→ 必须 error + 退出码 2 ---'
ln -s "$B/dsh/ck-a/profiles/node_modules/@deepseek-ai/dsh-host-x" "$B/.dsh/9.9.7-rc.2/broken-plugin-link" 2>/dev/null || true
mkdir -p "$B/.dsh/9.9.7-rc.2/profiles/node_modules/@deepseek-ai"
ln -s "$B/nonexistent-target" "$B/.dsh/9.9.7-rc.2/profiles/node_modules/@deepseek-ai/dsh-host-x"
out="$(run 2>&1)"; rc=$?
rc_is "$rc" 2 '有断链时退出码 2'
has "$out" '断链' '报出断链'
has "$out" '插件/依赖加载链' '点名插件/依赖加载链（09-19 那类）'
  has "$out" '按 home：' '断链按 home 分组报数（B12）'
  has "$out" '--fix-links' '给出修复命令（B12）'
rm -f "$B/.dsh/9.9.7-rc.2/broken-plugin-link"

echo '--- 3) 账本缺 baseline / 回声不一致 → warn 或 info，不崩 ---'
rm -f "$B/.dsh-suite/state/versions.kv"
out="$(run --only state 2>&1)"; rc=$?
has "$out" '账本未播种' '账本不存在时明确提示'
rc_is "$rc" 0 '账本未播种不算 error'
{
  printf '# rdsh state —— 测试账本\n'
  printf '# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note\n'
  printf '9.9.7-rc.2|9.9.7-rc.2|current||2026-09-01T00:00:00+08:00|local:x||2026-09-01T00:00:00+08:00|||%s|%s|\n' "$B/dsh/ck-a" "$B/.dsh/9.9.7-rc.2"
} > "$B/.dsh-suite/state/versions.kv"
out="$(run --only state 2>&1)"
has "$out" '没有 baseline' '缺 baseline 时会 warn'
# 回声与账本不一致
printf '# echo\nkey=9.9.7-rc.2\nrole=retired\n' > "$B/dsh/ck-a/.installed"
out="$(run --only state 2>&1)"
has "$out" '回声' '回声与账本不一致时提示'
printf '# echo\nkey=9.9.7-rc.2\nrole=current\n' > "$B/dsh/ck-a/.installed"

echo '--- 4) 零检查必须报错 ---'
out="$(run --only zzz 2>&1)"; rc=$?
rc_is "$rc" 2 '无维度可跑时退出码 2'
has "$out" '检查对象总数为 0' '明确拒绝"零检查却报全绿"'

echo '--- 5) --json ---'
"$B/dsh/doctor.sh" --json --only entries > "$T/out.json" 2>/dev/null
rc=$?
if python3 -c "import json,sys;d=json.load(open('$T/out.json'));assert d['checked']>0;assert 'dims' in d and 'findings' in d" 2>/dev/null; then
  ok '--json 输出可被 json.load 解析且 checked>0'
else
  bad '--json 输出不可解析'
fi

echo '--- 6) 全程只读：临时 BASE 逐字节不变 ---'
TMP_BEFORE="$(snap_tmp)"
run >/dev/null 2>&1 || true
run --only entries,state >/dev/null 2>&1 || true
TMP_AFTER="$(snap_tmp)"
[ "$TMP_BEFORE" = "$TMP_AFTER" ] && ok 'doctor 未改动临时 BASE 的任何文件' || {
  bad 'doctor 写入/改动了临时 BASE'
  diff <(printf '%s\n' "$TMP_BEFORE") <(printf '%s\n' "$TMP_AFTER") | head -6 | sed 's/^/      /'
}

echo '--- 7) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(snap_real)" ] && ok '真机 state 资产逐字节未变' || bad '真机 state 资产被本测试改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
