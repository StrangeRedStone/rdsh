#!/usr/bin/env bash
# =============================================================================
# reindex-workspaces.sh —— 重建工作区归属（按会话 header 的 cwd 重新归组）
#
# 背景（0.1.3/0.1.5/0.1.6 通用机制，见 <checkout>/packages/workspace/workspace/src/index.ts）：
#   启动时 WorkspaceRegistry 读 storages/workspace.json：
#     initialized == false → 扫所有已存会话，按**每个会话 header 的 cwd**归入工作区（一次性 bootstrap）
#     initialized == true  → 只重建 header 索引，**不新增任何成员**
#   所以：手工拷进来的会话目录，在 initialized=true 时永远进不了工作区，UI 显示「未分组」。
#
# 用途：迁移/拷贝会话之后，让 DSH 自己按 cwd 重新归组（不用手改 sessionIds）。
#
# 用法:
#   reindex-workspaces.sh [版本|数据目录] [--dry-run]
#     不给参数：用 $DSH_HOME；也没有则取 $DSH_DATA_ROOT 下最新的有 workspace.json 的数据目录
#
# 前置（重要）：**必须先停掉该版本的实例**。运行中的进程持有内存状态，退出时会写回
#   workspace.json，把这里的修改覆盖掉。
#
# 还原：脚本会先备份为 workspace.json.bak-reindex-<ts>，并打印拷回命令。
# =============================================================================
set -euo pipefail

# ---------------- 根目录解析：与 Rdsh.sh 同一套规则（环境变量 > 配置文件 > 默认） ----------------
RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"
cfg_get() {
  [ -f "$RDSH_CONFIG" ] || return 0
  local v
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}
expand_tilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
BASE="$(expand_tilde "${RDSH_BASE:-$(cfg_get BASE)}")"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
MANAGE_ROOT="$(expand_tilde "${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}")"
if [ -z "$MANAGE_ROOT" ]; then
  MANAGE_ROOT="$BASE/dsh"
  # 可移植性回退：$BASE/dsh 不是本工具所在处时，改用脚本自身目录（clone 到任意目录也能跑）
  if [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    _self_dir="$(dirname "$(readlink -f "$0")")"
    if [ -f "$_self_dir/Rdsh.sh" ]; then MANAGE_ROOT="$_self_dir"; fi
  fi
fi
DATA_ROOT="$(expand_tilde "${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}")";         [ -n "$DATA_ROOT" ]   || DATA_ROOT="$BASE/.dsh"
BACKUP_ROOT="$(expand_tilde "${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}")";   [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-backup"
SHARED_ROOT="$(expand_tilde "${RDSH_SHARED_HOME:-$(cfg_get SHARED_ROOT)}")";   [ -n "$SHARED_ROOT" ] || SHARED_ROOT="$BASE/.dsh-shared"
PLUGIN_ROOT="$(expand_tilde "${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}")";   [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$BASE/dsh-plugins"
DRY=0
ARG=""

log()  { printf '\033[1;34m[reindex]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[reindex!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[reindex!]\033[0m %s\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "未知选项：$a" ;;
    *) ARG="$a" ;;
  esac
done

# ---- 解析目标 home ----
read_version() {
  local d="$1" v=""
  [ -f "$d/package.json" ] && v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$d/package.json" | head -1)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$d")"
}
resolve_home() {
  local arg="$1" best="" bestv="" d v
  if [ -n "$arg" ]; then
    [[ "$arg" == ~* ]] && arg="${arg/#\~/$HOME}"
    if [ -d "$arg" ]; then printf '%s' "$arg"; return; fi
    for d in "$MANAGE_ROOT"/*/; do
      d="${d%/}"; v="$(read_version "$d")"
      if [ "$v" = "$arg" ] || [ "$(basename "$d")" = "$arg" ] \
         || [[ "$v" == *"$arg"* ]] || [[ "$(basename "$d")" == *"$arg"* ]]; then
        [ -f "$DATA_ROOT/$v/storages/workspace.json" ] || die "该版本没有 $DATA_ROOT/$v/storages/workspace.json"
        printf '%s' "$DATA_ROOT/$v"; return
      fi
    done
    die "找不到匹配「$arg」的版本/检出（看 $MANAGE_ROOT）"
  fi
  if [ -n "${DSH_HOME:-}" ] && [ -f "$DSH_HOME/storages/workspace.json" ]; then
    # 在 DSH 会话里跑时，当前实例的数据根优先于配置文件里的 BASE（最贴近"我现在在哪个版本"）
    warn "未指定目标：用当前实例的 DSH_HOME=$DSH_HOME（要按 BASE 走请显式给版本或路径）"
    printf '%s' "$DSH_HOME"; return
  fi
  for d in "$DATA_ROOT"/*/; do
    d="${d%/}"
    [ -f "$d/storages/workspace.json" ] || continue
    if [ -z "$best" ] || [ "$d" -nt "$best" ]; then best="$d"; bestv="$(basename "$d")"; fi
  done
  [ -n "$best" ] || die "在 $DATA_ROOT 下找不到任何带 storages/workspace.json 的数据目录"
  warn "未指定目标，取最新的：$bestv"
  printf '%s' "$best"
}

HOME_DIR="$(resolve_home "$ARG")"
WF="$HOME_DIR/storages/workspace.json"
[ -f "$WF" ] || die "找不到 $WF"

log "目标数据目录：$HOME_DIR"
log "workspace.json：$WF"

# ---- 安全检查：该 home 的实例是否还在跑 ----
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q '127.0.0.1:3080$'; then
  pid="$(ss -ltnp 2>/dev/null | awk '/127.0.0.1:3080/{match($0,/pid=[0-9]+/); print substr($0,RSTART+4,RLENGTH-4)}' | head -1)"
  running_home=""
  [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] && running_home="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DSH_HOME=//p')"
  if [ "$running_home" = "$HOME_DIR" ]; then
    if [ "$DRY" = "1" ]; then
      warn "该数据目录的实例正在运行（PID $pid）—— 真跑前必须先 Ctrl+C 停掉它，否则退出时会覆盖修改"
    else
      die "该数据目录的实例正在运行（PID $pid）—— 先 Ctrl+C 停掉再跑本脚本，否则退出时会覆盖本次修改"
    fi
  else
    warn "3080 上有别的实例在跑（DSH_HOME=${running_home:-未知}），与本目标不同，继续"
  fi
fi

# ---- 当前状态 ----
if command -v python3 >/dev/null 2>&1; then
  python3 - "$WF" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
g=d.get('global',{})
print(f"  当前 initialized = {g.get('initialized')}   工作区 {len(d.get('tables',{}).get('workspaces',{}))} 个")
EOF
else
  die "需要 python3"
fi

if [ "$DRY" = "1" ]; then
  log "[dry-run] 将把 global.initialized 置为 false，并备份为 $WF.bak-reindex-<ts>"
  log "[dry-run] 之后重启该版本：bootstrap 会按每个会话 header 的 cwd 重新归组（无变化的记录保持原样）"
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
BAK="$WF.bak-reindex-$TS"
cp -a "$WF" "$BAK"
log "已备份：$BAK"

python3 - "$WF" <<'EOF'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
before=d.get('global',{}).get('initialized')
d.setdefault('global',{})['initialized']=False
json.dump(d, open(p,'w'), ensure_ascii=False, separators=(',',':'))
print(f"  initialized: {before} → False")
EOF

log "完成。下一步："
printf '    rdsh start %s\n' "$(basename "$HOME_DIR")"
printf '  启动时 WorkspaceRegistry 会做一次性 bootstrap：按 cwd 把已存会话归入对应工作区。\n'
printf '  若结果不对，还原：cp -a "%s" "%s"\n' "$BAK" "$WF"
