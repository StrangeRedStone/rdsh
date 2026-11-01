#!/usr/bin/env bash
# =============================================================================
# smoke-cd.sh —— `rdsh cd` 的隔离功能冒烟
#
# 覆盖：
#   * 无参数/--list 列出已管理检出（含完整路径）
#   * <版本|目录名|路径> 打印绝对路径；--json 机器可读
#   * --manage 打印 rdsh 部署目录（migrate.sh 所在处，不是检出）
#   * --exec 在目标目录执行命令；--manage --exec 在部署目录执行
#   * 负样本：未知目标 / --list+目标 / --manage+目标 / --enter+--exec 必须非 0
#   * 真机 state/trash 一字未动
#
# 用法: bash smoke-cd.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh cd'; then
  echo "被测脚本里没有 \`rdsh cd\`（旧版本？先 publish --stage）：$SRC" >&2
  exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/rdsh" "$B/.dsh-suite/state" "$B/.dsh-suite/data"
cp -p "$SRC" "$B/rdsh/Rdsh.sh"

mkck() { # <目录名> <版本>
  local d="$B/rdsh/$1"
  mkdir -p "$d/node_modules"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"
  mkdir -p "$B/.dsh-suite/data/$2/sessions"
}
mkck ck-a 9.9.6-alpha.1
mkck ck-b 9.9.7-rc.2

run() {
  env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
      -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
      -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u DSH_WEB_PORT \
      RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" \
      bash "$B/rdsh/Rdsh.sh" "$@" </dev/null
}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_nonzero() { [ "$1" != 0 ] && ok "$2（rc=$1）" || bad "$2（不该 0）"; }

# 真机 state/trash 指纹（测试前后必须一致）
_rc="$HOME/.config/rdsh/config"
_rb="$(sed -nE 's/^[[:space:]]*BASE[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$_rc" 2>/dev/null | tail -1)"
REAL_ROOT="${_rb:-$HOME/dsh}"
REAL="$REAL_ROOT/.dsh-suite"
real_state() { find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort; }
REAL_BEFORE="$(real_state)"

echo '--- 1) 列表与单目标路径 ---'
out="$(run cd 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok 'cd 列表 rc=0' || bad "cd 列表 rc=$rc"
has "$out" '已管理检出（2）' '列表对象数正确'
has "$out" "$B/rdsh/ck-b" '列表含 ck-b 完整路径'
has "$out" '数据:' '列表含数据 home'
out="$(run cd 9.9.7-rc.2 2>&1)"; rc=$?
[ "$out" = "$B/rdsh/ck-b" ] && ok '版本号解析到精确检出' || bad "版本号解析错：$out"
out="$(run cd ck-a 2>&1)"; rc=$?
[ "$out" = "$B/rdsh/ck-a" ] && ok '目录名解析到检出' || bad "目录名解析错：$out"

echo '--- 2) --json / --manage ---'
out="$(run cd --json 2>&1)"; rc=$?
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==2; assert all(x["dir"] for x in d)' 2>/dev/null \
  && ok 'cd --json 合法且含 2 个目录' || bad 'cd --json 不合法/字段缺失'
out="$(run cd 9.9.7-rc.2 --json 2>&1)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["dir"].endswith("ck-b")' 2>/dev/null \
  && ok '单目标 --json 含 dir' || bad '单目标 --json 错'
[ "$(run cd --manage 2>&1)" = "$B/rdsh" ] && ok '--manage 指向部署目录' || bad '--manage 路径错'

echo '--- 3) --exec ---'
out="$(run cd 9.9.7-rc.2 --exec -- pwd 2>&1)"; rc=$?
has "$out" "$B/rdsh/ck-b" '检出 --exec 的 cwd 正确'
[ "$rc" = 0 ] && ok '检出 --exec rc=0' || bad "检出 --exec rc=$rc"
out="$(run cd --manage --exec -- pwd 2>&1)"; rc=$?
has "$out" "$B/rdsh" '--manage --exec 的 cwd 正确'

echo '--- 4) 负样本 ---'
run cd 不存在 >/dev/null 2>&1; rc_nonzero "$?" '未知目标必须非 0'
run cd 9.9.7-rc.2 --list >/dev/null 2>&1; rc_nonzero "$?" '--list 加目标必须非 0'
run cd --manage 9.9.7-rc.2 >/dev/null 2>&1; rc_nonzero "$?" '--manage 加目标必须非 0'
run cd 9.9.7-rc.2 --enter --exec -- pwd >/dev/null 2>&1; rc_nonzero "$?" '--enter + --exec 必须非 0'
run cd --json 9.9.7-rc.2 --enter --exec -- pwd >/dev/null 2>&1; rc_nonzero "$?" '组合冲突仍必须非 0'

echo '--- 5) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(real_state)" ] && ok '真机 state/trash 未变' || bad '真机 state/trash 被改'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
