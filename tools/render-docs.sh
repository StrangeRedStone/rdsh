#!/usr/bin/env bash
# =============================================================================
# render-docs.sh —— 机写文档：把「路径真源」渲染进文档（2026-11-05 P3）
#
# 为什么：docs/README 里的派生路径表此前**手抄**，布局一改就漂移（2026-11-02 实测
# 24 处指向已不存在的旧目录）。现在真源只有一个：`rdsh base --print-paths`；
# 本脚本把它渲染成表格，CI 用 `--check` 逐字节比对，手改/漂移就红。
#
# 用法:
#   tools/render-docs.sh            # 写入（更新文档里的块）
#   tools/render-docs.sh --check    # 只校验：不一致 → rc=1 并打印 diff
#   tools/render-docs.sh --help
#
# 文档里的块用标记围起来，块外内容不动：
#   <!-- PATHS:BEGIN -->
#   ...（本脚本生成，勿手改）...
#   <!-- PATHS:END -->
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "$0")"
REPO="$(dirname "$(dirname "$SELF")")"
RDSH="${RDSH_SRC:-$REPO/Rdsh.sh}"
MODE="write"
case "${1:-}" in
  --check) MODE="check" ;;
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
  "") ;;
  *) echo "未知参数：$1（--check / --help）" >&2; exit 2 ;;
esac
[ -f "$RDSH" ] || { echo "找不到 Rdsh.sh：$RDSH" >&2; exit 2; }

BEGIN='<!-- PATHS:BEGIN -->'
END='<!-- PATHS:END -->'

# 渲染块：先问真源，再转成相对 $BASE 的可移植写法
render_block() {
  local BASE MANAGE_ROOT DATA_ROOT SHARED_ROOT BACKUP_ROOT LOG_DIR RUN_DIR STATE_ROOT TRASH_ROOT PLUGIN_ROOT PATCHES_ROOT WEB_PORT
  eval "$(env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
             -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
             -u DSH_LOG_DIR -u DSH_WEB_PORT -u RDSH_PLUGIN_ROOT -u RDSH_TRASH \
             bash "$RDSH" base --print-paths 2>/dev/null)"

  rel() {  # 绝对路径 → 相对 $BASE（可移植）；不在 BASE 下则原样
    case "$1" in
      "$BASE")   printf '$BASE' ;;
      "$BASE"/*) printf '$BASE/%s' "${1#"$BASE"/}" ;;
      *)         printf '%s' "$1" ;;
    esac
  }
  row() { printf '| `%s` | `%s` | `%s` | %s |\n' "$1" "$2" "$3" "$4"; }

  printf '%s\n' "$BEGIN"
  printf '| 派生路径 | 默认值（相对 `$BASE`） | 环境变量覆盖 | 用途 |\n'
  printf '|---|---|---|---|\n'
  printf '| `BASE` | 默认 `$HOME/Mapp`（本机实际值见 `rdsh base`） | `RDSH_BASE` | 唯一旋钮；下列默认值都由它派生 |\n'
  row MANAGE_ROOT "$(rel "$MANAGE_ROOT")" RDSH_MANAGE_ROOT '检出根（`Rdsh.sh` 与各检出所在；经典 `$BASE/dsh` 自动回退）'
  row DATA_ROOT "$(rel "$DATA_ROOT")" RDSH_DATA_ROOT '数据根（每版本一个 `DSH_HOME`）'
  row SHARED_ROOT "$(rel "$SHARED_ROOT")" RDSH_SHARED_HOME '作者资产稳定根（skills / 三库 / AGENTS）'
  row BACKUP_ROOT "$(rel "$BACKUP_ROOT")" RDSH_BACKUP_ROOT '备份根（快照 + 回退基线）'
  row LOG_DIR "$(rel "$LOG_DIR")" DSH_LOG_DIR '启动日志（含访问 token，勿外传）'
  row RUN_DIR "$(rel "$RUN_DIR")" RDSH_RUN_DIR '实例注册表（注解层；真相是 `ss` + `/proc`）'
  row STATE_ROOT "$(rel "$STATE_ROOT")" RDSH_STATE_ROOT '状态账本（唯一权威）：`versions.kv` + `journal.log`'
  row TRASH_ROOT "$(rel "$TRASH_ROOT")" RDSH_TRASH '回收站（默认与 BASE 同文件系统）'
  row PLUGIN_ROOT "$(rel "$PLUGIN_ROOT")" RDSH_PLUGIN_ROOT '插件权威副本'
  row PATCHES_ROOT "$(rel "$PATCHES_ROOT")" RDSH_PATCHES '补丁仓'
  printf '| 默认端口 | `%s` | `DSH_WEB_PORT` / `--port` | dsh web 监听端口 |\n' "$WEB_PORT"
  printf '%s\n' "$END"
}

# 把文件里 BEGIN..END 之间替换成新块（块外不动）
replace_block() {  # <文件> <新块文件>
  local f="$1" blk="$2" tmp="$1.tmp.$$"
  awk -v begin="$BEGIN" -v end="$END" -v blkf="$blk" '
    $0 == begin { while ((getline line < blkf) > 0) print line; close(blkf); inside=1; next }
    $0 == end   { inside=0; next }
    !inside     { print }
  ' "$f" > "$tmp"
  mv -f "$tmp" "$f"
}

# 取文件里的现有块（用于 diff）
extract_block() {  # <文件>
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { inside=1; print; next }
    inside      { print }
    $0 == end   { inside=0 }
  ' "$1"
}

TARGETS=("$REPO/README.md" "$REPO/docs/架构.md")
BLK="$(mktemp)"; trap 'rm -f "$BLK"' EXIT
render_block > "$BLK"

fail=0
for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || { echo "缺文件：$f" >&2; fail=1; continue; }
  if ! grep -qxF "$BEGIN" "$f" || ! grep -qxF "$END" "$f"; then
    echo "✗ $f 缺 PATHS 标记（应含 $BEGIN / $END）" >&2
    fail=1
    continue
  fi
  if extract_block "$f" | diff -u - "$BLK" > /tmp/render-docs-diff.$$ 2>&1; then
    [ "$MODE" = "check" ] && echo "ok  $f"
  else
    if [ "$MODE" = "check" ]; then
      echo "✗ $f 的路径块与真源不一致（手改或漂移）：" >&2
      sed 's/^/    /' /tmp/render-docs-diff.$$ >&2
      fail=1
    else
      replace_block "$f" "$BLK"
      echo "已更新 $f"
    fi
  fi
  rm -f /tmp/render-docs-diff.$$
done

if [ "$MODE" = "check" ]; then
  [ "$fail" = 0 ] && echo "结论：文档路径块与真源一致" || { echo "结论：有不一致，见上" >&2; exit 1; }
else
  [ "$fail" = 0 ] && echo "结论：文档已同步" || exit 1
fi
