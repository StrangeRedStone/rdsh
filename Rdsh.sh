#!/bin/bash
# =============================================================================
# rdsh —— dsh 多版本命令包（启动 + 管理 · v4）
#
# 目录布局（根由单一旋钮 BASE 决定，默认 $HOME/Mapp；`rdsh base $HOME` 可改成 ~/dsh + ~/.dsh）：
#   基目录   : $BASE                            （环境 RDSH_BASE / 配置 ~/.config/rdsh/config 可覆盖）
#   代码检出 : $BASE/dsh/<检出目录>/            （本脚本同目录，自动扫描子目录）
#   数据根   : $BASE/.dsh/<版本号>/             （每版本独立 DSH_HOME；版本号取 package.json）
#   作者资产根: $BASE/.dsh-shared/              （与版本无关的 skills/lessons.md/AGENTS.md/.agent-presets/
#                                               facts.md/backlog.md；各版本 home 内以软链共享，不复制）
#   备份根   : $BASE/.dsh-backup/               （rdsh backup / migrate.sh 的落点）
#   启动日志 : $BASE/.dsh-logs/                 （含访问 token，目录 700 / 文件 600）
#   实例注册表: $BASE/.dsh-suite/run/           （instances/<端口>.kv；只是注解，真相是 ss + /proc）
#   映射文件 : $BASE/dsh/.map                   （可选，可手改）
#       行格式 dir|<检出目录名>|<数据目录>     —— 该检出的数据目录改指（如未迁移的 rc.2）
#               ext|<绝对路径>|<数据目录>      —— 登记一个"本体不动、仅数据隔离"的外部检出
#   相关工具 : migrate.sh（同目录）             —— 跨版本迁移器：备份 + 建链 + 探针 + 回退基线
#              reindex-workspaces.sh（同目录） —— 重建工作区归属（手拷会话后显示「未分组」时用）
#
# 用法（首个参数为子命令；不写 = run）：
#   rdsh                                  # 启动：列表菜单（回车=默认[最新]；可一次给多个，空格分隔）
#   rdsh run [版本|序号|项目名|路径]...    # 启动 1..N 个实例。默认**后台化**（systemd 用户单元，
#                                         #   关终端也不死），端口默认**递增**（在跑的最大端口 +1）
#       --port N                          #   指定起始端口（多个目标按 --step 递增）
#       --step N（默认1）--timeout N（默认90，等端口就绪）
#       --foreground                      #   占着终端跑（老行为；rdsh-restart.sh 用这条）
#       --no-open | --open                #   是否自动开浏览器（多目标时默认不开）
#       --dry-run                         #   只打印计划；--no-log 关启动日志
#                                         #   同一 DSH_HOME 已在跑 → 拒绝（多开会互相写 workspace）
#   rdsh start ...                        # 同 run（兼容别名，rdsh-restart.sh 仍可用）
#   rdsh add <检出路径> [--mode iso|link|body]
#                                         # 手动把检出纳入管理；同 run <新路径> 的询问
#   rdsh list                             # 列版本（序号/检出状态/数据目录）
#   rdsh status                           # 运行实例（全部端口）+ 数据总览
#   rdsh stop [目标|端口]                 # 停实例：默认停"端口最大的那一个"（后进先出）
#       --port N | --all                  #   指定端口 / 从最大端口往小全停
#       --dry-run                         #   只打印会杀谁（含 cwd/cmd 证据），不发信号
#       --timeout N（默认30）--delay N（默认3，自杀式停止的缓冲）--force（确认自杀）
#       --probe                           #   照常投递到 systemd 单元，但单元里只走到
#                                         #   "该杀谁"为止：不发信号（验证逃生链路用）
#                                         #   红线：目标过不了归属校验就绝不碰；绝不用 -9
#                                         #   在 dsh 内停"自己所在的实例"时会自动投递到一次性
#                                         #   systemd 单元，本命令立即返回，延迟后由单元执行
#   rdsh install [版本|序号|项目名|路径]   # pnpm install + build + 打标
#   rdsh debug new <版本> [--tag 名]      # 建"干净环境"：全新空 DSH_HOME（不播种、不链任何东西）
#       --assets | --creds | --copy-creds  #   按调试目的单独加料（作者资产 / 凭据）
#       --port N | --start | --dry-run
#   rdsh debug start|stop <id>            # 启/停某个调试环境（同版本多开的正路）
#   rdsh debug ls                         # 列调试环境（端口/在跑否/链了什么/大小/创建时间）
#   rdsh debug add|detach <id> ...        # 事后补加 / 摘掉（摘只挪软链，真身不动）
#   rdsh debug rm <id|--all|--older-than 7d>
#                                         # 删：先停实例 → 整体挪进回收目录（**永不 rm**），
#                                         #   并打印还原命令；只认 $BASE/.dsh-suite/debug/ 下的
#   rdsh debug env <id>                   # 打印可 eval 的 DSH_HOME/cd（排障用）
#   rdsh exec <版本|debug-id> -- <命令>    # 在指定环境里跑一次性命令
#   rdsh data [-o] [版本|序号|项目名|路径] # 显示 / 打开数据目录
#   rdsh backup [版本|序号]               # 备份数据目录到 $BASE/.dsh-backup/
#   rdsh logs [-f] [版本|序号] [-o]       # 查看/打开启动日志（--clean 清理旧日志）
#   rdsh base [路径] [--unset]            # 查看/设置基目录（只改 rdsh 的指向，不搬动任何数据）
#   rdsh patch list|status|apply|revert|export  # 检出补丁管理（转发 patch-manager.sh）
#                                         #   apply/revert 会改检出：默认要 --yes，支持 --dry-run
#   rdsh fetch --list [--refresh]         # 列远端可用版本（GitHub API 列举 + 10 分钟缓存；失败回退 git ls-remote）
#   rdsh fetch <版本> [--dir <名>] [--tarball] [--full] [--install] [--dry-run]
#                                         # 拉取指定版本检出到 $BASE/dsh/（默认 git clone --depth 1，与官方源码装法一致，
#                                         #   后续 rdsh patch export / 上游 diff 可用；--tarball 改走归档：更小更稳但无 .git）
#   rdsh help
#
# 选择目标：序号 | 版本号片段(rc.2) | 项目名片段(harness) | 检出目录名 | 完整路径。
# 输入只认可打印字符，控制键/转义序列会被剔除，不会干扰匹配。
#
# 用新路径启动"未纳入管理"的检出时，会询问隔离方式：
#   1) 全面隔离(推荐)：项目移入 $HOME/Mapp/dsh/，数据放 $HOME/Mapp/.dsh/<版本>/
#   2) 仅数据隔离    ：项目本体不动，数据放 $HOME/Mapp/.dsh/<版本>/
#   3) 本体移动，数据不动：项目移入 $HOME/Mapp/dsh/，数据继续用旧位置(默认 ~/.dsh)
# 非交互环境默认选 2（最少改动），并打印登记结果。
# =============================================================================
set -euo pipefail

# ---------------- 根目录解析：单一旋钮 BASE（可被环境变量/配置文件覆盖） ----------------
# 优先级：环境变量 > 配置文件 > 默认。
# 配置文件（默认 ~/.config/rdsh/config，可用 RDSH_CONFIG 指定）——纯 KEY=VALUE，**不 source**：
#     BASE=$HOME/Mapp                # 唯一旋钮：$BASE/dsh 放检出、$BASE/.dsh 放数据
#     # 需要时可逐项覆盖：MANAGE_ROOT= / DATA_ROOT= / BACKUP_ROOT= / SHARED_ROOT= / LOG_DIR=
# 例：BASE=$HOME → 检出在 ~/dsh、数据在 ~/.dsh、备份在 ~/.dsh-backup
RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"
cfg_get() {  # <KEY> → 配置文件里的值（去引号、展开 ~）；没有则空
  [ -f "$RDSH_CONFIG" ] || return 0
  local v
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}
expand() {  # 展开开头的 ~
  case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac
}

BASE="$(expand "${RDSH_BASE:-$(cfg_get BASE)}")"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
_manage="$(expand "${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}")"
_data="$(expand "${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}")"
_backup="$(expand "${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}")"
_shared="$(expand "${RDSH_SHARED_HOME:-$(cfg_get SHARED_ROOT)}")"
_logdir="$(expand "${DSH_LOG_DIR:-$(cfg_get LOG_DIR)}")"
_run="$(expand "${RDSH_RUN_DIR:-$(cfg_get RUN_DIR)}")"
_dbg="$(expand "${RDSH_DEBUG_ROOT:-$(cfg_get DEBUG_ROOT)}")"

MANAGE_ROOT="${_manage:-$BASE/dsh}"
# 可移植性回退：未显式配置 MANAGE_ROOT，且 $BASE/dsh 不是本工具所在处时，改用脚本自身目录。
# 这样 `git clone` 到任意目录后可直接跑；有既定布局（$BASE/dsh 里有 Rdsh.sh）时行为不变。
if [ -z "$_manage" ] && [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
  _self_dir="$(dirname "$(readlink -f "$0")")"
  if [ -f "$_self_dir/Rdsh.sh" ]; then MANAGE_ROOT="$_self_dir"; fi
fi
DATA_ROOT="${_data:-$BASE/.dsh}"
BACKUP_ROOT="${_backup:-$BASE/.dsh-backup}"
SHARED_ROOT="${_shared:-$BASE/.dsh-shared}"
MAP_FILE="$MANAGE_ROOT/.map"
LEGACY_HOME="$HOME/.dsh"                 # 旧单根布局：bootstrap 模板 + 模式3的默认数据位置
WEB_LOG="${DSH_WEB_LOG:-1}"               # 1=dsh web 控制台输出同时落盘（事后可查插件/监听器报错）；0=关闭
LOG_DIR="${_logdir:-$BASE/.dsh-logs}"     # 启动日志目录（内含访问 token，故目录 700 / 文件 600）
RUN_DIR="${_run:-$BASE/.dsh-suite/run}"   # 实例注册表（注解层；真相仍是 ss + /proc）
INSTANCES_DIR="$RUN_DIR/instances"        # 每实例一份 <端口>.kv
WEB_PORT="${DSH_WEB_PORT:-3080}"          # 默认监听端口；run/start 的 --port 可覆写
STOP_TIMEOUT="${DSH_STOP_TIMEOUT:-30}"    # rdsh stop 等端口释放的上限秒数
STOP_DELAY="${DSH_STOP_DELAY:-3}"         # 自杀式停止时留给调用方落盘的秒数
LAUNCH_TIMEOUT="${DSH_LAUNCH_TIMEOUT:-90}" # 后台启动后等端口就绪的上限秒数
NO_OPEN="${DSH_NO_OPEN:-0}"               # 1=不给 dsh 传 --no-open 的反面：1 表示传 --no-open（不开浏览器）
DEBUG_ROOT="${_dbg:-$BASE/.dsh-suite/debug}" # 调试环境根：<id>.env 清单 + <id>/ 就是干净 DSH_HOME
# 调用期覆盖（由 --debug <id> 设置）：让 launch_* 用调试环境的 home / 登记 kind=debug
ENTRY_HOME_OVERRIDE=""
INSTANCE_KIND="real"
INSTANCE_ID=""
DEBUG_MODE=0
AUTO_INSTALL="${RDSH_AUTO_INSTALL:-1}"    # 1=启动时检出缺依赖自动安装；0=只提示
REMOTE_URL="${RDSH_REMOTE:-https://github.com/deepseek-ai/deepseek-harness.git}"
TAG_PREFIX="${RDSH_TAG_PREFIX:-dsh-v}"    # 远端 tag 命名：dsh-v<版本>

log()  { printf '\033[1;34m[rdsh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rdsh!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[rdsh!]\033[0m %s\n' "$*" >&2; exit 1; }
has_tty() { [ -t 0 ] || [ "${DSH_MENU:-0}" = "1" ]; }
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"   # 自杀式停止时要把自己投递到 systemd 单元

read_version() {  # 检出根 -> 版本号（package.json 优先，否则用目录名）
  local dir="$1" v=""
  if [ -f "$dir/package.json" ]; then
    v=$(grep -m1 '"version"' "$dir/package.json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
  fi
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$dir")"
}

# ---------------- 映射文件 .map：dir|名称|数据 / ext|路径|数据 ----------------
MAP_DIRS=()    # 名称|数据
MAP_EXTS=()    # 路径|数据
load_map() {
  MAP_DIRS=(); MAP_EXTS=()
  [ -f "$MAP_FILE" ] || return 0
  local line kind k v
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS='|' read -r kind k v <<<"$line"
    case "$kind" in
      dir ) MAP_DIRS+=("$k|${v:-}") ;;
      ext ) [ -d "$k" ] && MAP_EXTS+=("$k|${v:-}") ;;
    esac
  done < "$MAP_FILE"
}
add_map_line() {  # <完整行>
  printf '%s\n' "$1" >> "$MAP_FILE"
}

data_home_for_name() {  # 检出目录名 -> 数据目录（.map 优先，其次 DATA_ROOT/<版本>）
  local base="$1" ver="$2" row k v fb
  fb=$(printf '%s/%s' "$DATA_ROOT" "$ver")
  for row in "${MAP_DIRS[@]:-}"; do
    IFS='|' read -r k v <<<"$row"
    [ "$k" = "$base" ] || continue
    if [ -z "$v" ]; then printf '%s' "$fb"; return; fi
    if [ -d "$v" ]; then printf '%s' "$v"; return; fi
    # 映射目标已不存在（如 ~/.dsh 已迁移）→ 新布局有数据就自动切换
    if [ -d "$fb" ]; then
      warn "数据已迁移：$v 不存在，改用新布局 $fb（可删 .map 中该行）" >&2
      printf '%s' "$fb"; return
    fi
    printf '%s' "$v"; return   # 都不在 → 由 ensure_data_home 明确报错
  done
  printf '%s' "$fb"
}

# ---------------- 条目：version | dir | base | data ----------------
ENTRIES=()
collect_entries() {
  ENTRIES=()
  local d base ver data
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    base=$(basename "${d%/}")
    [ "$base" = "Rdsh.sh" ] && continue
    [ "$base" = ".map" ] && continue
    # 只认真正像 dsh 检出的目录：根须有 package.json。
    # 否则本工具自带的 docs/ examples/ 等目录会被误列成"版本"。
    [ -f "$d/package.json" ] || continue
    ver=$(read_version "${d%/}")
    data=$(data_home_for_name "$base" "$ver")
    ENTRIES+=("$ver|${d%/}|$base|$data")
  done
  local row path v data def
  for row in "${MAP_EXTS[@]:-}"; do
    [ -n "$row" ] || continue
    IFS='|' read -r path v <<<"$row"
    [ -d "$path" ] || continue
    ver=$(read_version "$path")
    [ -n "$v" ] && data="$v" || data=$(printf '%s/%s' "$DATA_ROOT" "$ver")
    ENTRIES+=("$ver|${path%/}|$(basename "$path")|$data")
  done
  [ "${#ENTRIES[@]}" -gt 0 ] || die "未找到任何 dsh 检出（$MANAGE_ROOT 下无版本目录，也无 .map 外部登记）"
}

sort_entries() {  # 按版本语义倒序，最新在前（序号 1 = 默认）
  local -a tmp=()
  local e line v
  for e in "${ENTRIES[@]}"; do v="${e%%|*}"; tmp+=("$v|$e"); done
  mapfile -t tmp < <(printf '%s\n' "${tmp[@]}" | sort -Vr)
  ENTRIES=()
  for line in "${tmp[@]}"; do ENTRIES+=("${line#*|}"); done
}

entry_field() {  # <entry> <1..4> = version|dir|base|data
  local e="$1" n="$2"
  IFS='|' read -r f1 f2 f3 f4 <<<"$e"
  case "$n" in 1) printf '%s' "$f1";; 2) printf '%s' "$f2";; 3) printf '%s' "$f3";; 4) printf '%s' "$f4";; esac
}

built_status() {
  local dir="$1"
  if [ -d "$dir/node_modules" ] && [ -f "$dir/.installed" ]; then echo '就绪'
  elif [ -d "$dir/node_modules" ]; then echo '缺.installed'
  elif [ -f "$dir/.installed" ]; then echo '缺node_modules'
  else echo '未安装'; fi
}
data_state() {
  local d="$1"
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then echo '有数据'; else echo '空(首启自动初始化)'; fi
}

list_entries() {
  local i=1 e ver dir base data
  printf '\n可用 dsh 版本：\n'
  for e in "${ENTRIES[@]}"; do
    ver=$(entry_field "$e" 1); dir=$(entry_field "$e" 2); base=$(entry_field "$e" 3); data=$(entry_field "$e" 4)
    printf '  [%d] %-14s %-12s  检出: %s\n' "$i" "$ver" "$(built_status "$dir")" "$base"
    printf '       数据: %s (%s)\n' "$data" "$(data_state "$data")"
    i=$((i+1))
  done
}

pick_default() { printf '%s\n' "${ENTRIES[0]}"; }

# 只保留安全的可打印字符：字母数字 + 空白 + 常见路径/名称符号，
# 其余(控制键、转义序列、箭头残片、括号等)一律剔除。
clean_input() {
  printf '%s' "$1" \
    | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b[()][0-9A-Za-z]//g' -e 's/\x1b[=>]//g' \
    | tr -cd '[:alnum:] /._~+@#-'
}

resolve_match() {  # 版本号/项目名/目录名 的片段匹配（不含路径、不含序号）
  local arg="$1" found="" e ver dir base
  for e in "${ENTRIES[@]}"; do
    ver=$(entry_field "$e" 1); base=$(entry_field "$e" 3)
    if [[ "$ver" == *"$arg"* ]] || [[ "$base" == *"$arg"* ]]; then
      [ -n "$found" ] && die "“$arg” 匹配到多个版本，请输入序号或用 list 看全名"
      found="$e"
    fi
  done
  [ -n "$found" ] || die "未找到匹配 “$arg” 的版本/项目。可用：$(for e in "${ENTRIES[@]}"; do printf '%s ' "$(entry_field "$e" 1)"; done)（或给出完整检出路径）"
  printf '%s\n' "$found"
}

resolve_index() {  # 序号 -> 条目
  local n="$1" i=1 e
  for e in "${ENTRIES[@]}"; do
    [ "$i" = "$n" ] && { printf '%s\n' "$e"; return; }
    i=$((i+1))
  done
  die "序号 $n 超出范围（共 ${#ENTRIES[@]} 个）"
}

entry_by_dir() {  # 已管理检出（目录）-> 条目；不在管理内输出空
  local want="$1" e dir
  want=$(readlink -f "$want")
  for e in "${ENTRIES[@]}"; do
    dir=$(readlink -f "$(entry_field "$e" 2)")
    [ "$dir" = "$want" ] && { printf '%s\n' "$e"; return; }
  done
}

resolve_target() {  # 目标串 -> 条目。路径若指向未管理的检出则交给调用方做"纳入询问"
  local arg="$1"
  [ -z "$arg" ] && { pick_default; return; }
  [[ "$arg" == ~* ]] && arg="${arg/#\~/$HOME}"
  if [[ "$arg" =~ ^[0-9]+$ ]]; then resolve_index "$arg"; return; fi
  if [ -d "$arg" ] && [ -f "$arg/package.json" ]; then
    local e; e=$(entry_by_dir "$arg")
    [ -n "$e" ] && printf '%s\n' "$e" || printf 'UNMANAGED:%s\n' "$(readlink -f "$arg")"
    return
  fi
  resolve_match "$arg"
}

# ---- 端口与实例：真相层（ss + /proc） ----
# 端口不再硬编码：默认 $WEB_PORT，`--port N` 覆写。所有读写都用"端口"作参数。
port_listening() {  # [端口] → 0/1
  local p="${1:-$WEB_PORT}"
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH "sport = :$p" 2>/dev/null | grep -q .
}
port_busy() { port_listening "${1:-$WEB_PORT}"; }

port_pid() {  # [端口] → owner PID（查不到输出空）；恒返回 0
  local p="${1:-$WEB_PORT}"
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnpH "sport = :$p" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
  return 0
}

listening_ports() {  # 本机所有监听端口（升序去重）
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnpH 2>/dev/null | awk '{p=$4; sub(/.*:/,"",p); if (p ~ /^[0-9]+$/) print p}' | sort -un
}

port_free_from() {  # <起始端口> → 从它起第一个空闲端口
  local p="${1:-$WEB_PORT}"
  while port_listening "$p"; do p=$((p+1)); done
  printf '%s' "$p"
}

proc_cwd()     { readlink "/proc/$1/cwd" 2>/dev/null || true; }
proc_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true; }
proc_home() {  # 从进程环境取 DSH_HOME（未显式设置则输出空，由调用方按默认处理）
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -nE 's/^DSH_HOME=(.*)$/\1/p' | head -1 || true
}
cgroup_unit() {  # 本进程所在"我们自己的" systemd 用户单元名（无则空）—— 只认 dsh-web-* / rdsh-dbg-*
  grep -oE '(dsh-web|rdsh-dbg)-[A-Za-z0-9_.@-]+\.service' /proc/self/cgroup 2>/dev/null | head -1 || true
}

# 归属校验：只承认"我们的 dsh web"——命令行必须是 web 入口，且 cwd 是已管理检出
# 或名字像 dsh 检出（兼容未登记的旧实例）。家规：禁用 pkill/pgrep -f；
# 任何信号/停止动作都必须先过这一关。
is_dsh_web_pid() {  # <pid> → 0/1
  local pid="$1" cwd cmd
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
  cwd="$(proc_cwd "$pid")"
  [ -n "$cwd" ] || return 1
  cmd="$(proc_cmdline "$pid")"
  case "$cmd" in *"bin.ts web"*|*"dsh web"*) ;; *) return 1 ;; esac
  [ -n "$(entry_by_dir "$cwd")" ] && return 0
  case "$(basename "$cwd")" in *deepseek-harness*) return 0 ;; esac
  return 1
}
port_owner_cwd() {  # [端口] → 该端口上 dsh 实例的工作目录（若有）；恒返回 0
  local p pid; pid="$(port_pid "${1:-$WEB_PORT}")"
  [ -n "$pid" ] && proc_cwd "$pid"
  return 0
}

# ---- 实例注册表：注解层（$RUN_DIR/instances/<端口>.kv） ----
# 真相永远是 ss + /proc；注册表只补 ss 查不到的字段：kind(real|debug)、debug id、
# systemd 单元名、启动日志、启动时间。注册表缺失/过期都不影响识别（过期条目自动退休）。
registry_ports() {  # 注册表里登记过的端口
  [ -d "$INSTANCES_DIR" ] || return 0
  local f
  for f in "$INSTANCES_DIR"/*.kv; do
    [ -f "$f" ] || continue
    basename "$f" .kv
  done
}
registry_get() {  # <端口> <键> → 值（无则空）
  local f="$INSTANCES_DIR/$1.kv"
  [ -f "$f" ] || return 0
  sed -nE "s/^$2=(.*)$/\1/p" "$f" | tail -1
}
registry_put() {  # <端口> <pid> <版本> <检出> <DSH_HOME> <kind> <id> <unit> <日志> [时间]
  local p="$1" f="$INSTANCES_DIR/$1.kv" tmp
  mkdir -p "$INSTANCES_DIR"; chmod 700 "$RUN_DIR" "$INSTANCES_DIR" 2>/dev/null || true
  tmp="$f.tmp.$$"
  { printf 'port=%s\n'    "$1"
    printf 'pid=%s\n'     "$2"
    printf 'ver=%s\n'     "$3"
    printf 'dir=%s\n'     "$4"
    printf 'data=%s\n'    "$5"
    printf 'kind=%s\n'    "${6:-real}"
    printf 'id=%s\n'      "${7:-}"
    printf 'unit=%s\n'    "${8:-}"
    printf 'log=%s\n'     "${9:-}"
    printf 'started=%s\n' "${10:-$(date -Is)}"
  } > "$tmp"
  mv -f "$tmp" "$f"
}
registry_retire() {  # <端口>：把注册表里的死条目挪到 stale/（永不 rm）
  local p="$1" f="$INSTANCES_DIR/$1.kv"
  [ -f "$f" ] || return 0
  mkdir -p "$RUN_DIR/stale"
  mv "$f" "$RUN_DIR/stale/$p-$(date +%s).kv" 2>/dev/null || true
}

# 活实例 = 真相 ∪ 注解。每行：port|pid|ver|dir|data|kind|id|unit|started
instances_live() {
  local p pid dir data ver kind id unit started f seen=""
  for p in $(listening_ports); do
    pid="$(port_pid "$p")"
    [ -n "$pid" ] || continue
    is_dsh_web_pid "$pid" || continue
    dir="$(proc_cwd "$pid")"; data="$(proc_home "$pid")"
    ver="$(read_version "${dir:-/nonexistent}")"
    kind="$(registry_get "$p" kind)"; [ -n "$kind" ] || kind=real
    id="$(registry_get "$p" id)"
    unit="$(registry_get "$p" unit)"
    started="$(registry_get "$p" started)"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$p" "$pid" "$ver" "$dir" "$data" "$kind" "$id" "$unit" "$started"
    seen="$seen $p"
  done
  # 注册表有、但端口上已不在跑 → 退休（annotation 清理，不 rm）
  for f in $(registry_ports); do
    case " $seen " in *" $f "*) continue ;; esac
    registry_retire "$f"
  done
}

# ---- stop：优雅停止实例（归属校验 + 自杀防护） ----
# 家规：绝不用 pkill/pgrep -f；只对"过得了 is_dsh_web_pid"的进程动手，且绝不强杀（-9）。
proc_ppid() { awk '{print $4}' "/proc/$1/stat" 2>/dev/null || true; }

ancestor_chain_has() {  # <pid> → 0/1：本进程($$)的祖先链里是否有它（自杀检测）
  local want="$1" p=$$ guard=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$guard" -lt 64 ]; do
    [ "$p" = "$want" ] && return 0
    p="$(proc_ppid "$p")"
    guard=$((guard+1))
  done
  return 1
}

instance_matches() {  # <目标串> <端口> <版本> <检出> <debug id> → 0/1；纯数字只当端口
  local arg="$1" p="$2" ver="$3" dir="$4" id="$5" base
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    [ "$p" = "$arg" ] && return 0
    return 1
  fi
  [ -n "$id" ] && [ "$arg" = "$id" ] && { return 0; }
  case "$ver" in *"$arg"*) return 0 ;; esac
  base="$(basename "$dir")"
  case "$base" in *"$arg"*) return 0 ;; esac
  if [ -d "$arg" ] && [ "$(readlink -f "$arg")" = "$(readlink -f "$dir")" ]; then return 0; fi
  return 1
}

stop_one() {  # <端口> <pid> <版本> <检出> <kind> <id> <unit> <超时> → 0 成功 / 1 未确认
  local p="$1" pid="$2" ver="$3" dir="$4" kind="$5" id="$6" unit="$7" tmo="$8"
  local ppid waited=0 pcmd pcwd
  if ! is_dsh_web_pid "$pid"; then
    warn "端口 $p：PID $pid 不是 dsh web（cwd=$(proc_cwd "$pid")；cmd=$(proc_cmdline "$pid")）→ 拒绝动它"
    return 1
  fi
  ppid="$(proc_ppid "$pid")"
  if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    log "端口 $p：systemctl --user stop $unit（整 cgroup 优雅停机）"
    timeout "$tmo" systemctl --user stop "$unit" >/dev/null 2>&1 \
      || warn "systemctl stop $unit 超时或返回非零（继续等端口释放）"
  else
    log "端口 $p：向 PID $pid 发 SIGTERM（未托管实例，优雅停机）"
    kill -TERM "$pid" 2>/dev/null || warn "kill -TERM $pid 失败（可能已退出）"
  fi
  while port_listening "$p"; do
    if [ "$waited" -ge "$tmo" ]; then
      warn "等了 ${tmo}s 端口 $p 仍被占用 → 未强杀。请手工检查：ss -ltnp 'sport = :$p'"
      return 1
    fi
    sleep 1; waited=$((waited+1))
  done
  log "端口 $p 已释放（等了 ${waited}s）"
  # pnpm 包装进程可能残留（子进程退出后通常会自己走）；只在归属匹配时补一刀
  if [ -n "$ppid" ] && [ -d "/proc/$ppid" ]; then
    sleep 1
    if [ -d "/proc/$ppid" ]; then
      pcmd="$(proc_cmdline "$ppid")"; pcwd="$(proc_cwd "$ppid")"
      case "$pcmd$pcwd" in
        *"pnpm dsh web"*) log "包装进程 PID $ppid（pnpm）仍在，补发 SIGTERM"; kill -TERM "$ppid" 2>/dev/null || true ;;
        *) : ;;
      esac
    fi
  fi
  return 0
}

detach_stop() {  # <日志> <超时> <延迟> <原始参数...>：把自己投递到一次性 systemd 单元，stdout 输出单元名
  local logf="$1" tmo="$2" delay="$3"; shift 3
  command -v systemd-run >/dev/null 2>&1 \
    || die '没有 systemd-run，无法脱离 dsh 进程树安全执行自杀式停止。请在 dsh 外的终端里运行本命令。'
  mkdir -p "$(dirname "$logf")"; ( umask 077; : > "$logf" )
  local unitname="rdsh-stop-$(date +%Y%m%d-%H%M%S)"
  local args=(--user --unit="$unitname" --collect
              --setenv=PATH="$PATH" --setenv=HOME="$HOME"
              --setenv=DSH_STOP_DETACHED=1 --setenv=DSH_STOP_LOG="$logf")
  # systemd 不继承自定义环境变量（实测）：显式转发 RDSH_*/DSH_* 覆盖项
  local v
  for v in RDSH_BASE RDSH_CONFIG RDSH_MANAGE_ROOT RDSH_DATA_ROOT RDSH_BACKUP_ROOT \
           RDSH_SHARED_HOME RDSH_RUN_DIR DSH_LOG_DIR DSH_WEB_PORT DSH_WEB_LOG; do
    [ -n "${!v:-}" ] && args+=(--setenv="$v=${!v}")
  done
  systemd-run "${args[@]}" "$SELF" stop "$@" --timeout "$tmo" --delay "$delay" --force >/dev/null 2>&1 \
    || die '投递到 systemd 失败（systemd-run --user 不可用？）'
  printf '%s' "$unitname"
}

# ---- 作者资产：稳定根 + 软链 -------------------------------------------------
# 作者资产 = 与 DSH 版本无关、由用户或 agent 读写的东西；复制会在多版本间分叉。
# 注意 settings.yaml 不在此列：它随版本 schema 变，仍各留本 home。
AUTHOR_ASSETS=(skills lessons.md AGENTS.md .agent-presets facts.md backlog.md)

seed_shared_root() {  # 一次性播种：把 <home> 里的真文件搬进稳定根（只搬稳定根缺的）
  local donor="$1" n
  for n in "${AUTHOR_ASSETS[@]}"; do
    [ -e "$SHARED_ROOT/$n" ] && continue
    [ -e "$donor/$n" ] || continue
    mv "$donor/$n" "$SHARED_ROOT/$n"
    log "  稳定根 <- $donor/$n"
  done
}

# <数据目录>：缺则建链；home 里有真文件则迁入稳定根后建链；两边都有只警告不动（原则 P1）
link_author_assets() {
  local data="$1" n
  for n in "${AUTHOR_ASSETS[@]}"; do
    if [ -L "$data/$n" ]; then
      continue                                   # 已是软链 → 幂等
    elif [ -e "$data/$n" ]; then
      if [ -e "$SHARED_ROOT/$n" ]; then
        warn "$n：home 与稳定根各有一份，未动（请人工决定保留哪份）"
        continue
      fi
      mv "$data/$n" "$SHARED_ROOT/$n"
      ln -s "$SHARED_ROOT/$n" "$data/$n"
      log "  $n：已迁入稳定根并建链"
    elif [ -e "$SHARED_ROOT/$n" ]; then
      ln -s "$SHARED_ROOT/$n" "$data/$n"
      log "  $n：建链"
    fi
  done
}

ensure_data_home() {
  local data="$1"
  # 调试环境：只建目录，**不播种、不建链** —— "默认全新"就落在这一支上。
  # 想加作者资产/凭据走 `rdsh debug add <id> --assets|--creds`（显式、可撤销）。
  if [ "$DEBUG_MODE" = "1" ]; then
    [ -d "$data" ] || { log "创建调试数据目录: $data"; mkdir -p "$data"; chmod 700 "$data"; }
    export DSH_HOME="$data"
    log "DSH_HOME=$DSH_HOME（调试环境：不播种、不建链）"
    return 0
  fi
  if [ "$data" = "$LEGACY_HOME" ]; then
    [ -d "$data" ] || die "数据目录 $data 不存在——疑似 ~/.dsh 已被移动。请先把它迁回，或改 .map 中对应行。"
    return
  fi
  if [ ! -d "$data" ]; then
    log "创建数据目录: $data"
    mkdir -p "$data"; chmod 700 "$data"
  fi
  mkdir -p "$SHARED_ROOT"
  # 首次使用：稳定根为空时，从旧数据根或本 home 的真文件播种（之后各版本只建链，不复制）
  if [ -z "$(ls -A "$SHARED_ROOT" 2>/dev/null)" ]; then
    [ -d "$LEGACY_HOME" ] && seed_shared_root "$LEGACY_HOME"
    seed_shared_root "$data"
  fi
  # settings.yaml 随版本 schema 变，仍从旧数据根复制进本 home（仅在 home 为空时）
  if [ -z "$(ls -A "$data" 2>/dev/null)" ] && [ -f "$LEGACY_HOME/settings.yaml" ]; then
    cp "$LEGACY_HOME/settings.yaml" "$data/"; log '  + settings.yaml（版本相关，留本 home）'
  fi
  link_author_assets "$data"
  export DSH_HOME="$data"
  log "DSH_HOME=$DSH_HOME"
  log "作者资产根: $SHARED_ROOT（skills/lessons.md/AGENTS.md/.agent-presets 均为软链）"
}

ensure_built() {
  local dir="$1"
  if [ -d "$dir/node_modules" ] && [ -f "$dir/.installed" ]; then
    log '检出已就绪(node_modules + .installed)，跳过安装'
    return
  fi
  if [ "$AUTO_INSTALL" != "1" ]; then
    warn "检出缺依赖：请先运行 rdsh install $(basename "$dir")"
    return
  fi
  log "检出缺依赖，自动安装: $dir"
  cd "$dir" || die "无法进入 $dir"
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    git init >/dev/null; git add . >/dev/null; git commit -qm "Auto-init for build" || true
  fi
  command -v pnpm >/dev/null || die '未找到 pnpm'
  log 'pnpm install ...（依赖较大，请耐心等待）'
  pnpm install || die 'pnpm install 失败'
  log 'pnpm run build ...（较慢，请耐心等待）'
  pnpm run build || die 'pnpm run build 失败'
  touch "$dir/.installed"
  log '安装完成(.installed)'
}

launch_entry() {
  local entry="$1" dry="$2" port="${3:-$WEB_PORT}" ver dir data
  ver=$(entry_field "$entry" 1); dir=$(entry_field "$entry" 2)
  data="${ENTRY_HOME_OVERRIDE:-$(entry_field "$entry" 4)}"
  log "启动版本: $ver"
  log "检出目录: $dir"
  log "监听端口: $port"
  if [ "$dry" = "1" ]; then echo "DSH_HOME  : $data"; return 0; fi
  if port_busy "$port"; then
    local owner; owner=$(port_owner_cwd "$port")
    die "127.0.0.1:$port 已被占用（运行中检出：${owner:-未知}）。请先停掉旧实例，或用 --port 换端口。"
  fi
  ensure_data_home "$data"
  ensure_built "$dir"
  cd "$dir" || die "无法进入 $dir"
  command -v pnpm >/dev/null || die '未找到 pnpm'
  # 启动输出同时落盘：事后可检索插件/技能监听器的报错（此前这类报错只在终端里，无法复查）
  local logfile="$LOG_DIR/web-$ver-$port.log"
  if [ "$WEB_LOG" = "1" ]; then
    mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR" 2>/dev/null || true
    ( umask 077; [ -f "$logfile" ] || : > "$logfile" )   # 文件权限 600（含访问 token）
    log "启动日志: $logfile（含访问 token，勿外传；rdsh run --no-log 可关）"
    exec > >(tee -a "$logfile") 2>&1
  fi
  # 登记注解：PID 未知（马上就 exec 了），ss 会补上；这里主要记单元名与日志路径，
  # 让 status/stop 知道"这个实例是被 systemd 托管的"（停它可以整 cgroup 优雅收掉）。
  registry_put "$port" "" "$ver" "$dir" "$data" "$INSTANCE_KIND" "$INSTANCE_ID" "$(cgroup_unit)" "$logfile"
  log '启动 dsh web（Ctrl+C 退出）...'
  local webflags=(--port "$port")
  [ "$NO_OPEN" = "1" ] && webflags+=(--no-open)
  exec pnpm dsh web "${webflags[@]}"
}

# 纳入管理询问（模式）：1=全面隔离 2=仅数据隔离 3=本体移动数据不动；默认 1
adopt_prompt() {
  local path="$1" ver mode=""
  ver=$(read_version "$path")
  printf '\n检测到新检出（未纳入管理）：\n' >&2
  printf '  路径 : %s\n  版本 : %s\n' "$path" "$ver" >&2
  printf '  数据目录将隔离到 %s/%s\n\n' "$DATA_ROOT" "$ver" >&2
  printf '请选择隔离方式：\n' >&2
  printf '  1) 全面隔离(推荐)：项目移入 %s，数据隔离到 %s/%s\n' "$MANAGE_ROOT" "$DATA_ROOT" "$ver" >&2
  printf '  2) 仅数据隔离    ：项目本体不动，只把数据隔离\n' >&2
  printf '  3) 本体移动，数据不动：项目移入 %s，数据继续用旧位置\n' "$MANAGE_ROOT" >&2
  printf '  回车=1，q=取消> ' >&2
  local sel=""
  read -r sel || true
  sel=$(clean_input "$sel")
  case "$sel" in
    ""|1) mode=iso ;;
    2) mode=link ;;
    3) mode=body ;;
    q|Q) die '已取消' ;;
    *) warn "无效输入“$sel”，默认全面隔离" >&2; mode=iso ;;
  esac
  printf '%s' "$mode"
}

# 把一个未管理检出纳入管理；输出最终条目（stdout 纯净；日志走 stderr）
adopt_and_entry() {
  local path="$1" mode="$2" ver base dest entry data
  ver=$(read_version "$path"); base=$(basename "$path"); dest="$MANAGE_ROOT/$base"
  case "$mode" in
    iso )
      [ -e "$dest" ] && die "目标 $dest 已存在，请手动处理"
      log "移入管理目录: $path -> $dest" >&2
      mv "$path" "$dest"
      data=$(printf '%s/%s' "$DATA_ROOT" "$ver")
      ENTRIES+=("$ver|$dest|$base|$data")
      printf '%s\n' "${ENTRIES[-1]}"
      ;;
    link )
      data=$(printf '%s/%s' "$DATA_ROOT" "$ver")
      add_map_line "ext|$path|$data"
      log "登记外部检出(本体不动): $path (数据 $data)" >&2
      ENTRIES+=("$ver|$path|$base|$data")
      printf '%s\n' "${ENTRIES[-1]}"
      ;;
    body )
      [ -e "$dest" ] && die "目标 $dest 已存在，请手动处理"
      log "移入管理目录: $path -> $dest（数据留在旧位置 $LEGACY_HOME）" >&2
      mv "$path" "$dest"
      add_map_line "dir|$base|$LEGACY_HOME"
      data="$LEGACY_HOME"
      ENTRIES+=("$ver|$dest|$base|$data")
      printf '%s\n' "${ENTRIES[-1]}"
      ;;
  esac
}

# ---- 启动：端口规划 / 同 home 守卫 / 后台批量 ----
next_port() {  # 默认加一：在跑实例的最大端口 +1；一个都没有则从 $WEB_PORT 起找空闲
  local max="" p pid
  for p in $(listening_ports); do
    pid="$(port_pid "$p")"
    [ -n "$pid" ] || continue
    is_dsh_web_pid "$pid" || continue
    if [ -z "$max" ] || [ "$p" -gt "$max" ]; then max="$p"; fi
  done
  if [ -n "$max" ]; then port_free_from $((max + 1)); else port_free_from "$WEB_PORT"; fi
}

home_conflict_port() {  # <DSH_HOME> → 已有实例用着它的端口（无则空）
  local want="$1" rows p pid _a data _b _c _d _e
  [ -n "$want" ] || return 0
  want="$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")"
  rows="$(instances_live)"
  while IFS='|' read -r p pid _a _b data _c _d _e _f; do
    [ -n "$p" ] || continue
    [ -n "$data" ] || data="$LEGACY_HOME"
    if [ "$(readlink -f "$data" 2>/dev/null || printf '%s' "$data")" = "$want" ]; then
      printf '%s' "$p"; return 0
    fi
  done <<< "$rows"
  return 0
}

resolve_or_adopt() {  # <目标串> <端口> → 条目（UNMANAGED 时走登记流程；stdout 只输出条目）
  local target="$1" want_port="$2" entry mode owner upath
  entry="$(resolve_target "$target")"
  if [[ "$entry" == UNMANAGED:* ]]; then
    upath="${entry#UNMANAGED:}"
    owner="$(port_owner_cwd "$want_port")"
    if [ -n "$owner" ] && [ "$(readlink -f "$owner")" = "$upath" ]; then
      die "该检出正在运行中，不能移动/重新登记。请先停掉它。"
    fi
    if has_tty; then
      mode="$(adopt_prompt "$upath")"
    else
      log "非交互环境：按“仅数据隔离”登记 $upath"
      mode=link
    fi
    entry="$(adopt_and_entry "$upath" "$mode")"
  fi
  printf '%s\n' "$entry"
}

launch_bg_one() {  # <条目> <端口> <等待秒数> <noopen 0/1> → 0 就绪 / 1 未就绪
  local entry="$1" p="$2" tmo="$3" noopen="$4"
  local ver dir data unit unitname logf pid waited ts
  ver=$(entry_field "$entry" 1); dir=$(entry_field "$entry" 2)
  data="${ENTRY_HOME_OVERRIDE:-$(entry_field "$entry" 4)}"
  unit="dsh-web-$ver-$p"
  [ "$INSTANCE_KIND" = "debug" ] && unit="rdsh-dbg-$INSTANCE_ID-$p"
  logf="$LOG_DIR/web-$ver-$p.log"
  mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR" 2>/dev/null || true
  local common=(--collect --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=DSH_LAUNCH_DETACHED=1)
  local v
  for v in RDSH_BASE RDSH_CONFIG RDSH_MANAGE_ROOT RDSH_DATA_ROOT RDSH_BACKUP_ROOT \
           RDSH_SHARED_HOME RDSH_RUN_DIR DSH_LOG_DIR DSH_WEB_PORT DSH_WEB_LOG; do
    [ -n "${!v:-}" ] && common+=(--setenv="$v=${!v}")
  done
  local cmd=("$SELF" start "$dir" --port "$p" --foreground)
  [ "$INSTANCE_KIND" = "debug" ] && cmd+=(--debug "$INSTANCE_ID")
  [ "$noopen" = "1" ] && cmd+=(--no-open)
  [ "$WEB_LOG" = "1" ] || cmd+=(--no-log)
  if ! systemd-run --user --unit="$unit" "${common[@]}" "${cmd[@]}" >/dev/null 2>&1; then
    ts="$(date +%s)"; unitname="$unit-$ts"
    warn "单元名 $unit 已被占用，改用 $unitname"
    systemd-run --user --unit="$unitname" "${common[@]}" "${cmd[@]}" >/dev/null 2>&1 \
      || { warn "投递到 systemd 失败（systemd-run --user 不可用？）"; return 1; }
    unit="$unitname"
  fi
  log "已投递 unit=$unit，等端口 $p 就绪…"
  waited=0
  while ! port_listening "$p"; do
    if [ "$waited" -ge "$tmo" ]; then
      warn "端口 $p 在 ${tmo}s 内没起来 —— unit 仍在后台继续（首次安装可能很慢）"
      warn "  诊断：systemctl --user status $unit    日志：$logf"
      return 1
    fi
    sleep 1; waited=$((waited+1))
  done
  pid="$(port_pid "$p")"
  if ! is_dsh_web_pid "$pid"; then
    warn "端口 $p 上的进程不是我们的 dsh web（PID ${pid:-?}）—— 可能被别的服务占了。未登记。"
    return 1
  fi
  registry_put "$p" "$pid" "$ver" "$dir" "$data" "$INSTANCE_KIND" "$INSTANCE_ID" "$unit" "$logf"
  if [ "$INSTANCE_KIND" = "debug" ]; then
    log "已启动调试环境：$INSTANCE_ID（$ver）  端口 $p  PID $pid  等了 ${waited}s"
  else
    log "已启动：$ver  端口 $p  PID $pid  等了 ${waited}s"
  fi
  printf '        URL: http://127.0.0.1:%s/    日志: %s\n' "$p" "$logf"
  return 0
}

# ---- 调试环境：可丢弃沙箱 ----------------------------------------------------
# 布局：$DEBUG_ROOT/<id>.env（清单 600）+ $DEBUG_ROOT/<id>/（就是 DSH_HOME，默认**完全空**）。
# 「默认全新」= 不播种 settings、不链作者资产、不链凭据；要什么用 `debug add` 显式加，可 `detach` 摘掉。
# id 规则（硬约束）：必须以字母开头 —— 保证 `rdsh run 0.1.7` 永远命中正式版本，不会撞上沙箱名。
debug_env_file() { printf '%s/%s.env' "$DEBUG_ROOT" "$1"; }
debug_home()     { printf '%s/%s' "$DEBUG_ROOT" "$1"; }
debug_ids() {
  [ -d "$DEBUG_ROOT" ] || return 0
  local f
  for f in "$DEBUG_ROOT"/*.env; do
    [ -f "$f" ] || continue
    basename "$f" .env
  done
}
debug_get() {  # <id> <键> → 值（无则空）
  local f; f="$(debug_env_file "$1")"
  [ -f "$f" ] || return 0
  sed -nE "s/^$2=(.*)$/\1/p" "$f" | tail -1
}
debug_put() {  # <id> <版本> <检出> <assets 0/1> <creds none|link|copy>
  local id="$1" f created
  f="$(debug_env_file "$id")"; created="$(debug_get "$id" created)"
  [ -n "$created" ] || created="$(date -Is)"
  mkdir -p "$DEBUG_ROOT"; chmod 700 "$DEBUG_ROOT" 2>/dev/null || true
  ( umask 077
    { printf 'id=%s\n'      "$id"
      printf 'ver=%s\n'     "$2"
      printf 'dir=%s\n'     "$3"
      printf 'home=%s\n'    "$(debug_home "$id")"
      printf 'created=%s\n' "$created"
      printf 'assets=%s\n'  "$4"
      printf 'creds=%s\n'   "$5"
    } > "$f" )
}
debug_load() {  # <id> → 0/1；设好 DEBUG_MODE/ENTRY_HOME_OVERRIDE/INSTANCE_KIND/INSTANCE_ID
  local id="$1" home
  [ -n "$(debug_get "$id" home)" ] || return 1
  home="$(debug_home "$id")"
  [ -d "$home" ] || return 1
  DEBUG_MODE=1; ENTRY_HOME_OVERRIDE="$home"; INSTANCE_KIND=debug; INSTANCE_ID="$id"
  return 0
}
debug_port_of() {  # <id> → 该环境正在跑的端口（无则空）
  local p _pid _ver _dir _data _kind _id _unit _st
  while IFS='|' read -r p _pid _ver _dir _data _kind _id _unit _st; do
    [ -n "$p" ] || continue
    [ "$_id" = "$1" ] && { printf '%s' "$p"; return 0; }
  done <<< "$(instances_live)"
  return 0
}
debug_link_assets() {  # <home>：只建软链；home 里已有真文件只警告不动（P1）
  local home="$1" n
  for n in "${AUTHOR_ASSETS[@]}"; do
    [ -e "$SHARED_ROOT/$n" ] || { warn "稳定根没有 $n，跳过"; continue; }
    [ -L "$home/$n" ] && continue
    if [ -e "$home/$n" ]; then warn "$home/$n 已是真文件，未动"; continue; fi
    ln -s "$SHARED_ROOT/$n" "$home/$n"
    log "  + $n → $SHARED_ROOT/$n"
  done
}
debug_unlink_assets() {  # <home>：只摘"指向稳定根"的软链（把链接本身挪进回收目录，真身不动）
  local home="$1" n
  for n in "${AUTHOR_ASSETS[@]}"; do
    if [ -L "$home/$n" ] && [ "$(readlink -f "$home/$n")" = "$(readlink -f "$SHARED_ROOT/$n")" ]; then
      rdsh_trash_quiet "$home/$n"; log "  - $n"
    fi
  done
}
creds_source() {  # 凭据源：优先各版本 home，其次 ~/.dsh
  local e data
  for e in "${ENTRIES[@]}"; do
    data="$(entry_field "$e" 4)"
    [ -f "$data/.credentials.yaml" ] && { printf '%s' "$data/.credentials.yaml"; return 0; }
  done
  [ -f "$LEGACY_HOME/.credentials.yaml" ] && printf '%s' "$LEGACY_HOME/.credentials.yaml"
  return 0
}
debug_link_creds() {  # <home> [link|copy]
  local home="$1" mode="${2:-link}" src
  src="$(creds_source)"
  [ -n "$src" ] || { warn '找不到 .credentials.yaml（各版本 home 与 ~/.dsh 都没有）→ 跳过凭据'; return 1; }
  if [ -L "$home/.credentials.yaml" ]; then
    if [ "$(readlink -f "$home/.credentials.yaml")" = "$(readlink -f "$src")" ]; then
      log '  = .credentials.yaml 已链到同一份源，跳过'
      return 0
    fi
    rdsh_trash "$home/.credentials.yaml"      # 别的软链：挪走留痕再链
  elif [ -e "$home/.credentials.yaml" ]; then
    # dsh 首启会自己建一个空的 .credentials.yaml（不带 key）；要接真凭据就得先把它挪走
    rdsh_trash "$home/.credentials.yaml"
  fi
  if [ "$mode" = "copy" ]; then
    cp -p "$src" "$home/.credentials.yaml"
    chmod 600 "$home/.credentials.yaml"    # dsh 硬校验：凭据文件不能有组/其他位
    log '  + .credentials.yaml（独立复制一份，已 chmod 600）'
  else
    ln -s "$src" "$home/.credentials.yaml"
    log "  + .credentials.yaml → $src（软链，读写同一份）"
  fi
}
debug_unlink_creds() {  # <home>
  local home="$1"
  [ -L "$home/.credentials.yaml" ] || return 0
  rdsh_trash_quiet "$home/.credentials.yaml"; log '  - .credentials.yaml（链接挪走，真身未动）'
}

cmd_debug_ls() {
  local ids; ids="$(debug_ids)"
  if [ -z "$ids" ]; then
    log "还没有调试环境。新建：rdsh debug new <版本> --tag <名> [--assets] [--creds] [--start]"
    return 0
  fi
  local id home ver created assets creds size port rows; rows="$(instances_live)"
  printf '\n调试环境（%s）：\n' "$DEBUG_ROOT"
  for id in $ids; do
    home="$(debug_home "$id")"; ver="$(debug_get "$id" ver)"; created="$(debug_get "$id" created)"
    assets="$(debug_get "$id" assets)"; creds="$(debug_get "$id" creds)"
    size="$(du -sh "$home" 2>/dev/null | cut -f1 || true)"
    port="$(debug_port_of "$id")"
    printf '  %-14s %-14s %s\n' "$id" "$ver" "$([ -n "$port" ] && echo "运行中（端口 $port）" || echo '未运行')"
    printf '        home: %s (%s)   创建: %s\n' "$home" "${size:-?}" "$created"
    printf '        作者资产: %s   凭据: %s\n' \
      "$([ "$assets" = "1" ] && echo '已链' || echo '无')" \
      "$([ -z "$creds" ] || [ "$creds" = "none" ] && echo '无' || echo "$creds")"
    printf '        启动: rdsh debug start %s     删除: rdsh debug rm %s\n' "$id" "$id"
  done
}

cmd_debug_new() {
  local ver="" tag="" assets=0 creds="none" port="" start=0 dry=0 a
  local -a sargs=()
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --tag ) shift; [ $# -gt 0 ] || die '--tag 需要名字'; tag="$1" ;;
      --tag=* ) tag="${a#--tag=}" ;;
      --assets ) assets=1 ;;
      --creds ) creds=link ;;
      --copy-creds ) creds=copy ;;
      --port ) shift; [ $# -gt 0 ] || die '--port 需要端口号'; sargs+=(--port "$1") ;;
      --port=* ) sargs+=(--port "${a#--port=}") ;;
      --no-open|--open|--foreground|--fg ) sargs+=("$a") ;;
      --start ) start=1 ;;
      --dry-run|-n ) dry=1 ;;
      -*) die "未知选项：$a（用 rdsh help 看用法）" ;;
      * ) ver="$a" ;;
    esac
    shift
  done
  [ -n "$ver" ] || die '用法: rdsh debug new <版本|序号|项目名|路径> [--tag 名] [--assets] [--creds|--copy-creds] [--port N] [--start] [--dry-run]'
  local entry; entry="$(resolve_target "$ver")"
  [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理，先 rdsh add <路径> --mode iso|link|body'
  local rver id home i
  rver="$(entry_field "$entry" 1)"
  if [ -z "$tag" ]; then
    i=1; while [ -e "$(debug_env_file "d$i")" ] || [ -d "$(debug_home "d$i")" ]; do i=$((i+1)); done
    id="d$i"
  else
    id="$tag"
  fi
  case "$id" in
    [A-Za-z]*) ;;
    *) die "调试环境 id 必须以字母开头（收到：$id）—— 这样 rdsh run <版本> 永远不会撞上沙箱名" ;;
  esac
  case "$id" in *[!A-Za-z0-9._-]*) die "id 只能含字母数字与 . _ -（收到：$id）" ;; esac
  home="$(debug_home "$id")"
  if [ -e "$(debug_env_file "$id")" ] || [ -d "$home" ]; then
    die "调试环境 “$id” 已存在（rdsh debug ls 看）"
  fi
  log "新建调试环境: $id（版本 $rver）"
  printf '  DSH_HOME : %s\n  检出     : %s\n  正式数据 : %s（本命令不会碰它）\n' \
    "$home" "$(entry_field "$entry" 2)" "$(entry_field "$entry" 4)"
  if [ "$dry" = "1" ]; then log '--dry-run：未创建任何东西。'; return 0; fi
  mkdir -p "$home"; chmod 700 "$home"
  debug_put "$id" "$rver" "$(entry_field "$entry" 2)" "$assets" "$creds"
  log '默认全新：不播种 settings、不链作者资产、不链凭据'
  if [ "$assets" = "1" ]; then debug_link_assets "$home"; fi
  if [ "$creds" != "none" ]; then debug_link_creds "$home" "$creds" || true; fi
  log "创建完成。启动：rdsh debug start $id    删除：rdsh debug rm $id"
  if [ "$start" = "1" ]; then
    cmd_debug_start "$id" "${sargs[@]}"
  fi
}

cmd_debug_start() {
  local id="${1:-}"; [ -n "$id" ] || die '用法: rdsh debug start <id> [--port N] [--foreground] [--no-open]'
  shift
  debug_load "$id" || die "没有调试环境 “$id”（rdsh debug ls 看）"
  local dir; dir="$(debug_get "$id" dir)"
  [ -d "$dir" ] || die "调试环境 $id 的检出已不存在：$dir"
  cmd_start "$dir" --debug "$id" "$@"
}

cmd_debug_stop() {
  local id="${1:-}"; [ -n "$id" ] || die '用法: rdsh debug stop <id>'
  debug_load "$id" >/dev/null 2>&1 || die "没有调试环境 “$id”"
  shift
  cmd_stop "$id" "$@"
}

cmd_debug_add() {  # <id> [--assets] [--creds|--copy-creds]
  local id="${1:-}"; [ -n "$id" ] || die '用法: rdsh debug add <id> [--assets] [--creds|--copy-creds]'
  shift
  [ -f "$(debug_env_file "$id")" ] || die "没有调试环境 “$id”"
  local home a assets creds did=0
  home="$(debug_home "$id")"
  assets="$(debug_get "$id" assets)"; [ -n "$assets" ] || assets=0
  creds="$(debug_get "$id" creds)";   [ -n "$creds" ]  || creds=none
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --assets ) debug_link_assets "$home"; assets=1; did=1 ;;
      --creds ) if debug_link_creds "$home" link; then creds=link; fi; did=1 ;;
      --copy-creds ) if debug_link_creds "$home" copy; then creds=copy; fi; did=1 ;;
      *) die "未知选项：$a（--assets / --creds / --copy-creds）" ;;
    esac
    shift
  done
  [ "$did" = "1" ] || die '要加什么？--assets / --creds / --copy-creds'
  debug_put "$id" "$(debug_get "$id" ver)" "$(debug_get "$id" dir)" "$assets" "$creds"
  log '清单已更新'
  warn 'skills 与 .credentials.yaml 是热重载的（应即时生效）；AGENTS.md / .agent-presets 通常要重启实例'
  log "生效：rdsh debug stop $id && rdsh debug start $id"
}

cmd_debug_detach() {  # <id> [--assets] [--creds]（不带参数 = 全摘）
  local id="${1:-}"; [ -n "$id" ] || die '用法: rdsh debug detach <id> [--assets] [--creds]'
  shift
  [ -f "$(debug_env_file "$id")" ] || die "没有调试环境 “$id”"
  local home assets creds a all=1
  home="$(debug_home "$id")"
  assets="$(debug_get "$id" assets)"; [ -n "$assets" ] || assets=0
  creds="$(debug_get "$id" creds)";   [ -n "$creds" ]  || creds=none
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --assets ) debug_unlink_assets "$home"; assets=0; all=0 ;;
      --creds ) debug_unlink_creds "$home"; creds=none; all=0 ;;
      *) die "未知选项：$a（--assets / --creds）" ;;
    esac
    shift
  done
  if [ "$all" = "1" ]; then
    debug_unlink_assets "$home"; debug_unlink_creds "$home"; assets=0; creds=none
  fi
  debug_put "$id" "$(debug_get "$id" ver)" "$(debug_get "$id" dir)" "$assets" "$creds"
  warn '真身（稳定根里的资产 / 源凭据）未动；被摘掉的软链在回收目录，mv 回去即可还原'
}

cmd_debug_rm() {  # <id> | --all | --older-than 7d
  local dry=0 all=0 older="" id="" a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --dry-run|-n ) dry=1 ;;
      --all ) all=1 ;;
      --older-than ) shift; older="${1:-}"; [ -n "$older" ] || die '--older-than 需要天数，如 7d' ;;
      -*) die "未知选项：$a" ;;
      * ) id="$a" ;;
    esac
    shift
  done
  local ids="" x c cut days
  if [ "$all" = "1" ]; then
    ids="$(debug_ids)"
  elif [ -n "$older" ]; then
    days="${older%d}"; case "$days" in ''|*[!0-9]*) die "--older-than 形如 7d（收到：$older）" ;; esac
    cut=$(( $(date +%s) - days * 86400 ))
    for x in $(debug_ids); do
      c="$(debug_get "$x" created)"; c="$(date -d "$c" +%s 2>/dev/null || echo 0)"
      [ "$c" -lt "$cut" ] && ids="$ids $x"
    done
  else
    [ -n "$id" ] || die '用法: rdsh debug rm <id> | --all | --older-than 7d（可加 --dry-run）'
    ids="$id"
  fi
  ids="$(printf '%s' "$ids" | tr ' ' '\n' | sed '/^$/d' | tr '\n' ' ')"
  if [ -z "${ids// /}" ]; then log '没有匹配的调试环境'; return 0; fi
  # 硬白名单：只能是 $DEBUG_ROOT 下的、且带清单的环境（正式 data/<版本> 到不了这里）
  for x in $ids; do
    [ -f "$(debug_env_file "$x")" ] || die "“$x” 不是调试环境（没有清单）—— 拒绝删除"
    case "$(debug_home "$x")" in "$DEBUG_ROOT"/*) ;; *) die "路径不在 $DEBUG_ROOT 下：$(debug_home "$x")" ;; esac
  done
  warn "将处理：$ids"
  local p dest ts
  for x in $ids; do
    p="$(debug_port_of "$x")"
    if [ -n "$p" ]; then
      if [ "$dry" = "1" ]; then
        log "[dry-run] 会先停端口 $p（环境 $x）"
      else
        cmd_stop "$x" || { warn "环境 $x 的实例未确认停止 → 跳过删除"; continue; }
      fi
    fi
  done
  if [ "$dry" = "1" ]; then log '--dry-run：未删除任何东西。'; return 0; fi
  ts="$(date +%Y%m%d-%H%M%S)"; dest="${RDSH_TRASH:-/tmp}/rdsh-trash-debug-$ts"
  mkdir -p "$dest"
  for x in $ids; do
    [ -e "$(debug_home "$x")" ] && mv "$(debug_home "$x")" "$dest/$x"
    [ -e "$(debug_env_file "$x")" ] && mv "$(debug_env_file "$x")" "$dest/$x.env"
    log "已挪走：$x"
  done
  log "回收目录（永不 rm）：$dest"
  printf '  还原：mv %s/<id> %s/ && mv %s/<id>.env %s/\n' "$dest" "$DEBUG_ROOT" "$dest" "$DEBUG_ROOT"
}

cmd_debug_env() {  # <id>：打印可直接 eval 的环境
  local id="${1:-}"; [ -n "$id" ] || die '用法: rdsh debug env <id>'
  debug_load "$id" >/dev/null 2>&1 || die "没有调试环境 “$id”"
  printf 'export DSH_HOME=%s\n' "$(debug_home "$id")"
  printf 'cd %s\n' "$(debug_get "$id" dir)"
}

cmd_debug() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    ""|ls|list ) cmd_debug_ls ;;
    new|create ) cmd_debug_new "$@" ;;
    start|up ) cmd_debug_start "$@" ;;
    stop|down ) cmd_debug_stop "$@" ;;
    add ) cmd_debug_add "$@" ;;
    detach ) cmd_debug_detach "$@" ;;
    rm|delete ) cmd_debug_rm "$@" ;;
    env ) cmd_debug_env "$@" ;;
    -h|--help|help ) printf 'rdsh debug new|start|stop|ls|add|detach|rm|env　（详见 rdsh help）\n' ;;
    * ) die "未知子命令：debug $sub（可用：new start stop ls add detach rm env）" ;;
  esac
}

cmd_exec() {  # exec <版本|序号|项目名|debug-id|路径> -- <命令...>
  local target="" a; local -a args=()
  while [ $# -gt 0 ]; do
    a="$1"
    if [ "$a" = "--" ]; then shift; args=("$@"); break; fi
    target="$a"; shift
  done
  [ -n "$target" ] || die '用法: rdsh exec <版本|序号|项目名|debug-id|路径> -- <命令...>'
  [ "${#args[@]}" -gt 0 ] || die '用法: rdsh exec <目标> -- <命令...>（-- 后面是要跑的命令）'
  local dir home entry
  if [ -n "$(debug_get "$target" home)" ]; then
    debug_load "$target" >/dev/null 2>&1 || die "调试环境 $target 不可用"
    dir="$(debug_get "$target" dir)"; home="$(debug_home "$target")"
  else
    entry="$(resolve_target "$target")"
    [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理，先 rdsh add <路径> --mode iso|link|body'
    dir="$(entry_field "$entry" 2)"; home="$(entry_field "$entry" 4)"
  fi
  [ -d "$dir" ] || die "检出不存在：$dir"
  log "环境 $home（检出 $dir）"
  ( cd "$dir" && DSH_HOME="$home" exec "${args[@]}" )
}

# ---- 子命令实现 ----
# run/start：默认后台化（systemd 用户单元，脱离终端与 DSH cgroup），端口默认递增；
# --foreground 回到"占着终端跑"的老行为（rdsh-restart.sh 与单元内部的调用走这条）。
cmd_start() {
  local dry=0 bg=1 noopen="" timeout="$LAUNCH_TIMEOUT" step=1 port="" explicit_port=0 takeover=0 debug_id="" a
  local -a raws=()
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --dry-run|-n ) dry=1 ;;
      --takeover ) takeover=1 ;;
      --debug ) shift; [ $# -gt 0 ] || die '--debug 需要一个调试环境 id'; debug_id="$1" ;;
      --no-log ) WEB_LOG=0 ;;
      --log ) WEB_LOG=1 ;;
      --foreground|--fg ) bg=0 ;;
      --background|--bg|-b ) bg=1 ;;
      --no-open ) noopen=1 ;;
      --open ) noopen=0 ;;
      --port ) shift; [ $# -gt 0 ] || die '--port 需要一个端口号'; port="$1"; explicit_port=1 ;;
      --port=* ) port="${a#--port=}"; explicit_port=1 ;;
      --step ) shift; [ $# -gt 0 ] || die '--step 需要数字'; step="$1" ;;
      --timeout ) shift; [ $# -gt 0 ] || die '--timeout 需要秒数'; timeout="$1" ;;
      -* ) die "未知选项：$a（用 rdsh help 看用法）" ;;
      * ) raws+=("$a") ;;
    esac
    shift
  done
  [ "${DSH_LAUNCH_DETACHED:-0}" = "1" ] && bg=0     # 防递归：单元内部一律前台
  if [ -n "$debug_id" ]; then
    debug_load "$debug_id" || die "没有调试环境 “$debug_id”（用 rdsh debug ls 看）"
  fi
  case "$step" in ''|*[!0-9]*) die "--step 需要非负整数，收到：$step" ;; esac
  case "$timeout" in ''|*[!0-9]*) die "--timeout 需要非负整数，收到：$timeout" ;; esac
  [ "$step" -ge 1 ] || die '--step 至少为 1'
  if [ -n "$port" ]; then case "$port" in *[!0-9]*) die "--port 需要数字，收到：$port" ;; esac; fi

  # ---- 选目标：无参数则走菜单（有 tty 才问）；支持一次给多个 ----
  if [ "${#raws[@]}" -eq 0 ]; then
    if has_tty; then
      list_entries >&2
      local defver; defver=$(entry_field "$(pick_default)" 1)
      printf '\n直接回车 = 默认 [1] %s；可一次给多个（空格分隔）：序号/版本/项目名/路径；q 退出。\n' "$defver" >&2
      printf '选择> ' >&2
      local sel=""; read -r sel || true
      sel=$(clean_input "$sel")
      printf '\n' >&2
      case "$sel" in q|Q ) echo '已取消'; exit 0 ;; esac
      if [ -n "$sel" ]; then raws=($sel); else raws=(""); fi
    else
      raws=("")
    fi
  fi
  if [ -z "$noopen" ]; then
    if [ "${#raws[@]}" -gt 1 ]; then noopen=1; else noopen=0; fi
  fi
  if [ "$noopen" = "1" ]; then NO_OPEN=1; else NO_OPEN=0; fi
  if [ "$bg" = "0" ] && [ "${#raws[@]}" -gt 1 ]; then
    die "前台模式只能启动 1 个目标（你要启动 ${#raws[@]} 个）：去掉 --foreground 走后台"
  fi

  # ---- 规划：条目 × 端口（先全部校验，再动手） ----
  local -a ents=() ports=()
  local t e p base="" i=0 conflict
  for t in "${raws[@]}"; do
    if [ "$i" -eq 0 ]; then
      if [ "$explicit_port" = "1" ]; then base="$port"; else base="$(next_port)"; fi
    else
      base=$((base + step))
    fi
    if [ "$explicit_port" = "1" ]; then p=$((port + i * step)); else p="$(port_free_from "$base")"; fi
    e="$(resolve_or_adopt "$t" "$p")"
    ents+=("$e"); ports+=("$p")
    i=$((i+1))
  done

  local -a keep_e=() keep_p=() note=()
  local bad=""
  i=0
  for e in "${ents[@]}"; do
    p="${ports[$i]}"
    local ehome; ehome="${ENTRY_HOME_OVERRIDE:-$(entry_field "$e" 4)}"
    conflict="$(home_conflict_port "$ehome")"
    local msg=""
    # --takeover：调用方声明"该 home / 该端口上的旧实例我马上会停掉"（rdsh-restart.sh 用）。
    # 真实占用仍会被 launch_entry 的 port_busy 复查挡住，不会静默双开。
    if [ "$takeover" = "1" ] && { [ -n "$conflict" ] || port_busy "$p"; }; then
      msg="! --takeover：该 home / 端口正被旧实例占用（调用方须先停掉它）"
    elif [ -n "$conflict" ]; then
      msg="✗ 数据目录已在端口 $conflict 上运行（同一 DSH_HOME 不能多开）"
      [ -z "$bad" ] && bad="数据目录 $ehome 已在端口 $conflict 上运行。同一 DSH_HOME 多开会互相写 workspace/settings —— 同版本多开请用 rdsh debug new。"
    elif port_busy "$p"; then
      if [ "$explicit_port" = "1" ]; then
        msg="✗ 端口 $p 已被占用（运行中检出：$(port_owner_cwd "$p")）"
        [ -z "$bad" ] && bad="127.0.0.1:$p 已被占用（运行中检出：$(port_owner_cwd "$p")）。换 --port，或先 rdsh stop。"
      else
        local np; np="$(port_free_from $((p + 1)))"
        msg="! 端口 $p 被占，改用 $np"
        p="$np"
      fi
    fi
    note+=("$msg"); keep_e+=("$e"); keep_p+=("$p")
    i=$((i+1))
  done
  ents=("${keep_e[@]}"); ports=("${keep_p[@]}")

  # ---- 计划（这几行的格式被 rdsh-restart.sh grep 解析，勿改） ----
  echo "== 启动计划（${#ents[@]} 个） =="
  i=0
  for e in "${ents[@]}"; do
    log "启动版本: $(entry_field "$e" 1)"
    log "检出目录: $(entry_field "$e" 2)"
    log "监听端口: ${ports[$i]}"
    printf 'DSH_HOME  : %s\n' "${ENTRY_HOME_OVERRIDE:-$(entry_field "$e" 4)}"
    [ "$INSTANCE_KIND" = "debug" ] && printf '调试环境  : %s（kind=debug，status 里会单列）\n' "$INSTANCE_ID"
    [ -n "${note[$i]}" ] && printf '            %s\n' "${note[$i]}"
    i=$((i+1))
  done
  printf '模式: %s%s\n' "$([ "$bg" = "1" ] && echo '后台（systemd 用户单元）' || echo '前台（占终端）')" \
    "$([ "$noopen" = "1" ] && echo '，不自动开浏览器' || echo '')"
  if [ -n "$bad" ]; then
    warn "$bad"
    if [ "$dry" = "1" ]; then log '--dry-run：计划里有冲突，未启动任何东西。'; return 1; fi
    die '计划里有冲突，未启动任何东西。'
  fi
  if [ "$dry" = "1" ]; then log '--dry-run：到此为止，未启动任何东西。'; return 0; fi

  # ---- 前台：只支持单个目标 ----
  if [ "$bg" = "0" ]; then
    launch_entry "${ents[0]}" 0 "${ports[0]}"
    return 0
  fi

  # ---- 后台：逐个投递 + 等就绪 + 登记 ----
  local failed=0
  i=0
  for e in "${ents[@]}"; do
    launch_bg_one "$e" "${ports[$i]}" "$timeout" "$noopen" || failed=$((failed+1))
    i=$((i+1))
  done
  echo
  if [ "$failed" = "0" ]; then
    log "全部就绪（${#ents[@]} 个）。看实例：rdsh status；停止：rdsh stop（默认停端口最大的）"
  else
    warn "$failed 个实例未在 ${timeout}s 内就绪（其余不受影响）"
  fi
  [ "$failed" = "0" ]
}

cmd_add() {  # add <路径> [--mode iso|link|body]
  [ $# -ge 1 ] || die "用法: rdsh add <检出路径> [--mode iso|link|body]"
  local path="" mode="" a
  for a in "$@"; do
    case "$a" in
      --mode ) mode=ask ;;
      iso|link|body ) mode="$a" ;;
      * ) path="$a" ;;
    esac
  done
  [ -d "$path" ] && [ -f "$path/package.json" ] || die "不是有效的 dsh 检出: $path"
  local e; e=$(entry_by_dir "$path")
  if [ -n "$e" ]; then log "已在管理中：$(entry_field "$e" 3)"; return 0; fi
  path=$(readlink -f "$path")
  if [ "$mode" = "ask" ] || [ -z "$mode" ]; then
    has_tty || die "用法: rdsh add <路径> --mode iso|link|body（非交互必须显式给模式）"
    mode=$(adopt_prompt "$path")
  fi
  adopt_and_entry "$path" "$mode" >/dev/null
  log '登记完成'
}

cmd_list() { list_entries; printf '\n共 %d 个。启动：rdsh <序号|版本|项目名|路径>\n' "${#ENTRIES[@]}"; }

cmd_status() {
  echo '== 运行实例 =='
  local rows; rows="$(instances_live)"
  if [ -z "$rows" ]; then
    printf '  无（未发现由 dsh/rdsh 启动的 web 实例；默认端口 %s 空闲）\n' "$WEB_PORT"
  else
    local p pid ver dir data kind id unit started tag
    while IFS='|' read -r p pid ver dir data kind id unit started; do
      [ -n "$p" ] || continue
      tag="$kind"
      [ "$kind" = "debug" ] && tag="debug:${id:-?}"
      local here=""
      ancestor_chain_has "$pid" && here="   ← 你所在的实例"
      printf '  [%s] %-14s %-12s PID %s%s\n' "$p" "$ver" "$tag" "$pid" "$here"
      printf '        运行检出: %s\n' "$dir"
      printf '        DSH_HOME: %s\n' "${data:-（默认 ~/.dsh）}"
      printf '        URL: http://127.0.0.1:%s/    unit: %s    启动: %s\n' \
        "$p" "${unit:-（无，非 systemd 托管）}" "${started:-未知}"
    done <<< "$rows"
  fi
  echo
  echo '== 数据目录总览 =='
  local i=1 e ver dir data
  for e in "${ENTRIES[@]}"; do
    ver=$(entry_field "$e" 1); dir=$(entry_field "$e" 2); data=$(entry_field "$e" 4)
    printf '  [%d] %-14s 检出:%-10s 数据: %s (%s)\n' "$i" "$ver" "$(built_status "$dir")" "$data" "$(data_state "$data")"
    i=$((i+1))
  done
}

# ---------------- stop：停止实例 ----------------
# 默认 = 停"端口最大的那一个"（后进先出，与 run 的端口递增对称）；--all = 从最大端口往小全停。
# 唯一不可覆盖的红线：目标进程过不了归属校验就绝不碰。
cmd_stop() {
  local ORIG_ARGS=("$@")
  local all=0 dry=0 force=0 probe=0 port="" arg="" timeout="$STOP_TIMEOUT" delay="$STOP_DELAY" a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --all|-a ) all=1 ;;
      --dry-run|-n ) dry=1 ;;
      --probe ) probe=1 ;;
      --force|-f|--yes|-y ) force=1 ;;
      --timeout ) shift; [ $# -gt 0 ] || die '--timeout 需要秒数'; timeout="$1" ;;
      --delay ) shift; [ $# -gt 0 ] || die '--delay 需要秒数'; delay="$1" ;;
      --port ) shift; [ $# -gt 0 ] || die '--port 需要端口号'; port="$1" ;;
      --port=* ) port="${a#--port=}" ;;
      -*) die "未知选项：$a（用 rdsh help 看用法）" ;;
      * ) arg="$a" ;;
    esac
    shift
  done
  case "$timeout" in ''|*[!0-9]*) die "--timeout 需要非负整数，收到：$timeout" ;; esac
  case "$delay"   in ''|*[!0-9]*) die "--delay 需要非负整数，收到：$delay" ;; esac

  local rows; rows="$(instances_live)"
  [ -n "$rows" ] || { log '没有在跑的 dsh 实例'; return 0; }

  # ---- 选目标 ----
  local sel="" p pid ver dir data kind id unit started n=0
  if [ -n "$port" ]; then
    case "$port" in ''|*[!0-9]*) die "--port 需要数字，收到：$port" ;; esac
    sel="$(printf '%s\n' "$rows" | awk -F'|' -v pp="$port" '$1==pp')"
    [ -n "$sel" ] || die "端口 $port 上没有在跑的 dsh 实例（用 rdsh status 看）"
  elif [ "$all" = "1" ]; then
    sel="$(printf '%s\n' "$rows" | sort -t'|' -k1,1nr)"
  elif [ -n "$arg" ]; then
    while IFS='|' read -r p pid ver dir data kind id unit started; do
      [ -n "$p" ] || continue
      if instance_matches "$arg" "$p" "$ver" "$dir" "$id"; then
        sel="$sel$p|$pid|$ver|$dir|$data|$kind|$id|$unit|$started"$'\n'
        n=$((n+1))
      fi
    done <<< "$rows"
    [ "$n" -gt 0 ] || die "没有匹配 “$arg” 的在跑实例（用 rdsh status 看）"
    [ "$n" -eq 1 ] || die "“$arg” 匹配到 $n 个实例，请改用 --port 指定"
  else
    sel="$(printf '%s\n' "$rows" | sort -t'|' -k1,1nr | head -1)"   # 默认：端口最大
  fi

  # ---- 自杀检测（目标是不是本进程的祖先） ----
  local self_ports=""
  while IFS='|' read -r p pid ver dir data kind id unit started; do
    [ -n "$p" ] || continue
    ancestor_chain_has "$pid" && self_ports="$self_ports $p"
  done <<< "$sel"

  # ---- 计划 ----
  echo '== 停止计划 =='
  n=0
  local how
  while IFS='|' read -r p pid ver dir data kind id unit started; do
    [ -n "$p" ] || continue
    n=$((n+1))
    if [ -n "$unit" ]; then how="systemctl --user stop $unit"; else how="SIGTERM PID $pid"; fi
    printf '  %d) 端口 %s  %s  [%s%s]  %s\n' "$n" "$p" "$ver" "$kind" "${id:+:$id}" "$how"
  done <<< "$sel"
  [ -n "$self_ports" ] && warn "其中包含**你所在的实例**（端口：$self_ports）——停它会截断当前会话/终端"
  if [ "$dry" = "1" ]; then
    log '--dry-run：到此为止，未发任何信号。'
    return 0
  fi

  # ---- 自杀防护 + 逃生舱 ----
  # 需要投递到一次性单元的场景：① 目标包含自己（否则命令会被自己触发的关停杀掉）
  # ② --probe（照常投递，只验证链路）。已在单元里就不再投递（防递归）。
  local need_detach=0
  [ -n "$self_ports" ] && need_detach=1
  [ "$probe" = "1" ] && need_detach=1
  [ "${DSH_STOP_DETACHED:-0}" = "1" ] && need_detach=0

  if [ "$need_detach" = "1" ]; then
    if [ -n "$self_ports" ] && [ "$force" != "1" ]; then
      if has_tty; then
        printf '目标包含你所在的实例，确认停止请输入 yes > ' >&2
        local ans=""; read -r ans || true
        [ "$(clean_input "$ans")" = "yes" ] || die '已取消'
      else
        die '非交互环境拒绝自杀式停止（会截断当前会话）。确认无误请加 --force，或用 rdsh-restart.sh 重启。'
      fi
    fi
    local logf="$LOG_DIR/stop-$(date +%Y%m%d-%H%M%S).log" unitname
    unitname="$(detach_stop "$logf" "$timeout" "$delay" "${ORIG_ARGS[@]}")"
    if [ "$probe" = "1" ]; then
      log "已投递到 systemd 单元：$unitname（--probe：只验证投递链路，不发信号）"
    else
      log "已投递到 systemd 单元：$unitname（$delay 秒后停止端口$self_ports）"
      log '当前会话/终端即将被停掉 —— 这是预期的。'
    fi
    log "进度与结果看：$logf"
    return 0
  fi

  # ---- 执行 ----
  if [ "${DSH_STOP_PROBE:-0}" = "1" ] || [ "$probe" = "1" ]; then
    log "--probe：投递链路验证结束 —— 未发任何信号、未停止任何实例。"
    log "（若这是真跑，接下来会停止：$(printf '%s' "$sel" | awk -F'|' '{printf "%s ", $1}')）"
    return 0
  fi
  # 自杀/投递场景才需要缓冲：单元副本里自己不是 dsh 后代（self_ports 为空），
  # 所以必须把 DSH_STOP_DETACHED 也算进来，否则 --delay 会被静默跳过。
  if [ "$delay" -gt 0 ] && { [ -n "$self_ports" ] || [ "${DSH_STOP_DETACHED:-0}" = "1" ]; }; then
    log "等待 ${delay}s（给调用方落盘的时间）…"
    sleep "$delay"
  fi
  echo '== 执行 =='
  local failed=0
  while IFS='|' read -r p pid ver dir data kind id unit started; do
    [ -n "$p" ] || continue
    stop_one "$p" "$pid" "$ver" "$dir" "$kind" "$id" "$unit" "$timeout" || failed=$((failed+1))
  done <<< "$sel"
  echo
  if [ "$failed" = "0" ]; then log '停止完成'; else warn "$failed 个实例未能确认停止"; fi
  [ "$failed" = "0" ]
}

cmd_install() {
  [ $# -ge 1 ] || die "用法: rdsh install <序号|版本名|项目名|检出路径>"
  local entry; entry=$(resolve_target "$1")
  [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理，先运行: rdsh add <路径> --mode iso|link|body'
  ensure_built "$(entry_field "$entry" 2)"
}

cmd_data() {
  [ $# -ge 1 ] || die "用法: rdsh data [-o] <序号|版本名|项目名|检出路径>"
  local open=0 args=() a
  for a in "$@"; do case "$a" in -o|--open ) open=1 ;; * ) args+=("$a") ;; esac; done
  local entry; entry=$(resolve_target "${args[0]}") || die '解析目标失败'
  [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理，先运行: rdsh add <路径> --mode iso|link|body'
  local ver data
  ver=$(entry_field "$entry" 1); data=$(entry_field "$entry" 4)
  echo "版本 $ver 的数据目录: $data"
  if [ "$data" = "$LEGACY_HOME" ] && [ ! -d "$data" ]; then
    die "目标 $data 不存在，先确认 ~/.dsh 位置或改 .map"
  fi
  [ -d "$data" ] || { log "创建 $data"; mkdir -p "$data"; chmod 700 "$data"; }
  if [ "$open" = "1" ]; then
    command -v xdg-open >/dev/null && xdg-open "$data" || echo "请手动打开: $data"
  fi
}

cmd_backup() {
  [ $# -ge 1 ] || die "用法: rdsh backup <序号|版本名|项目名>"
  local entry; entry=$(resolve_target "$1")
  [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理'
  local ver data
  ver=$(entry_field "$entry" 1); data=$(entry_field "$entry" 4)
  [ -d "$data" ] || die "版本 $ver 尚无数据目录（$data）"
  local dest="$BACKUP_ROOT/$ver-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$dest")"
  log "备份 $data -> $dest"
  cp -a "$data" "$dest"
  log '备份完成'
}

# ---------------- base：查看/设置基目录（P1：只改指向，不搬数据） ----------------
cmd_base() {
  local arg="" unset=0 dry=0 a
  for a in "$@"; do case "$a" in --unset) unset=1 ;; --dry-run) dry=1 ;; *) arg="$a" ;; esac; done

  echo '当前解析（优先级：环境变量 > 配置文件 > 默认）：'
  printf '  配置文件   : %s%s\n' "$RDSH_CONFIG" "$([ -f "$RDSH_CONFIG" ] && echo '' || echo '（不存在）')"
  printf '  基目录 BASE: %s\n' "$BASE"
  printf '  检出根     : %s\n' "$MANAGE_ROOT"
  printf '  数据根     : %s\n' "$DATA_ROOT"
  printf '  作者资产根 : %s\n' "$SHARED_ROOT"
  printf '  备份根     : %s\n' "$BACKUP_ROOT"
  printf '  启动日志   : %s\n' "$LOG_DIR"
  printf '  实例注册表 : %s（注解层）\n' "$RUN_DIR"
  printf '  默认端口   : %s\n' "$WEB_PORT"
  [ -n "${RDSH_BASE:-}" ] && warn "环境变量 RDSH_BASE=$RDSH_BASE 正在覆盖配置文件（改配置不会生效）"

  if [ -z "$arg" ] && [ "$unset" = "0" ]; then
    echo
    echo '改基目录（示例）：'
    printf '  rdsh base %s      # 检出在 %s/dsh、数据在 %s/.dsh、备份在 %s/.dsh-backup\n' "$HOME" "$HOME" "$HOME" "$HOME"
    printf '  rdsh base %s      # 回到当前这种布局\n' "$HOME/Mapp"
    echo  '  rdsh base --unset                 # 删掉配置里的 BASE，回到默认 $HOME/Mapp'
    echo
    echo '说明：本命令只改 rdsh 的指向，**不搬动**任何现有检出/数据；新位置为空时会自动创建。'
    return 0
  fi

  mkdir -p "$(dirname "$RDSH_CONFIG")"
  if [ "$unset" = "1" ]; then
    if [ ! -f "$RDSH_CONFIG" ]; then warn "配置文件不存在，无需删除"; return 0; fi
    if [ "$dry" = "1" ]; then echo "[dry-run] 从 $RDSH_CONFIG 删除 BASE 行"; return 0; fi
    sed -i '/^[[:space:]]*BASE[[:space:]]*=/d' "$RDSH_CONFIG"
    log "已删除 $RDSH_CONFIG 中的 BASE"
    return 0
  fi

  case "$arg" in /*|~*) ;; *) die "基目录必须是绝对路径或以 ~ 开头（收到：$arg）" ;; esac
  arg="$(expand "$arg")"
  if [ "$dry" = "1" ]; then
    echo "[dry-run] 将把 BASE=$arg 写入 $RDSH_CONFIG（不创建目录、不搬数据）"
    return 0
  fi
  [ -d "$arg" ] || { log "创建基目录 $arg"; mkdir -p "$arg"; }
  touch "$RDSH_CONFIG"
  if grep -qE '^[[:space:]]*BASE[[:space:]]*=' "$RDSH_CONFIG"; then
    sed -i "s|^[[:space:]]*BASE[[:space:]]*=.*|BASE=$arg|" "$RDSH_CONFIG"
  else
    printf 'BASE=%s\n' "$arg" >> "$RDSH_CONFIG"
  fi
  log "已写入 BASE=$arg → $RDSH_CONFIG"
  echo
  warn '本命令只改 rdsh 的**指向**，现有数据/检出一个都没动（原则 P1）：'
  printf '  现有检出仍在 : %s\n' "$MANAGE_ROOT"
  printf '  现有数据仍在 : %s\n' "$DATA_ROOT"
  printf '  新的检出根   : %s/dsh\n' "$arg"
  printf '  新的数据根   : %s/.dsh\n' "$arg"
  printf '  要搬家请自行 rsync/mv，或用重装（rdsh fetch && rdsh install）后把数据目录拷过去。\n'
}

# ---------------- logs：查看/清理启动日志 ----------------
cmd_logs() {
  local follow=0 open=0 clean=0 target="" a
  for a in "$@"; do case "$a" in -f|--follow) follow=1 ;; -o|--open) open=1 ;; --clean) clean=1 ;; *) target="$a" ;; esac; done
  [ -d "$LOG_DIR" ] || die "日志目录不存在：$LOG_DIR（还没用 rdsh 启动过？）"

  if [ "$clean" = "1" ]; then
    local f n=0
    for f in "$LOG_DIR"/web-*.log; do
      [ -f "$f" ] || continue
      : > "$f"; n=$((n+1))
    done
    log "已清空 $n 个日志文件（文件保留，内容清掉）"
    return 0
  fi

  local ver=""
  if [ -z "$target" ]; then
    ver=$(entry_field "$(pick_default)" 1)
  else
    local entry; entry=$(resolve_target "$target")
    [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理'
    ver=$(entry_field "$entry" 1)
  fi
  # 日志名带端口（同版本多实例各写各的）：优先"该版本正在跑的实例端口"，
  # 再回退默认端口，再回退旧命名 web-<版本>.log，最后回退任意端口的最新一份
  local f="" cand p rp="" _pid _ver _dir _data _kind _id _unit _st
  while IFS='|' read -r p _pid _ver _dir _data _kind _id _unit _st; do
    [ -n "$p" ] || continue
    [ "$_ver" = "$ver" ] && { rp="$p"; break; }
  done <<< "$(instances_live)"
  for cand in ${rp:+"$LOG_DIR/web-$ver-$rp.log"} "$LOG_DIR/web-$ver-$WEB_PORT.log" "$LOG_DIR/web-$ver.log"; do
    [ -f "$cand" ] && { f="$cand"; break; }
  done
  if [ -z "$f" ]; then
    f="$(ls -1t "$LOG_DIR"/web-"$ver"-*.log 2>/dev/null | head -1 || true)"
  fi
  [ -n "$f" ] || die "没有 $ver 的启动日志（该版本还没启动过？用 rdsh logs --clean 清理全部）"

  echo "日志文件（token 已打码显示）：$f"
  ls -la "$LOG_DIR" | sed 's/^/  /'
  if [ "$open" = "1" ] && command -v xdg-open >/dev/null; then xdg-open "$f"; return 0; fi
  echo '--- 末尾 200 行 ---'
  if [ "$follow" = "1" ]; then
    tail -f "$f"
  else
    sed -E 's/token=[A-Za-z0-9_-]+/token=***/g' "$f" | tail -200
  fi
}

# ---------------- fetch：从 GitHub 拉取指定版本的检出 ----------------
rdsh_trash() {  # 失败/清理时把半成品挪走（不 rm；与 guard-rails 的约定一致）
  local p="$1"
  [ -e "$p" ] || return 0
  local dest="${RDSH_TRASH:-/tmp}/rdsh-trash-$(basename "$p")-$(date +%s)"
  mv "$p" "$dest" 2>/dev/null && warn "已移到回收目录：$dest" || warn "无法移动 $p，请手动处理"
}
rdsh_trash_quiet() {  # 同 rdsh_trash，但成功路径上不吭声
  local p="$1"
  [ -e "$p" ] || return 0
  mv "$p" "${RDSH_TRASH:-/tmp}/rdsh-trash-$(basename "$p")-$(date +%s)" 2>/dev/null || true
}
remote_tags_git() {  # git 协议列举（备选；某些网络对 git over HTTPS 不友好）
  command -v git >/dev/null || return 1
  timeout "${RDSH_FETCH_TIMEOUT:-60}" git ls-remote --tags --refs "$REMOTE_URL" 2>/tmp/rdsh-ls-remote.err \
    | awk -F/ '{print $NF}' | sed "s|^$TAG_PREFIX||" | sort -V
}
remote_tags_api() {  # GitHub API 列举（首选：一次 HTTPS 请求，比 git 协商轻；未认证限流 60 次/小时）
  command -v curl >/dev/null || return 1
  local url="https://api.github.com/repos/deepseek-ai/deepseek-harness/tags?per_page=100" json out
  json="$(timeout "${RDSH_FETCH_TIMEOUT:-60}" curl -sS --retry 1 --connect-timeout 10 "$url" 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  if command -v jq >/dev/null; then
    out="$(printf '%s' "$json" | jq -r '.[].name' 2>/dev/null | sed "s|^$TAG_PREFIX||" | sort -V)"
  else
    out="$(printf '%s' "$json" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sed "s|^$TAG_PREFIX||" | sort -V)"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
remote_tags() { remote_tags_api || remote_tags_git; }
all_remote_tags() {  # 带 10 分钟磁盘缓存的远端 tag；--refresh 强制刷新
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/rdsh"
  local cache="$cache_dir/tags-$(printf '%s' "$REMOTE_URL" | md5sum | cut -c1-8)"
  local ttl="${RDSH_TAGS_TTL:-600}" now age=999999
  now=$(date +%s)
  [ -s "$cache" ] && age=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if [ "${REFRESH:-0}" = "1" ] || [ ! -s "$cache" ] || [ "$age" -gt "$ttl" ]; then
    mkdir -p "$cache_dir"
    if remote_tags > "$cache.tmp" 2>/dev/null && [ -s "$cache.tmp" ]; then
      mv "$cache.tmp" "$cache"
    else
      rdsh_trash_quiet "$cache.tmp"
      [ -s "$cache" ] || die "拿不到远端版本列表：网络不通（校园网/公司网对 GitHub 可能不畅）、或 git/curl 不可用。可试 --refresh，或调大 RDSH_FETCH_TIMEOUT"
      warn '远端查询失败，用的是缓存（可能不是最新）'
    fi
  fi
  cat "$cache"
}
cmd_fetch() {
  local list=0 tarball=0 gitmode=1 full=0 do_install=0 dry=0 dirname="" ver="" a prev=""
  for a in "$@"; do
    case "$a" in
      --list|-l) list=1 ;;
      --tarball) tarball=1; gitmode=0 ;;
      --git) gitmode=1; tarball=0 ;;
      --full) full=1 ;;
      --install) do_install=1 ;;
      --dry-run) dry=1 ;;
      --refresh) REFRESH=1 ;;
      --dir) : ;;                                    # 取值看下面的 prev
      -*) die "未知选项：$a（用 rdsh help 看用法）" ;;
      *) if [ "$prev" = "--dir" ]; then dirname="$a"; else ver="$a"; fi ;;
    esac
    prev="$a"
  done

  if [ "$list" = "1" ]; then
    log "远端版本（$REMOTE_URL ｜ tag 前缀 $TAG_PREFIX ｜ ✅ = 本机已有）："
    # 本机已有版本：按**目录里的 package.json 版本号**判定，不依赖目录命名（历史上带/不带 v 两种都有）
    local localvers="" d v mark
    for d in "$MANAGE_ROOT"/*/; do
      [ -d "$d" ] || continue
      localvers="$localvers $(read_version "${d%/}")"
    done
    all_remote_tags | tac | while read -r v; do
      [ -n "$v" ] || continue
      case " $localvers " in *" $v "*) mark='✅' ;; *) mark='  ' ;; esac
      printf '  %s %s\n' "$mark" "$v"
    done
    [ -s /tmp/rdsh-ls-remote.err ] && warn "git stderr：$(head -2 /tmp/rdsh-ls-remote.err)"
    return 0
  fi

  [ -n "$ver" ] || die '用法: rdsh fetch <版本>（用 rdsh fetch --list 看可选）'
  local tag="$TAG_PREFIX$ver"
  # 本地检查先做：目标已存在就不必联网
  local target="$MANAGE_ROOT/${dirname:-deepseek-harness-dsh-$ver}"
  [ -e "$target" ] && die "目标已存在：$target（改名/移走，或用 --dir 换个名字）"

  local tags; tags="$(all_remote_tags)"
  if ! printf '%s\n' "$tags" | grep -qx "$ver"; then
    warn "远端没有版本「$ver」，相近的有："
    printf '%s\n' "$tags" | grep -F "$(printf '%s' "$ver" | cut -d. -f1,2)" | tail -5 | sed 's/^/    /'
    die '请用 rdsh fetch --list 选一个'
  fi

  if [ "$dry" = "1" ]; then
    printf '  [dry-run] 方式: %s\n' "$([ "$tarball" = "1" ] && echo '归档 tarball（--tarball，无 .git）' || echo "git clone$([ "$full" = "1" ] && echo '' || echo ' --depth 1') --branch $tag（默认）")"
    printf '  [dry-run] 目标: %s\n' "$target"
    printf '  [dry-run] 之后: rdsh install %s\n' "$ver"
    return 0
  fi

  mkdir -p "$MANAGE_ROOT"
  local tmp="$MANAGE_ROOT/.fetch-$ver-$(date +%Y%m%d-%H%M%S)"
  log "拉取 $tag → $target"
  if [ "$tarball" = "1" ]; then
    local url="https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/$tag.tar.gz"
    mkdir -p "$tmp"
    log "下载 $url"
    if ! curl -fL --retry 2 --connect-timeout 15 -o "$tmp/src.tar.gz" "$url"; then
      rdsh_trash "$tmp"
      die '下载失败：网络不畅（校园网/公司网对 GitHub 常见）或版本不存在。可重试、去掉 --tarball 改用默认的 git 方式，或调大 RDSH_FETCH_TIMEOUT'
    fi
    if ! tar -xzf "$tmp/src.tar.gz" -C "$tmp"; then rdsh_trash "$tmp"; die '解压失败'; fi
    local inner; inner="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d -name 'deepseek-harness-*' | head -1)"
    [ -n "$inner" ] || { rdsh_trash "$tmp"; die '归档结构与预期不符'; }
    mv "$inner" "$target"
    rdsh_trash_quiet "$tmp"   # 成功路径：静默清理临时目录（不 rm，挪到回收目录）
    warn '注意：归档检出没有 .git —— rdsh patch export 不可用，也无法 git diff/status 对比上游；需要补丁或考古请去掉 --tarball 用默认的 git 方式重拉。'
  else
    local depth=(--depth 1)
    [ "$full" = "1" ] && depth=()
    if ! git clone "${depth[@]}" --branch "$tag" "$REMOTE_URL" "$tmp"; then
      rdsh_trash "$tmp"
      die 'git clone 失败：网络不畅或版本不存在。可重试、改用归档方式 --tarball，或调大 RDSH_FETCH_TIMEOUT'
    fi
    mv "$tmp" "$target"
  fi

  local got; got="$(read_version "$target")"
  if [ "$got" != "$ver" ]; then
    warn "校验不符：目录里的版本号是 $got，期望 $ver（tag 与 package.json 可能不同步）"
  else
    log "校验通过：$target（版本 $got）"
  fi
  log "下一步：rdsh install $ver（pnpm install + build，较慢）"
  if [ "$do_install" = "1" ]; then
    load_map; collect_entries; sort_entries   # 让新检出进入清单
    cmd_install "$ver"
  fi
}

cmd_help() { sed -n '2,/^# =\{20,\}$/p' "$0"; }   # 打印头部文档块（不再依赖魔法行号）

# ---- 入口 ----
# 被投递到 systemd 单元执行时（自杀式停止），输出统一落盘，事后可查
if [ -n "${DSH_STOP_LOG:-}" ]; then
  exec >>"$DSH_STOP_LOG" 2>&1
  log "（本次由 systemd 单元执行，日志：$DSH_STOP_LOG）"
fi

main() {
  local cmd="${1:-start}"
  # 只有需要"检出清单"的子命令才去扫描；fetch/base/help 在空基目录下也要能跑
  case "$cmd" in
    base|fetch|help|-h|--help ) : ;;
    * ) load_map; collect_entries; sort_entries ;;
  esac
  case "$cmd" in
    ""|start|run ) shift || true; cmd_start "$@" ;;
    list|ls ) cmd_list ;;
    status ) cmd_status ;;
    stop|down ) shift; cmd_stop "$@" ;;
    debug ) shift; cmd_debug "$@" ;;
    exec ) shift; cmd_exec "$@" ;;
    add ) shift; cmd_add "$@" ;;
    install ) shift; cmd_install "$@" ;;
    data ) shift; cmd_data "$@" ;;
    backup ) shift; cmd_backup "$@" ;;
    logs|log ) shift; cmd_logs "$@" ;;
    base|root ) shift; cmd_base "$@" ;;
    patch ) shift; exec "$MANAGE_ROOT/patch-manager.sh" "$@" ;;   # 转发到补丁管理器
    fetch|download|dl ) shift; cmd_fetch "$@" ;;
    help|-h|--help ) cmd_help ;;
    --dry-run|-n ) cmd_start "$@" ;;
    * ) cmd_start "$@" ;;   # 其余参数一律当作 start 的目标
  esac
}
main "$@"
