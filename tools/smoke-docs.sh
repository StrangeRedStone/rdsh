#!/usr/bin/env bash
# =============================================================================
# smoke-docs.sh —— 文档路径表「机写」的隔离冒烟（2026-11-05 P3）
#
# 背景：docs/README 里的派生路径表曾手抄，布局一改就漂移（2026-11-02 实测 24 处指向
#       已不存在的旧目录）。现在由 tools/render-docs.sh 从 `rdsh base --print-paths`
#       生成，CI 用 --check 逐字节比对。
#
# 本冒烟在**临时仓库**里自证：
#   * 首次 write 能生成块，且块内**不含机器绝对路径**（可移植）
#   * 生成后 --check 通过
#   * 块内被手改（漂移）→ --check 必须 rc=1（负样本）
#   * 缺标记 → --check 必须 rc=1
#   * 恢复后 → 通过（幂等）
#
# 用法: bash smoke-docs.sh [Rdsh.sh 路径]
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
RENDER="$(dirname "$(readlink -f "$0")")/render-docs.sh"
[ -f "$RENDER" ] || { echo "找不到 render-docs.sh: $RENDER" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R/tools" "$R/docs"
cp -p "$SRC" "$R/Rdsh.sh"
cp -p "$RENDER" "$R/tools/render-docs.sh"
printf '# README\n\n<!-- PATHS:BEGIN -->\n<!-- PATHS:END -->\n' > "$R/README.md"
printf '# 架构\n\n<!-- PATHS:BEGIN -->\n<!-- PATHS:END -->\n' > "$R/docs/架构.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

# 隔离 HOME：别读真机配置
export HOME="$T/home"; mkdir -p "$HOME"
run() { ( cd "$R" && env -u RDSH_BASE -u RDSH_CONFIG bash tools/render-docs.sh "$@" 2>&1 ); }

echo '--- 1) 首次生成 ---'
out="$(run)"; rc=$?
rc_is "$rc" 0 'write rc=0'
has_block() { grep -q 'PATHS:BEGIN' "$1" && [ "$(grep -c 'MANAGE_ROOT' "$1")" -ge 1 ]; }
has_block "$R/README.md" && ok 'README 生成了路径块' || bad 'README 没生成'
has_block "$R/docs/架构.md" && ok '架构 生成了路径块' || bad '架构 没生成'

echo '--- 2) 可移植：块内不含机器绝对路径 ---'
if sed -n '/PATHS:BEGIN/,/PATHS:END/p' "$R/README.md" | grep -q '/home/'; then
  bad '块里出现 /home/ 绝对路径（不可移植）'
else
  ok '块内无 /home/ 绝对路径'
fi

echo '--- 3) check 通过 ---'
out="$(run --check)"; rc=$?
rc_is "$rc" 0 '生成后 --check rc=0'

echo '--- 4) 负样本：手改块内一行 → 必须红 ---'
sed -i 's#`\$BASE/\.dsh-suite/data`#`\$BASE/xxx`#' "$R/README.md"
out="$(run --check)"; rc=$?
rc_is "$rc" 1 '漂移后 --check rc=1'
case "$out" in *'不一致'*) ok '输出点明了"不一致"' ;; *) bad '输出没点明不一致' ;; esac

echo '--- 5) 恢复后重新生成 → 又绿 ---'
run >/dev/null 2>&1
out="$(run --check)"; rc=$?
rc_is "$rc" 0 '重新生成后 --check rc=0'

echo '--- 6) 负样本：缺标记 → 必须红 ---'
printf '# README（无标记）\n' > "$R/README.md"
out="$(run --check)"; rc=$?
rc_is "$rc" 1 '缺标记 --check rc=1'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
