#!/usr/bin/env bash
# =============================================================================
# publish.sh —— 把本机（权威）的 rdsh 脚本集中进发布仓库
#
# 定位：**维护者工具**，不是 rdsh 的运行时组件。
#
# 为什么需要它：本机的工作目录里既有脚本，也有 6G+ 的 dsh 检出（上游代码）。
#   发布仓库必须只含「干净的一套」，所以按**显式白名单逐个文件搬运**，绝不通配扫目录。
#
# 权威方向：本机 → 仓库（单向）。数据在本机生成，云端只是发布快照。
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(dirname "$SELF_DIR")"                 # tools/ 的上一层 = 仓库根
FROM="${RDSH_PUBLISH_FROM:-$HOME/Mapp/dsh}"    # 本机工作目录
MODE=""
DRY=0

# ---- 白名单：只有这些文件会被发布（写死，不用通配符扫目录） ----
FILES="Rdsh.sh migrate.sh reindex-workspaces.sh plugin-sync.sh rdsh-restart.sh patch-manager.sh"

usage() {
  echo "publish.sh —— 把本机的 rdsh 脚本集中进发布仓库（单向：本机 -> 仓库）"
  echo
  echo "用法:"
  echo "  publish.sh --check             只读：列出本机与仓库的差异"
  echo "  publish.sh --stage             把白名单文件从本机拷进仓库，并打印 git status"
  echo "  publish.sh --stage --dry-run   只打印将要做什么"
  echo
  echo "选项:"
  echo "  --from <目录>   本机脚本所在（默认 $HOME/Mapp/dsh，或环境变量 RDSH_PUBLISH_FROM）"
  echo "  --repo <目录>   发布仓库根（默认为本脚本所在的仓库）"
  echo "  -h, --help      显示本帮助"
  echo
  echo "白名单（只有这些文件会被搬运）："
  for f in $FILES; do echo "    $f"; done
}

log()  { echo "[publish] $*"; }
warn() { echo "[publish!] $*" >&2; }
die()  { echo "[publish!] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --stage) MODE=stage ;;
    --from) shift; FROM="${1:-}" ;;
    --repo) shift; REPO="${1:-}" ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift || true
done

[ -n "$MODE" ] || { usage; exit 1; }
[ -d "$FROM" ] || die "源目录不存在：$FROM（用 --from 指定）"
[ -d "$REPO/.git" ] || die "目标不是 git 仓库：$REPO（用 --repo 指定）"

echo "本机：$FROM"
echo "仓库：$REPO"
echo
diff_n=0; miss_n=0
for f in $FILES; do
  if [ ! -f "$FROM/$f" ]; then
    warn "本机缺文件：$f"; miss_n=$((miss_n+1)); continue
  fi
  if [ ! -f "$REPO/$f" ]; then
    echo "  新增  $f"; diff_n=$((diff_n+1))
  elif cmp -s "$FROM/$f" "$REPO/$f"; then
    echo "  一致  $f"
  else
    echo "  不同  $f"; diff_n=$((diff_n+1))
  fi
done
echo

if [ "$MODE" = "check" ]; then
  if [ "$diff_n" -eq 0 ] && [ "$miss_n" -eq 0 ]; then
    log "仓库与本机一致（检查了 6 个白名单文件）"
    exit 0
  fi
  log "有 $diff_n 个文件需要 --stage"
  exit 1
fi

# ---- stage ----
[ "$miss_n" -eq 0 ] || die "本机缺 $miss_n 个文件，先补齐再发布"
if [ "$DRY" = "1" ]; then
  log "dry-run：将把上面标为「新增/不同」的文件从本机拷进仓库"
  exit 0
fi
for f in $FILES; do
  cp -p "$FROM/$f" "$REPO/$f"
done
log "已集中 6 个文件进仓库"
echo
log "git status（应只涉及上面那些文件）："
git -C "$REPO" status --short
echo
extra=$(git -C "$REPO" status --porcelain | grep -c '^??' || true)
if [ "$extra" -gt 0 ]; then
  warn "仓库里有 $extra 个未跟踪文件（上面的 ?? 行）—— 提交前确认它们该不该发布"
fi
log "下一步：cd $REPO && git add -A && git commit -m '...' && git push"
