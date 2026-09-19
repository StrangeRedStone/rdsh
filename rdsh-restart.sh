#!/bin/bash
# =============================================================================
# rdsh-restart.sh —— 安全重启当前 dsh web 实例（含 systemd 逃生舱）
#
# 为什么需要它：Rdsh.sh 没有 stop/restart 子命令，而 `rdsh start` 一旦发现
# 127.0.0.1:3080 被占用就直接 die。所以"重启"必须自己完成：
#   识别端口 owner PID → 优雅 SIGTERM → 等端口释放 → 重新拉起。
#
# 三条硬约束（2026-09-18 实测）：
#   1. 新实例必须由 `systemd-run --user` 新建 unit 拉起：实测其 cgroup 与
#      `dsh-subprocess-<pid>-<hash>.scope` 平级，不在 DSH 关停时的 managed range 内；
#      否则新进程会随旧进程一起被杀。
#   2. 禁用 pkill/pgrep -f（自匹配误杀 + 家规 + guard-rails 硬拦）：
#      只对端口 owner PID 发信号，且发信号前必须核对进程归属。
#   3. 必须等端口释放再启动，否则新 rdsh 会因端口占用 die。
#
# 额外保险：如果脚本是从 DSH 自己的子进程里跑起来的（比如 agent 的 bash 工具），
# 它会先把"自己"重新投递到 systemd 单元里再退出 —— 否则脚本会被它自己触发的
# 关停流程一起杀掉，重启做到一半就断了。
#
# 用法：
#   rdsh-restart.sh                       # 重启"当前正在运行的那个检出"
#   rdsh-restart.sh 0.1.6-alpha.1         # 重启到指定版本/序号/项目名/路径
#   rdsh-restart.sh --dry-run             # 只打印计划，什么都不做（可安全随时跑）
#   rdsh-restart.sh --delay 5             # 杀旧实例前多等 5 秒（默认 3，留给调用方落盘）
#   rdsh-restart.sh --force               # 目标与在跑的检出不同时也照做
#   rdsh-restart.sh --no-detach           # 禁止自动投递到 systemd（交互排障用）
#   rdsh-restart.sh --probe               # 危险动作演练：照常投递到 systemd 单元，
#                                         #   但单元里只走到"该杀谁、该起什么"为止，
#                                         #   不真的 kill、不真的启动（验证投递链路用）
#
# 环境变量：
#   DSH_RESTART_DELAY    等价于 --delay
#   DSH_RESTART_TIMEOUT  等端口释放/恢复的秒数（默认 30）
#   DSH_RESTART_LOGDIR   日志目录（默认 <BASE>/.dsh-logs）
#   DSH_WEB_PORT         端口（默认 3080）
#
# 退出码：0 成功（含 dry-run）；1 参数/前置条件错误；2 过程中失败
# =============================================================================

set -u

SELF="$(readlink -f "$0")"
PORT="${DSH_WEB_PORT:-3080}"
DELAY="${DSH_RESTART_DELAY:-3}"
TIMEOUT="${DSH_RESTART_TIMEOUT:-30}"
FORCE=0
DRY=0
PROBE=0
NO_DETACH=0
TARGET=""
TS="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;34m[restart]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[restart!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[restart!]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# ---- BASE / 日志目录：与 Rdsh.sh 同一套解析（env > ~/.config/rdsh/config > 默认）----
RDSH_CONFIG="$HOME/.config/rdsh/config"
cfg_get() {
  [ -f "$RDSH_CONFIG" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1 \
    | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}
expand_tilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
BASE="$(expand_tilde "${RDSH_BASE:-$(cfg_get BASE)}")"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
LOG_DIR="$(expand_tilde "${DSH_RESTART_LOGDIR:-${DSH_LOG_DIR:-$(cfg_get LOG_DIR)}}")"; [ -n "$LOG_DIR" ] || LOG_DIR="$BASE/.dsh-logs"
MANAGE_ROOT="$(expand_tilde "${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}")"
if [ -z "$MANAGE_ROOT" ]; then
  MANAGE_ROOT="$BASE/dsh"
  # 可移植性回退：$BASE/dsh 不是本工具所在处时，改用本脚本所在目录
  if [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    _self_dir="$(dirname "$SELF")"
    if [ -f "$_self_dir/Rdsh.sh" ]; then MANAGE_ROOT="$_self_dir"; fi
  fi
fi
RDSH_BIN="$MANAGE_ROOT/Rdsh.sh"

# 若被投递到 systemd 单元执行，统一把输出落到日志文件
if [ -n "${DSH_RESTART_LOG:-}" ]; then
  exec >>"$DSH_RESTART_LOG" 2>&1
  log "（本次运行由 systemd 单元执行，日志：$DSH_RESTART_LOG）"
fi

# ---------------------------------------------------------------- 进程/端口工具
port_listening() { ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . ; }

port_pid() {  # 端口 owner PID；查不到则空（ss -p 需要同用户权限，本脚本与 DSH 同用户）
  ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

proc_cwd()     { readlink "/proc/$1/cwd" 2>/dev/null; }
proc_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
proc_ppid()    { awk '{print $4}' "/proc/$1/stat" 2>/dev/null; }

# 端口 owner 必须确实是"我们的 dsh web"：cwd 是 dsh 检出、命令行是 web 入口
assert_owned_by_dsh() {  # <pid> -> 0/1
  local pid="$1" cwd cmd
  cwd="$(proc_cwd "$pid")"; cmd="$(proc_cmdline "$pid")"
  [ -n "$cwd" ] || return 1
  case "$cwd" in *deepseek-harness*) ;; *) return 1 ;; esac
  case "$cmd" in *"bin.ts web"*|*"dsh web"*) ;; *) return 1 ;; esac
  return 0
}

# 当前 shell 的祖先链里有没有 dsh web 主进程 → 决定是否需要"投递到 systemd"
inside_dsh() {
  local p=$$ cmd guard=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$guard" -lt 64 ]; do
    cmd="$(proc_cmdline "$p")"
    case "$cmd" in *"bin.ts web"*) return 0 ;; esac
    p="$(proc_ppid "$p")"; guard=$((guard + 1))
  done
  return 1
}

# ---------------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --probe)      PROBE=1 ;;
    --force)      FORCE=1 ;;
    --no-detach)  NO_DETACH=1 ;;
    --delay)      shift; DELAY="${1:-3}" ;;
    --timeout)    shift; TIMEOUT="${1:-30}" ;;
    --port)       shift; PORT="${1:-3080}" ;;
    -h|--help)    sed -n '2,/^# =\{20,\}$/p' "$SELF"; exit 0 ;;
    --)           shift; TARGET="${1:-}"; break ;;
    -*)           die "未知参数：$1（--help 看用法）" ;;
    *)            TARGET="$1" ;;
  esac
  shift
done
case "$DELAY" in ''|*[!0-9]*) die "--delay 需要非负整数，收到：$DELAY" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout 需要非负整数，收到：$TIMEOUT" ;; esac

[ -x "$RDSH_BIN" ] || die "找不到可执行的 rdsh：$RDSH_BIN（用 RDSH_BASE 指定基目录）"
command -v systemd-run >/dev/null || die "系统没有 systemd-run：本脚本强依赖它把新实例拉出 DSH 的 cgroup（见 --help 顶部说明）"

# --------------------------------------------------------- 逃生舱：投递到 systemd
if [ "$DRY" = "0" ] && [ "$NO_DETACH" = "0" ] && [ "${DSH_RESTART_DETACHED:-0}" != "1" ] && inside_dsh; then
  mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR" 2>/dev/null || true
  UNIT="rdsh-restart-$TS"
  LOGFILE="$LOG_DIR/restart-$TS.log"
  ( umask 077; : >"$LOGFILE" )
  args=(--user --unit="$UNIT" --collect --setenv=PATH="$PATH" --setenv=DSH_RESTART_DETACHED=1 --setenv=DSH_RESTART_LOG="$LOGFILE")
  script_args=("$SELF" --delay "$DELAY" --timeout "$TIMEOUT" --port "$PORT")
  [ "$PROBE" = "1" ] && script_args+=(--probe)          # 必须排在脚本名之后，否则被 systemd-run 当成自己的选项
  [ -n "$TARGET" ] && script_args+=("$TARGET")
  systemd-run "${args[@]}" "${script_args[@]}" >/dev/null 2>&1 \
    || die "投递到 systemd 失败（systemd-run --user 不可用？）" 2
  log "检测到本脚本运行在 DSH 的子进程里 → 已投递到 systemd 单元：$UNIT"
  log "该单元将于 $DELAY 秒后重启 dsh（端口 $PORT）。进度看：$LOGFILE"
  log "也可以：systemctl --user status $UNIT"
  exit 0
fi

# ------------------------------------------------------------------ 1) 找旧实例
OLD_PID=""; OLD_CWD=""
if port_listening; then
  OLD_PID="$(port_pid)"
  if [ -z "$OLD_PID" ]; then
    die "端口 $PORT 被占用，但拿不到 owner PID（ss -p 无权限？）。为安全起见不做任何动作。" 2
  fi
  OLD_CWD="$(proc_cwd "$OLD_PID")"
  if ! assert_owned_by_dsh "$OLD_PID"; then
    warn "占用端口 $PORT 的 PID $OLD_PID 看起来不是 dsh web："
    warn "  cwd = ${OLD_CWD:-?}"
    warn "  cmd = $(proc_cmdline "$OLD_PID")"
    [ "$FORCE" = "1" ] || die "拒绝动它。确认无误可加 --force。" 2
    warn "--force 已给：仍将继续。"
  fi
fi

# ------------------------------------------------------------------ 2) 定目标
# 默认重启"正在跑的那个检出"；没有在跑的实例则交给 rdsh 的默认项。
if [ -n "$TARGET" ]; then
  REQ="$TARGET"
elif [ -n "$OLD_CWD" ]; then
  REQ="$OLD_CWD"
else
  REQ=""
fi

# 用 rdsh 自己的解析器校验目标（--dry-run 不做端口检查、不写任何东西）
DRY_OUT="$("$RDSH_BIN" start --dry-run ${REQ:+"$REQ"} 2>&1)"
DRY_RC=$?
if [ "$DRY_RC" != "0" ]; then
  printf '%s\n' "$DRY_OUT" >&2
  die "目标无法解析（rdsh start --dry-run 退出码 $DRY_RC）" 2
fi
PLAIN="$(printf '%s' "$DRY_OUT" | sed -E 's/\x1b\[[0-9;]*m//g')"
NEW_VER="$(printf '%s\n' "$PLAIN" | sed -nE 's/^\[rdsh\] 启动版本:[[:space:]]*(.*)$/\1/p' | tail -1)"
NEW_DIR="$(printf '%s\n' "$PLAIN" | sed -nE 's/^\[rdsh\] 检出目录:[[:space:]]*(.*)$/\1/p' | tail -1)"
NEW_HOME="$(printf '%s\n' "$PLAIN" | sed -nE 's/^DSH_HOME[[:space:]]*:[[:space:]]*(.*)$/\1/p' | tail -1)"
[ -n "$NEW_DIR" ] || die "解析不出目标检出目录，rdsh 输出：$PLAIN" 2

if [ -n "$OLD_CWD" ] && [ "$(readlink -f "$OLD_CWD")" != "$(readlink -f "$NEW_DIR")" ]; then
  warn "在跑的检出与目标不同："
  warn "  在跑：$OLD_CWD"
  warn "  目标：$NEW_DIR"
  [ "$FORCE" = "1" ] || die "拒绝换版本重启（如确需，请用 rdsh start 手动切换，或加 --force）。" 2
fi

# ------------------------------------------------------------------ 3) 打印计划
log "=============================================================="
log " 重启计划"
log "   端口        : $PORT"
log "   旧实例 PID  : ${OLD_PID:-（无，端口空闲）}"
log "   旧实例 检出 : ${OLD_CWD:-—}"
log "   新实例 版本 : ${NEW_VER:-?}"
log "   新实例 检出 : $NEW_DIR"
log "   新实例 数据 : ${NEW_HOME:-?}"
log "   延迟        : ${DELAY}s 后杀旧实例"
log "   等待上限    : ${TIMEOUT}s"
log "=============================================================="

if [ "$DRY" = "1" ]; then
  log "--dry-run：到此为止，未做任何改动。"
  exit 0
fi

if [ "$PROBE" = "1" ]; then
  log "--probe：投递链路验证结束 —— 不 kill、不启动。"
  log "（若这是真跑，接下来会：kill -TERM ${OLD_PID:-无} → 等端口 $PORT 释放 → systemd-run 起 $NEW_DIR）"
  exit 0
fi

# ------------------------------------------------------------------ 4) 延迟（让调用方先把结果落盘）
if [ "$DELAY" -gt 0 ]; then
  log "等待 ${DELAY}s（给调用方/当前回合落盘的时间）…"
  sleep "$DELAY"
fi

# ------------------------------------------------------------------ 5) 优雅停旧实例
PARENT_PID=""
if [ -n "$OLD_PID" ]; then
  PARENT_PID="$(proc_ppid "$OLD_PID")"
  log "向 PID $OLD_PID 发 SIGTERM（优雅停机：DSH 会先 dispose 整棵树，上限 5s）…"
  kill -TERM "$OLD_PID" 2>/dev/null || warn "kill -TERM $OLD_PID 失败（可能已退出）"

  waited=0
  while port_listening; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      die "等了 ${TIMEOUT}s 端口 $PORT 仍被占用，已放弃启动（旧实例可能没退干净）。手工检查：ss -ltnp 'sport = :$PORT'" 2
    fi
    sleep 1; waited=$((waited + 1))
  done
  log "端口 $PORT 已释放（等了 ${waited}s）。"

  # pnpm 包装进程可能残留（child 退出后通常自己走；没走则补一刀，仍按归属校验）
  if [ -n "$PARENT_PID" ] && [ -d "/proc/$PARENT_PID" ]; then
    sleep 1
    if [ -d "/proc/$PARENT_PID" ]; then
      pcmd="$(proc_cmdline "$PARENT_PID")"; pcwd="$(proc_cwd "$PARENT_PID")"
      case "$pcmd$pcwd" in
        *"pnpm dsh web"*) log "包装进程 PID $PARENT_PID（pnpm）仍在，补发 SIGTERM。"; kill -TERM "$PARENT_PID" 2>/dev/null || true ;;
        *) warn "PID $PARENT_PID 仍在但不是 pnpm 包装进程（cmd=$pcmd），不动它。" ;;
      esac
    fi
  fi
else
  log "端口空闲：没有旧实例需要停。"
fi

# ------------------------------------------------------------------ 6) 拉起新实例
UNIT="dsh-web-$TS"
LOG_HINT="$LOG_DIR/web-${NEW_VER:-未知}.log"
log "用 systemd-run 拉起新实例：unit=$UNIT（这样它的 cgroup 不在 DSH 的 managed range 内）…"
systemd-run --user --unit="$UNIT" --collect \
  --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
  "$RDSH_BIN" start --log "$NEW_DIR" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  die "systemd-run 启动失败。请手工执行：rdsh start $NEW_DIR" 2
fi
log "已提交启动请求（unit=$UNIT）。"

# ------------------------------------------------------------------ 7) 自证：等端口回来
waited=0
while ! port_listening; do
  if [ "$waited" -ge "$TIMEOUT" ]; then
    warn "等了 ${waited}s 端口 $PORT 仍未监听 —— 启动可能失败。"
    warn "看日志：$LOG_HINT"
    warn "看单元：systemctl --user status $UNIT"
    exit 2
  fi
  sleep 1; waited=$((waited + 1))
done
NEW_PID="$(port_pid)"

# ------------------------------------------------- 8) 飞轮兜底（跨进程接手）
# 台账 `$NEW_HOME/wake/<会话>.json` 若在重启后仍未被消费，说明"进程内 wake"没跑成
# （web 进程没起来 / 插件没装载 / 会话被拒）。此时改用官方一发式驱动跨进程接手：
#   dsh --profile headless --session-id <会话> "<唤醒指令>"
# 它会自己取该会话的写租约、跑完、落盘、退出。实测可行（提示缓存命中，成本很低）。
wake_fallback() {
  local dir="${NEW_HOME:-}/wake"
  [ -d "$dir" ] || return 0
  [ "${DSH_RESTART_HEADLESS:-1}" = "1" ] || { log "已禁用飞轮兜底（DSH_RESTART_HEADLESS=0）"; return 0; }
  local pending
  pending="$(ls -1 "$dir"/session-*.json 2>/dev/null | head -1 || true)"
  [ -n "$pending" ] || return 0
  log "台账仍有未消费条目：$(basename "$pending") —— 先等 20s 让进程内 wake 跑"
  sleep 20
  [ -f "$pending" ] || { log "台账已被进程内 wake 消费，兜底不需要动手。"; return 0; }

  local sid prompt ready
  sid="$(basename "$pending" .json)"
  read -r ready prompt < <(python3 - "$pending" <<'PYEOF'
import json,sys,time
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print('0'); raise SystemExit
nb=d.get('notBefore')
due = (nb is None) or (float(nb) <= time.time()*1000)
print(('1' if due else '0'), (d.get('prompt') or '').replace('\n',' '))
PYEOF
)
  if [ "${ready:-0}" != "1" ]; then
    log "台账未到点（notBefore 未到），留给下次启动或进程内定时器。"
    return 0
  fi
  [ -n "${prompt:-}" ] || { warn "台账缺 prompt，放弃兜底。"; return 0; }
  command -v pnpm >/dev/null || { warn "找不到 pnpm，放弃兜底。"; return 0; }

  local unit="dsh-wake-$TS"
  log "用 headless 跨进程接手：session=$sid（unit=$unit）"
  systemd-run --user --unit="$unit" --collect \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=DSH_HOME="${NEW_HOME:-}" \
    --working-directory="$NEW_DIR" \
    "$(command -v pnpm)" dsh --profile headless --session-id "$sid" "$prompt" >/dev/null 2>&1 \
    && log "兜底已投递（日志：journalctl --user -u $unit）" \
    || warn "兜底投递失败；台账保留，可手工执行：cd $NEW_DIR && pnpm dsh --profile headless --session-id $sid \"$prompt\""
}
wake_fallback

log "=============================================================="
log " 重启完成"
log "   新实例 PID : ${NEW_PID:-?}"
log "   新实例 版本: ${NEW_VER:-?}"
log "   数据目录   : ${NEW_HOME:-?}"
log "   systemd 单元: $UNIT"
log "   启动日志   : $LOG_HINT"
log "   浏览器     : http://127.0.0.1:$PORT/ （持久 cookie 仍有效，刷新即可）"
log "=============================================================="
exit 0
