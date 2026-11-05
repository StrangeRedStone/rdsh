#!/usr/bin/env bash
# =============================================================================
# smoke-plugin.sh —— `rdsh plugin new|check|ls`（外部能力脚手架/自检）隔离冒烟
#
# 覆盖（2026-11-05，1.0.4）：
#   * `plugin new`：生成可执行骨架，manifest 恰好 1 行 6 字段、id 有 x- 前缀
#   * `plugin check`：好文件通过；坏样本必须红 ——
#       5 字段行 / 非 x- 前缀 / id 撞名 / 不可执行 / --manifest 无输出
#   * `plugin ls`：列出 id/子命令/风险
#   * 重复 `plugin new` 同名 → 拒绝
#
# 用法: bash smoke-plugin.sh [Rdsh.sh 路径]
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
B="$T/base"; mkdir -p "$B/rdsh" "$B/.dsh-suite/state"
cp -p "$SRC" "$B/rdsh/Rdsh.sh"
printf 'BASE=%s\n' "$B" > "$T/rdsh-config"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
          -u DSH_LOG_DIR -u RDSH_WEB_PORT -u RDSH_PLUGIN_ROOT -u RDSH_TRASH \
          RDSH_CONFIG="$T/rdsh-config" HOME="$T/home" \
          bash "$B/rdsh/Rdsh.sh" "$@" </dev/null 2>&1; }
PD="$B/rdsh/plugins.d"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

echo '--- 1) plugin new：生成可跑骨架 ---'
out="$(run plugin new demo)"; rc=$?
rc_is "$rc" 0 'new rc=0'
[ -x "$PD/demo.sh" ] && ok '骨架已生成且可执行（demo.sh）' || bad '骨架没生成/不可执行'
mf="$("$PD/demo.sh" --manifest 2>&1)"
has "$mf" 'iface=1' 'manifest 带 iface=1'
has "$mf" 'x-demo' 'manifest 的能力行 id 有 x- 前缀'
rows="$(printf '%s\n' "$mf" | grep -vcE '^(iface=|#|$)')"
[ "$rows" = "1" ] && ok 'manifest 恰好 1 行能力' || bad "manifest 能力行数为 $rows（应 1）"

echo '--- 2) plugin check / ls：好文件通过 ---'
out="$(run plugin check)"; rc=$?
rc_is "$rc" 0 'check rc=0'
has "$out" '通过 1' '统计里通过 1 个'
out="$(run plugin ls)"
has "$out" 'x-demo' 'ls 列出 x-demo'
has "$out" 'demo' 'ls 列出子命令'
has "$out" 'read' 'ls 列出风险等级'

echo '--- 3) 负样本：坏文件必须红 ---'
# 3a) 5 字段
cp -p "$PD/demo.sh" "$PD/bad5.sh"
sed -i 's#^x-demo|demo||read||#x-demo|demo||read|#' "$PD/bad5.sh"
out="$(run plugin check "$PD/bad5.sh")"; rc=$?
rc_is "$rc" 1 '5 字段 → rc=1'
has "$out" '不是 6 字段' '点名"不是 6 字段"'
rm -f "$PD/bad5.sh"

# 3b) id 无 x- 前缀
cp -p "$PD/demo.sh" "$PD/nox.sh"
sed -i 's#^x-demo|#demo|#' "$PD/nox.sh"
out="$(run plugin check "$PD/nox.sh")"; rc=$?
rc_is "$rc" 1 '无 x- 前缀 → rc=1'
has "$out" 'x- 前缀' '点名缺 x- 前缀'
rm -f "$PD/nox.sh"

# 3c) id 撞名（两个文件同 id）
cp -p "$PD/demo.sh" "$PD/dup.sh"
out="$(run plugin check "$PD/demo.sh" "$PD/dup.sh")"; rc=$?
rc_is "$rc" 1 'id 撞名 → rc=1'
has "$out" '撞名' '点名撞名'
rm -f "$PD/dup.sh"

# 3d) 不可执行
cp -p "$PD/demo.sh" "$PD/noexec.sh"; chmod -x "$PD/noexec.sh"
out="$(run plugin check "$PD/noexec.sh")"; rc=$?
rc_is "$rc" 1 '不可执行 → rc=1'
has "$out" '不可执行' '点名不可执行'
rm -f "$PD/noexec.sh"

# 3e) --manifest 无输出
printf '#!/usr/bin/env bash\nexit 0\n' > "$PD/empty.sh"; chmod +x "$PD/empty.sh"
out="$(run plugin check "$PD/empty.sh")"; rc=$?
rc_is "$rc" 1 '--manifest 无输出 → rc=1'
has "$out" '无输出' '点名无输出'
rm -f "$PD/empty.sh"

echo '--- 4) 重复 new 同名 → 拒绝 ---'
out="$(run plugin new demo)"; rc=$?
[ "$rc" != "0" ] && ok '同名已存在 → 拒绝' || bad '同名竟然覆盖了'
has "$out" '已存在' '明说已存在'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
