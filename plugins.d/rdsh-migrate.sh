#!/usr/bin/env bash
# =============================================================================
# rdsh-migrate.sh —— 版本迁移前门（rdsh 外部能力；`rdsh migrate …`）
#
# 定位：只负责“流程”——选提供者 → plan 闸门 → 真迁移写日志 → 打印下一步。
#       版本差异交给提供者脚本：
#         通用版 = $MANAGE_ROOT/migrate.sh（原名原位置）
#         特化版 = $MANAGE_ROOT/migrate-<from>-to-<to>[-<id>].sh（同目录，文件头自述）
#
# 设计约束（用户 2026-10-28/11-01）：
#   - 不新开目录、不建 registry；统一地址 $MANAGE_ROOT，靠命名+文件头区分；
#   - 脚本不做图形界面，`rdsh migrate` 零交互：所有选择显式给参数；
#   - `-f/--force` 只越过提供者声明的可强制错误；安全闸门永远硬停；
#   - 迁移后不自动启动目标，打印 `rdsh start <to>` 与验收清单。
#
# 用法见 --help。
# =============================================================================
set -euo pipefail

IFACE=1
PROG="$(basename "$0")"
TS="$(date +%Y%m%d-%H%M%S)"

die() { printf '错误: %s\n' "$*" >&2; exit 2; }
log() { printf '[migrate] %s\n' "$*"; }
warn() { printf '[migrate!] %s\n' "$*" >&2; }
usage() { sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 根解析：优先用 rdsh 已解析的环境；直接运行则回退配置文件 ----
cfg_get() {
  local f="${RDSH_CONFIG:-$HOME/.config/rdsh/config}" v=""
  [ -f "$f" ] || return 0
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$f" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}
BASE="${RDSH_BASE:-$(cfg_get BASE)}"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
MANAGE_ROOT="${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}"; [ -n "$MANAGE_ROOT" ] || MANAGE_ROOT="$BASE/rdsh"
# 可移植性回退：脚本所在目录就是 rdsh 部署目录
_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ -f "$MANAGE_ROOT/Rdsh.sh" ] || MANAGE_ROOT="$(dirname "$_self_dir")"
DATA_ROOT="${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}"; [ -n "$DATA_ROOT" ] || DATA_ROOT="$BASE/.dsh-suite/data"
BACKUP_ROOT="${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}"; [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-suite/backup"
LOG_DIR="${RDSH_LOG_DIR:-$(cfg_get LOG_DIR)}"; [ -n "$LOG_DIR" ] || LOG_DIR="$BASE/.dsh-suite/logs"
ALL_ITEMS="sessions,storages,settings,credentials,assets,plugins,profile,probe"
GENERIC="$MANAGE_ROOT/migrate.sh"

# ---- 提供者发现 ----
PROV_ID="" PROV_FILE="" PROV_FROM="" PROV_TO="" PROV_ITEMS="" PROV_SUMMARY=""
provider_rows() {  # 输出：id|file|from|to|items|summary（每行一个）
  # 通用版
  [ -f "$GENERIC" ] && printf 'generic|%s|*|*|%s|通用版迁移器（应急可直接 bash migrate.sh）\n' "$GENERIC" "$ALL_ITEMS"
  local f meta from to id items summary
  for f in "$MANAGE_ROOT"/migrate-*.sh; do
    [ -f "$f" ] || continue
    meta="$(sed -n 's/^# rdsh-migrate: //p' "$f" | head -1)"
    [ -n "$meta" ] || { warn "特化脚本缺文件头，跳过：$f（需要一行 '# rdsh-migrate: from=… to=…'）"; continue; }
    from="$(printf '%s\n' "$meta" | sed -nE 's/.*from=([^ ]+).*/\1/p')"
    to="$(printf '%s\n' "$meta" | sed -nE 's/.*to=([^ ]+).*/\1/p')"
    id="$(printf '%s\n' "$meta" | sed -nE 's/.*id=([^ ]+).*/\1/p')"
    items="$(printf '%s\n' "$meta" | sed -nE 's/.*items=([^ ]+).*/\1/p')"
    summary="$(printf '%s\n' "$meta" | sed -nE 's/.*summary=//p')"
    [ -n "$from" ] && [ -n "$to" ] || { warn "特化脚本文件头缺 from/to，跳过：$f"; continue; }
    [ -n "$id" ] || id="$(basename "$f" .sh)"
    [ -n "$items" ] || items="$ALL_ITEMS"
    printf '%s|%s|%s|%s|%s|%s\n' "$id" "$f" "$from" "$to" "$items" "${summary:-未写说明}"
  done
}
match_provider() {  # <from> <to>：过滤匹配行
  local f t r pf pt
  f="$1"; t="$2"
  provider_rows | awk -F'|' -v f="$f" -v t="$t" '((f=="*"||$3=="*"||$3==f) && (t=="*"||$4=="*"||$4==t)) {print}'
}
resolve_provider() {  # <from> <to> [--provider id]
  local from="$1" to="$2" want="${3:-}" rows n
  rows="$(match_provider "$from" "$to")"
  if [ -z "$rows" ]; then die "没有能处理 $from → $to 的迁移提供者（看 $MANAGE_ROOT/migrate*.sh）"; fi
  if [ -n "$want" ]; then
    PROV_LINE="$(printf '%s\n' "$rows" | awk -F'|' -v w="$want" '$1==w')"
    [ -n "$PROV_LINE" ] || die "没有 id=$want 的提供者（可用：$(printf '%s\n' "$rows" | cut -d'|' -f1 | paste -sd, -)）"
  else
    n="$(printf '%s\n' "$rows" | grep -c . || true)"
    if [ "$n" -gt 1 ]; then
      printf '[migrate] 找到 %s 个可用的迁移提供者：\n' "$n" >&2
      printf '%s\n' "$rows" | awk -F'|' '{printf "  [%s] %s（%s）—— %s\n", NR, $1, $2, $6}' >&2
      die "存在多个提供者：请显式加 --provider <id> 选择（不做交互）"
    fi
    PROV_LINE="$rows"
  fi
  IFS='|' read -r PROV_ID PROV_FILE PROV_FROM PROV_TO PROV_ITEMS PROV_SUMMARY <<< "$PROV_LINE"
}

# ---- 参数 ----
FROM="" TO="" ITEMS="" SESSIONS="none" SESSIONS_FILE="" DRY=0 FORCE=0 PROVIDER="" LIST=0
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --manifest )
      cat <<MF
iface=1
x-rdsh-migrate|migrate|--from <ver> --to <ver> (--all / --items a,b,c) [--sessions none/all/file:<json>] [--dry-run] [-f] [--provider id]|write|--dry-run|版本迁移前门：选提供者+plan 闸门+真迁移写日志（零交互）
MF
      exit 0 ;;
    --from) [ $# -ge 2 ] || die '--from 需要值'; FROM="$2"; shift 2 ;;
    --from=*) FROM="${a#--from=}"; shift ;;
    --to) [ $# -ge 2 ] || die '--to 需要值'; TO="$2"; shift 2 ;;
    --to=*) TO="${a#--to=}"; shift ;;
    --items) [ $# -ge 2 ] || die '--items 需要值'; ITEMS="$2"; shift 2 ;;
    --items=*) ITEMS="${a#--items=}"; shift ;;
    -a|--all) ITEMS="$ALL_ITEMS"; shift ;;
    --sessions) [ $# -ge 2 ] || die '--sessions 需要值'; SESSIONS="$2"; shift 2 ;;
    --sessions=*) SESSIONS="${a#--sessions=}"; shift ;;
    --sessions-file) [ $# -ge 2 ] || die '--sessions-file 需要路径'; SESSIONS=file; SESSIONS_FILE="$2"; shift 2 ;;
    --sessions-file=*) SESSIONS=file; SESSIONS_FILE="${a#--sessions-file=}"; shift ;;
    --dry-run|--plan) DRY=1; shift ;;
    -f|--force) FORCE=1; shift ;;
    --provider) [ $# -ge 2 ] || die '--provider 需要 id'; PROVIDER="$2"; shift 2 ;;
    --provider=*) PROVIDER="${a#--provider=}"; shift ;;
    --list|--list-providers) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知选项：$a（用 rdsh migrate --help）" ;;
    *) if [ -z "$FROM" ]; then FROM="$a"; elif [ -z "$TO" ]; then TO="$a"; else die "多余参数：$a"; fi; shift ;;
  esac
done

if [ "$LIST" = 1 ]; then
  [ -n "$FROM" ] && [ -n "$TO" ] || { FROM="${FROM:-*}"; TO="${TO:-*}"; }
  printf '迁移提供者（from=%s to=%s）：\n' "$FROM" "$TO"
  match_provider "$FROM" "$TO" | awk -F'|' '{printf "  %-24s %-38s from=%-14s to=%-14s %s\n", $1, $2, $3, $4, $6}'
  exit 0
fi
[ -n "$FROM" ] && [ -n "$TO" ] || die '需要 --from <ver> 与 --to <ver>（所有参数显式；无默认）'
[ -n "$ITEMS" ] || die '需要显式选内容：-a/--all 或 --items a,b,c'
case ",$ITEMS," in *,all,*) ITEMS="$ALL_ITEMS" ;; esac
# 规范/校验 items
_norm=""; IFS_SAVE="$IFS"; IFS=','
for it in $ITEMS; do
  it="$(printf '%s' "$it" | tr -d '[:space:]')"; [ -n "$it" ] || continue
  case ",$ALL_ITEMS," in *",$it,"*) ;; *) die "未知 items：$it（可选：$ALL_ITEMS）" ;; esac
  case ",$_norm," in *",$it,"*) ;; *) _norm="${_norm:+$_norm,}$it" ;; esac
done
IFS="$IFS_SAVE"; ITEMS="$_norm"
[ -n "$ITEMS" ] || die '--items 不能为空'
case "$SESSIONS" in
  file:* ) SESSIONS_FILE="${SESSIONS#file:}"; SESSIONS=file ;;
  none|all|file ) ;;
  *) die '--sessions 只能是 none|all|file（file 需 --sessions-file）' ;;
esac
[ "$SESSIONS" = file ] && [ -z "$SESSIONS_FILE" ] && die '--sessions=file 需要 --sessions-file <json>' 

resolve_provider "$FROM" "$TO" "$PROVIDER"
# 安全闸门：目标 home 已有实例在跑 → 硬停（-f 也不越过）
TARGET_HOME="$DATA_ROOT/$TO"
if [ -n "${TARGET_HOME:-}" ] && [ -d "$TARGET_HOME" ]; then
  for p in /proc/[0-9]*; do
    [ -r "$p/environ" ] || continue
    h="$(cat "$p/environ" 2>/dev/null | tr '\0' '\n' | sed -nE 's/^DSH_HOME=(.*)$/\1/p' | head -1 || true)"
    [ "$h" = "$TARGET_HOME" ] && { warn "安全闸门：目标 home 有实例在跑（pid ${p#/proc/}，$TARGET_HOME）——先停它，-f 也不越过"; exit 3; }
  done
fi
# 提供者声明的 items 必须覆盖请求项
for it in $(printf '%s' "$ITEMS" | tr ',' ' '); do
  case ",$PROV_ITEMS," in *",$it,"*) ;; *) die "提供者 $PROV_ID 不支持 items=$it（支持：$PROV_ITEMS）；换 --provider 或去掉该项" ;; esac
done

log "提供者：$PROV_ID（$PROV_FILE）"
log "内容：$ITEMS；会话：$SESSIONS"
PROV_SH="$PROV_FILE"
LOG_FILE="$LOG_DIR/migrate-$FROM-to-$TO-$TS.log"
PLAN_FILE="$LOG_DIR/migrate-$FROM-to-$TO-$TS.plan.log"
ARCHIVE_DIR="$BACKUP_ROOT/migrate-$FROM-to-$TO-$TS-provider"

run_provider() {  # <mode: plan|apply>
  local mode="$1"; shift
  local -a args=("$FROM" "$TO" "--items=$ITEMS")
  case "$SESSIONS" in
    none ) args+=("--sessions=none") ;;
    all ) args+=("--sessions=all") ;;
    file ) args+=("--sessions-file=$SESSIONS_FILE") ;;
  esac
  if [ "$mode" = plan ]; then args+=("--dry-run"); fi
  if [ "$FORCE" = 1 ]; then args+=("--force"); fi
  if [ "$mode" = plan ]; then
    bash "$PROV_SH" "${args[@]}"
  else
    bash "$PROV_SH" "${args[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi
}

# plan 闸门：总是先跑（plan 本身零写入）
set +e
PLAN_OUT="$(run_provider plan 2>&1)"; PLAN_RC=$?
set -e
printf '%s\n' "$PLAN_OUT"
if [ "$PLAN_RC" != 0 ]; then
  if [ "$FORCE" != 1 ]; then
    warn "plan 发现错误（退出码 $PLAN_RC）。若确认这些错误可忽略，加 -f/--force 重跑；"
    warn "安全闸门（目标在跑/无备份/磁盘/权限/隐私）不会被 -f 越过。"
    exit 2
  fi
  warn "plan 退出码 $PLAN_RC；按 -f 继续（将记录为强制迁移）"
fi
if [ "$DRY" = 1 ]; then
  log "dry-run：只打印计划，未写入任何文件"
  exit 0
fi

mkdir -p "$(dirname "$PLAN_FILE")" "$LOG_DIR"
printf '%s\n' "$PLAN_OUT" > "$PLAN_FILE"

# 归档本次提供者与 plan（只读证据；特化脚本可随后删除）
mkdir -p "$ARCHIVE_DIR"
cp -a "$PROV_SH" "$ARCHIVE_DIR/provider-$(basename "$PROV_SH")"
cp -a "$PLAN_FILE" "$ARCHIVE_DIR/plan.log"
log "真迁移开始，日志：$LOG_FILE"
set +e
run_provider apply; APPLY_RC=$?
set -e
if [ "$APPLY_RC" != 0 ]; then
  warn "迁移失败（退出码 $APPLY_RC）。源 home 应保持只读；日志：$LOG_FILE"
  exit "$APPLY_RC"
fi
log "迁移完成。下一步（由人执行）：rdsh start $TO"
cat <<EOF
验收清单：
  1) 启动日志无 failed to import / did not activate / patch: entry ... not found
  2) 关键界面（本地插件等）在
  3) 工具可用、LLM 可用
  4) 会话内 compat_check 的 C 维无异常
确认“可用”后再写入账本/记录；不要自动启动目标实例。
EOF
exit 0
