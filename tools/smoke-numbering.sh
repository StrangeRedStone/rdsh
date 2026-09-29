#!/usr/bin/env bash
# =============================================================================
# smoke-numbering.sh —— 同版本共存编号（B7）的隔离功能冒烟
#
# 规则（《恢复与退役-设计与排期》§三）：
#   * 次号 = `-2` 后缀，**全链一致**（检出目录名 / 数据目录 / 显示名 / 账本键）
#   * 身份**一经分配就不变、不压缩、不重用**（删了留墓碑）
#   * 键不同的两份**数据 home 必须分开**（否则互相写 workspace.json/settings）
#   * 匹配：先全名精确（含次号），片段命中多份就报错，**不替用户选**
#   * 快照按**键**归档（不是版本）—— 同版本两份的备份不能混
#
# 用法: bash smoke-numbering.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh retire'; then
  echo "被测脚本像是旧版本（先 publish --stage）：$SRC" >&2; exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-suite/state" "$B/.dsh-suite/run/instances"
cp -p "$SRC" "$B/dsh/Rdsh.sh"
[ -f "$(dirname "$SRC")/doctor.sh" ] && cp -p "$(dirname "$SRC")/doctor.sh" "$B/dsh/doctor.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

mkck() { # <目录名> <版本>
  local d="$B/dsh/$1"
  mkdir -p "$d/node_modules" "$d/.git/info"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"; printf 'objects\n.installed\n' > "$d/.git/info/exclude"
}
mkck ck-1 9.9.7-rc.2
mkck ck-2 9.9.7-rc.2              # 同版本第二份（目录名不带次号 —— 最容易撞车的形态）
printf '# 账本\n# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note\n' \
  > "$B/.dsh-suite/state/versions.kv"
printf '# journal\n' > "$B/.dsh-suite/state/journal.log"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

echo '--- 1) 两份同版本：先登记的拿版本号，后一份拿 -2（state --init 扫重） ---'
out="$(run state --init 2>&1)"; rc=$?
rc_is "$rc" 0 'state --init rc=0'
KV="$(cat "$B/.dsh-suite/state/versions.kv")"
has "$KV" '9.9.7-rc.2|9.9.7-rc.2|' '第一份的键 = 版本号'
has "$KV" '9.9.7-rc.2-2' '第二份拿到了 -2 次号'
has "$out" '同版本第二份检出' '明确提示这是同版本第二份'
has "$out" '数据 home' '提示数据 home 已分开'

echo '--- 2) 数据 home 必须分开（并写进 .map） ---'
has "$(cat "$B/dsh/.map" 2>/dev/null)" 'dir|ck-2|' 'ck-2 的数据目录映射已写入 .map'
D1="$B/.dsh/9.9.7-rc.2"; D2="$B/.dsh/9.9.7-rc.2-2"
has "$(run list 2>&1)" '9.9.7-rc.2-2' 'list 显示次号'
out="$(run list 2>&1)"
has "$out" "$D2" 'list 里第二份的数据目录是 <键>'
# 注意：$D1 是 $D2 的前缀（.../9.9.7-rc.2 vs .../9.9.7-rc.2-2），
# 所以必须**整行锚定**，不能用 grep -c "$D1" 这种子串计数（会被前缀骗）
esc1="$(printf '%s' "$D1" | sed 's/[.[\*^$]/\\&/g')"
esc2="$(printf '%s' "$D2" | sed 's/[.[\*^$]/\\&/g')"
printf '%s\n' "$out" | grep -qE "^ *数据: ${esc1} \\(" && ok '第一份的数据 home = <版本>' || bad '第一份数据 home 不对'
printf '%s\n' "$out" | grep -qE "^ *数据: ${esc2} \\(" && ok '第二份的数据 home = <键>（-2）' || bad '第二份数据 home 不对'
n_same="$(printf '%s\n' "$out" | grep -cE "^ *数据: ${esc1} \\(")"
[ "$n_same" = "1" ] && ok '第一份的数据 home 只出现一次（没有共用）' || bad "第一份数据 home 出现 $n_same 次"

echo '--- 3) 匹配规则：全名精确可用；裸版本号因多份而报错（不替用户选） ---'
out="$(run data 9.9.7-rc.2-2 2>&1)"; rc=$?
rc_is "$rc" 0 '用次号点名 → 成功'
has "$out" '9.9.7-rc.2-2' '解析到带次号的那份'
out="$(run data 9.9.7-rc.2 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '裸版本号命中多份 → 报错' || bad '裸版本号竟然选了一个'
has "$out" '次号点名' '报错里告诉怎么点名'

echo '--- 4) 身份不变、不压缩、不重用 ---'
run backup 9.9.7-rc.2-2 --snapshot >/dev/null 2>&1
run retire 9.9.7-rc.2-2 --apply >/dev/null 2>&1
has "$(cat "$B/.dsh-suite/state/versions.kv")" '9.9.7-rc.2-2|' '退役后仍能在账本里查到 -2（墓碑）'
has "$(cat "$B/.dsh-suite/state/versions.kv")" '|retired|' '角色置 retired'
# 第一份的键不受影响（不压缩）
out="$(run state show 9.9.7-rc.2 2>&1)"
has "$out" 'role' '第一份仍在账本'
hasnt "$out" '9.9.7-rc.2-2' '第一份的键没有被改写成别的'
# 再新增一份：必须拿 -3，绝不重用 -2
mkck ck-3 9.9.7-rc.2
run state --init >/dev/null 2>&1
has "$(cat "$B/.dsh-suite/state/versions.kv")" '9.9.7-rc.2-3' '新的一份拿到 -3（不重用已退役的 -2）'

echo '--- 5) 快照按键归档（同版本两份不混） ---'
S2="$B/.dsh-backup/snapshots/9.9.7-rc.2-2"
[ -d "$S2" ] && ok '快照目录用**键**命名（9.9.7-rc.2-2）' || bad '快照没有按键归档'
[ -f "$(ls -1dt "$S2"/*/ 2>/dev/null | sed -n '1p')/MANIFEST.kv" ] && ok '快照带 MANIFEST' || bad '缺 MANIFEST'
has "$(cat "$(ls -1dt "$S2"/*/ | sed -n '1p')/MANIFEST.kv")" 'key=9.9.7-rc.2-2' 'MANIFEST 记 key'
has "$(cat "$(ls -1dt "$S2"/*/ | sed -n '1p')/MANIFEST.kv")" 'version=9.9.7-rc.2' 'MANIFEST 同时记 version'

echo '--- 6) doctor 报同版本多份 ---'
out="$(run doctor --only entries 2>&1)"; rc=$?
has "$out" '同版本多份' 'doctor 点出同版本多份'
hasnt "$out" '数据 home 撞车' '数据 home 没有撞车（已分家）'

echo '--- 7) 真机资产未被触碰 ---'
REAL="$HOME/Mapp/.dsh-suite"
BEFORE="$(find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort)"
out="$(run list 2>&1)"
AFTER="$(find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort)"
[ "$BEFORE" = "$AFTER" ] && ok '真机 state/trash 未变' || bad '真机被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
