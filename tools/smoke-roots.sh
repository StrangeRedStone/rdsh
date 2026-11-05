#!/usr/bin/env bash
# =============================================================================
# smoke-roots.sh —— 附属脚本共享「根解析库」的隔离冒烟（2026-11-05 P1）
#
# 背景：根解析以前在 6 个脚本里各抄一份。现在附属脚本 source `tools/lib-roots.sh`，
# 主脚本（Rdsh.sh）保持原解析规则，并在转发前 export 解析结果。
#
# 自证：
#   * 配置文件 BASE → 各派生根正确
#   * 环境变量 RDSH_BASE 覆盖配置文件
#   * 经典布局回退（$BASE/rdsh 无 Rdsh.sh、$BASE/dsh 有 → 用 dsh）
#   * 可移植回退（两者都没有 → 调用脚本自身目录，须含 Rdsh.sh）
#   * lib 结果与 `Rdsh.sh base --print-paths` 一致
#   * 5 个附属脚本确实在 source 共享库（防“改了库却没人用”）
#
# 用法: bash smoke-roots.sh [Rdsh.sh 路径]
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
REPO="$(cd "$(dirname "$SRC")" && pwd)"
LIB="$REPO/tools/lib-roots.sh"
[ -f "$LIB" ] || { echo "找不到共享库: $LIB" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 $2，实际 $1）"; }

# 用共享库解析并打印指定字段
probe() {  # <工作目录> <KEY…> -- <env…>
  local dir="$1"; shift
  local keys=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do keys+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "$dir" && env "$@" bash -c '
      . "$1/tools/lib-roots.sh"
      rdsh_resolve_roots
      shift
      for k in "$@"; do eval "printf \"%s\\n\" \"\$$k\""; done
    ' _ "$REPO" "${keys[@]}" )
}

echo '--- 1) 配置文件 BASE → 派生正确 ---'
B1="$T/base1"; mkdir -p "$B1/rdsh"; cp -p "$SRC" "$B1/rdsh/Rdsh.sh"
mkdir -p "$B1/tools"; cp -p "$LIB" "$B1/tools/lib-roots.sh"
printf 'BASE=%s\n' "$B1" > "$T/cfg1"
out="$(probe "$T" BASE MANAGE_ROOT DATA_ROOT BACKUP_ROOT STATE_ROOT PLUGIN_ROOT -- RDSH_CONFIG="$T/cfg1" HOME="$T/home")"
eq "$(printf '%s\n' "$out" | sed -n 1p)" "$B1" 'BASE 来自配置'
eq "$(printf '%s\n' "$out" | sed -n 2p)" "$B1/rdsh" 'MANAGE_ROOT=$BASE/rdsh'
eq "$(printf '%s\n' "$out" | sed -n 3p)" "$B1/.dsh-suite/data" 'DATA_ROOT 正确'
eq "$(printf '%s\n' "$out" | sed -n 4p)" "$B1/.dsh-suite/backup" 'BACKUP_ROOT 正确'
eq "$(printf '%s\n' "$out" | sed -n 5p)" "$B1/.dsh-suite/state" 'STATE_ROOT 正确'
eq "$(printf '%s\n' "$out" | sed -n 6p)" "$B1/.dsh-suite/plugins" 'PLUGIN_ROOT 正确'

echo '--- 2) 环境 RDSH_BASE 覆盖配置文件 ---'
B2="$T/base2"; mkdir -p "$B2/rdsh"; cp -p "$SRC" "$B2/rdsh/Rdsh.sh"
out="$(probe "$T" BASE MANAGE_ROOT -- RDSH_CONFIG="$T/cfg1" RDSH_BASE="$B2" HOME="$T/home")"
eq "$(printf '%s\n' "$out" | sed -n 1p)" "$B2" 'BASE 被环境覆盖'
eq "$(printf '%s\n' "$out" | sed -n 2p)" "$B2/rdsh" 'MANAGE_ROOT 跟着覆盖'

echo '--- 3) 经典布局回退：$BASE/dsh ---'
B3="$T/base3"; mkdir -p "$B3/dsh"; cp -p "$SRC" "$B3/dsh/Rdsh.sh"
printf 'BASE=%s\n' "$B3" > "$T/cfg3"
out="$(probe "$T" MANAGE_ROOT -- RDSH_CONFIG="$T/cfg3" HOME="$T/home")"
eq "$out" "$B3/dsh" '无 rdsh/ 时回退经典 dsh/'

echo '--- 4) 可移植回退：脚本自身目录 ---'
B4="$T/base4"; mkdir -p "$B4/self/tools"; cp -p "$SRC" "$B4/self/Rdsh.sh"; cp -p "$LIB" "$B4/self/tools/lib-roots.sh"
cat > "$B4/self/probe.sh" <<'P'
#!/usr/bin/env bash
set -euo pipefail
_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$_self_dir/tools/lib-roots.sh"
rdsh_resolve_roots
printf '%s\n' "$MANAGE_ROOT"
P
chmod +x "$B4/self/probe.sh"
printf 'BASE=%s\n' "$B4/no-such" > "$T/cfg4"
out="$(env -u RDSH_BASE RDSH_CONFIG="$T/cfg4" HOME="$T/home" bash "$B4/self/probe.sh")"
eq "$out" "$B4/self" '找不到检出时回退脚本自身目录'

echo '--- 5) 与 Rdsh.sh base --print-paths 一致 ---'
rp="$(env -u RDSH_BASE RDSH_CONFIG="$T/cfg1" HOME="$T/home" bash "$B1/rdsh/Rdsh.sh" base --print-paths 2>/dev/null)"
lib="$(probe "$T" BASE MANAGE_ROOT DATA_ROOT BACKUP_ROOT LOG_DIR RUN_DIR STATE_ROOT TRASH_ROOT PLUGIN_ROOT PATCHES_ROOT -- RDSH_CONFIG="$T/cfg1" HOME="$T/home")"
same=1; i=1
while IFS='=' read -r k v; do
  case "$k" in BASE|MANAGE_ROOT|DATA_ROOT|BACKUP_ROOT|LOG_DIR|RUN_DIR|STATE_ROOT|TRASH_ROOT|PLUGIN_ROOT|PATCHES_ROOT) ;; *) continue ;; esac
  got="$(printf '%s\n' "$lib" | sed -n "${i}p")"
  [ "$got" = "$v" ] || { same=0; echo "      不一致：$k lib=$got rdsh=$v"; }
  i=$((i+1))
done <<< "$rp"
[ "$same" = 1 ] && ok 'lib 与 rdsh base --print-paths 逐项一致' || bad 'lib 与 rdsh 不一致'

echo '--- 6) 附属脚本确实在用共享库 ---'
for f in doctor.sh migrate.sh plugin-sync.sh rdsh-restart.sh patch-manager.sh; do
  if grep -q 'tools/lib-roots.sh' "$REPO/$f" 2>/dev/null; then ok "$f 使用共享库"; else bad "$f 没 source 共享库"; fi
done

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
