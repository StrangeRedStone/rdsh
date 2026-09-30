#!/usr/bin/env bash
# =============================================================================
# smoke-wake.sh —— 唤醒台账写入/撤销 + `restart --wake` 的隔离功能冒烟
#
# 覆盖 B13（把"重启 + 续转"收进 rdsh）新增的三样东西，以及**两次真机泄漏**换来的纪律：
#   * `wake add/ls/del`：JSON 用 jq 生成（提示词含引号/换行也要原样往返）；del 走**回收站**（不 rm）
#   * `restart --wake --session`：重启前登记；选项在前（`--dry-run`）也能解析出目标
#   * 无目标时回退顺序：显式目标 → **账本 current** → 在跑实例；都没有就 **warn 跳过**（不 die）
#   * `RDSH_NO_LIVE_INSTANCES=1` 测试缝：隔离 `ss` 真相层（否则隔离 BASE 会把台账写进**真机 home**）
#   * **真机 `$DSH_HOME/wake` 目录测试前后逐项一致**（硬断言；本文件的两条教训就来自它被写脏过两次）
#
# 用法: bash smoke-wake.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" wake --help 2>/dev/null | grep -q 'wake add'; then
  echo "被测脚本还没有 \`wake add\`（B13 未应用？先跑补丁）：$SRC" >&2; exit 2
fi
command -v jq >/dev/null || { echo '本冒烟需要 jq' >&2; exit 2; }

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-suite/state" "$B/.dsh-suite/run/instances" "$B/.dsh-suite/logs"
cp -p "$SRC" "$B/dsh/Rdsh.sh"
[ -f "$(dirname "$SRC")/rdsh-restart.sh" ] && cp -p "$(dirname "$SRC")/rdsh-restart.sh" "$B/dsh/"
D="$B/dsh/ck-1"; H="$B/.dsh/9.9.7-rc.2"
mkdir -p "$D" "$H"; printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$D/package.json"

# 注意：env 的 `-u` 选项必须排在**赋值之前**（GNU env 把选项后的第一个非赋值当命令，
# 顺序写反会得到 rc=127「-u: command not found」——本冒烟第一版就栽在这）
run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT \
          -u RDSH_BACKUP_ROOT -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_NO_LIVE_INSTANCES="${NO_LIVE:-0}" RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" \
          bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）" ; }

# 真机台账目录指纹（硬断言：本测试绝不碰它）
REAL_WAKE="$HOME/Mapp/.dsh-suite/data/0.1.7-rc.2/wake"
real_state() { find "$REAL_WAKE" -maxdepth 1 2>/dev/null | sort | tr '\n' ' '; }
REAL_BEFORE="$(real_state)"

echo '--- 0) 播种账本 + 指定 current（让"无目标"能走账本回退） ---'
run state --init >/dev/null 2>&1
run state role 9.9.7-rc.2 current >/dev/null 2>&1
has "$(grep -v '^#' "$B/.dsh-suite/state/versions.kv")" '|current|' '账本里 9.9.7-rc.2 = current'

echo '--- 1) wake add：JSON 合法、提示词含引号与换行也原样往返 ---'
PROMPT=$'他说 "继续"；然后换行\n第二行'
out="$(run wake add sess-a "$PROMPT" --target 9.9.7-rc.2 2>&1)"; rc=$?
rc_is "$rc" 0 'wake add rc=0'
F="$H/wake/sess-a.json"
[ -f "$F" ] && ok '台账文件已落在**隔离** home' || bad '台账文件不在隔离 home'
if [ -f "$F" ]; then
  jq -e . "$F" >/dev/null 2>&1 && ok 'JSON 合法（jq 可解析）' || bad 'JSON 非法'
  [ "$(jq -r '.prompt' "$F")" = "$PROMPT" ] && ok '提示词原样往返（引号/换行没被写坏）' || bad '提示词被转义写坏了'
  [ "$(jq -r '.createdBy' "$F")" = 'rdsh wake add' ] && ok '记下了登记人' || bad 'createdBy 不对'
fi
has "$out" '已登记唤醒' '输出里说明了登记结果'

echo '--- 1.5) --dry-run 只出计划、不落盘（契约的 write 默认） ---'
out="$(run wake add sess-dry '只应出计划' --target 9.9.7-rc.2 --dry-run 2>&1)"
has "$out" '[dry-run] 将登记唤醒' 'add --dry-run 明说只出计划'
[ ! -f "$H/wake/sess-dry.json" ] && ok 'add --dry-run 没有落盘' || bad 'add --dry-run 竟然写了'
out="$(run wake del sess-a --target 9.9.7-rc.2 --dry-run 2>&1)"
has "$out" '[dry-run] 将撤销唤醒' 'del --dry-run 明说只出计划'
[ -f "$F" ] && ok 'del --dry-run 没有真撤' || bad 'del --dry-run 竟然撤了'

echo '--- 2) wake ls 能看到 ---'
out="$(run wake ls 2>&1)"
has "$out" 'sess-a' 'ls 列出 sess-a'
has "$out" '他说' 'ls 显示提示词摘要'

echo '--- 3) 无 --target → 走账本 current（仍隔离） ---'
out="$(run wake add sess-b '走账本回退' 2>&1)"; rc=$?
rc_is "$rc" 0 '无 --target 也能登记'
[ -f "$H/wake/sess-b.json" ] && ok '写进了隔离 home（账本回退生效）' || bad '账本回退没生效'
has "$out" '账本 current' '输出里标明了来源'

echo '--- 4) restart --wake --session：选项在前也能解析目标 ---'
out="$(run restart 9.9.7-rc.2 --wake '重启后继续 B13' --session sess-c --dry-run 2>&1)"
[ -f "$H/wake/sess-c.json" ] && ok '重启前已登记（--dry-run 也登记）' || bad '没登记'
[ "$(jq -r '.reason' "$H/wake/sess-c.json" 2>/dev/null)" = 'restart' ] && ok '原因记为 restart' || bad '原因字段不对'
has "$out" '已登记唤醒台账' '输出里有登记回执'

echo '--- 5) restart --wake 缺 --session → 明确报错 ---'
out="$(run restart 9.9.7-rc.2 --wake '没给 session' --dry-run 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '缺 --session 拒绝执行' || bad '缺参数竟然放行'
has "$out" '需要同时给 --session' '报错说清了缺什么'

echo '--- 6) wake del：移进回收站（不 rm），ls 不再列出 ---'
out="$(run wake del sess-a --target 9.9.7-rc.2 2>&1)"; rc=$?
rc_is "$rc" 0 'wake del rc=0'
[ ! -f "$F" ] && ok '台账文件已移走' || bad '文件还在'
[ -n "$(ls -1 "$B/.dsh-suite/trash" 2>/dev/null)" ] && ok '回收站里有条目（可还原）' || bad '回收站没条目'
hasnt "$(run wake ls 2>&1)" 'sess-a' 'ls 不再列出 sess-a'

echo '--- 7) 无目标 + 无账本 current + 无在跑实例 → warn 跳过（不 die） ---'
run state role 9.9.7-rc.2 installed >/dev/null 2>&1
NO_LIVE=1 out="$(run restart --wake 'x' --session sess-d --dry-run 2>&1)"; rc=$?
has "$out" '跳过唤醒登记' '明确说明跳过登记'
hasnt "$out" '需要同时给' '不是参数错误'
[ ! -f "$H/wake/sess-d.json" ] && ok '没有写出任何台账文件' || bad '竟然写了台账'

echo '--- 8) 真机台账目录一字未动（两次泄漏换来的硬约束） ---'
[ "$REAL_BEFORE" = "$(real_state)" ] && ok "真机 wake 目录未变（$([ -z "$REAL_BEFORE" ] && echo 空)）" || bad "真机被写了：[$REAL_BEFORE] → [$(real_state)]"

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
