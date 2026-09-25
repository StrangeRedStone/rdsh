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
#   映射文件 : $BASE/dsh/.map                   （可选，可手改）
#       行格式 dir|<检出目录名>|<数据目录>     —— 该检出的数据目录改指（如未迁移的 rc.2）
#               ext|<绝对路径>|<数据目录>      —— 登记一个"本体不动、仅数据隔离"的外部检出
#   相关工具 : migrate.sh（同目录）             —— 跨版本迁移器：备份 + 建链 + 探针 + 回退基线
#              reindex-workspaces.sh（同目录） —— 重建工作区归属（手拷会话后显示「未分组」时用）
#
# 用法（首个参数为子命令；不写 = start）：
#   rdsh                                  # 启动：列表菜单（回车=默认[最新]，序号/版本/项目名/路径）
#   rdsh start [版本|序号|项目名|路径]     # 启动指定项（--dry-run 预览；--no-log 关启动日志）
#   rdsh add <检出路径> [--mode iso|link|body]
#                                         # 手动把检出纳入管理；同 start <新路径> 的询问
#   rdsh list                             # 列版本（序号/检出状态/数据目录）
#   rdsh status                           # 运行实例 + 数据总览
#   rdsh install [版本|序号|项目名|路径]   # pnpm install + build + 打标
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
AUTO_INSTALL="${RDSH_AUTO_INSTALL:-1}"    # 1=启动时检出缺依赖自动安装；0=只提示
REMOTE_URL="${RDSH_REMOTE:-https://github.com/deepseek-ai/deepseek-harness.git}"
TAG_PREFIX="${RDSH_TAG_PREFIX:-dsh-v}"    # 远端 tag 命名：dsh-v<版本>

log()  { printf '\033[1;34m[rdsh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rdsh!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[rdsh!]\033[0m %s\n' "$*" >&2; exit 1; }
has_tty() { [ -t 0 ] || [ "${DSH_MENU:-0}" = "1" ]; }

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

# ---- 启动 ----
port_busy() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -q '127.0.0.1:3080$'
}
port_owner_cwd() {  # 正在监听 3080 的进程工作目录（若有）；本函数恒返回 0
  command -v ss >/dev/null 2>&1 || return 0
  local line pid
  line=$(ss -ltnp 2>/dev/null | awk '/127.0.0.1:3080/{print; exit}')
  [ -n "$line" ] || return 0
  pid=$(printf '%s' "$line" | sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -1)
  if [ -n "$pid" ] && [ -d "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd"
  fi
  return 0
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
  local entry="$1" dry="$2" ver dir data
  ver=$(entry_field "$entry" 1); dir=$(entry_field "$entry" 2); data=$(entry_field "$entry" 4)
  log "启动版本: $ver"
  log "检出目录: $dir"
  if [ "$dry" = "1" ]; then echo "DSH_HOME  : $data"; return 0; fi
  if port_busy; then
    local owner; owner=$(port_owner_cwd)
    die "127.0.0.1:3080 已被占用（运行中检出：${owner:-未知}）。请先停掉旧实例再启动。"
  fi
  ensure_data_home "$data"
  ensure_built "$dir"
  cd "$dir" || die "无法进入 $dir"
  command -v pnpm >/dev/null || die '未找到 pnpm'
  # 启动输出同时落盘：事后可检索插件/技能监听器的报错（此前这类报错只在终端里，无法复查）
  if [ "$WEB_LOG" = "1" ]; then
    local logfile="$LOG_DIR/web-$ver.log"
    mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR" 2>/dev/null || true
    ( umask 077; [ -f "$logfile" ] || : > "$logfile" )   # 文件权限 600（含访问 token）
    log "启动日志: $logfile（含访问 token，勿外传；rdsh start --no-log 可关）"
    exec > >(tee -a "$logfile") 2>&1
  fi
  log '启动 dsh web（Ctrl+C 退出）...'
  exec pnpm dsh web
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

# ---- 子命令实现 ----
cmd_start() {
  local dry=0 target="" a
  for a in "$@"; do
    case "$a" in --dry-run|-n ) dry=1 ;; --no-log ) WEB_LOG=0 ;; --log ) WEB_LOG=1 ;; * ) target="$a" ;; esac
  done
  if [ "$dry" = "0" ] && port_busy; then
    local owner; owner=$(port_owner_cwd)
    die "127.0.0.1:3080 已被占用（运行中检出：${owner:-未知}）。请先停掉旧实例再启动。"
  fi
  local entry="" mode=""
  if [ -z "$target" ]; then
    if has_tty; then
      list_entries >&2
      local defver; defver=$(entry_field "$(pick_default)" 1)
      printf '\n直接回车 = 默认 [1] %s；输入 序号/版本/项目名/路径 后回车启动；q 退出。\n' "$defver" >&2
      printf '选择> ' >&2
      local sel=""
      read -r sel || true
      sel=$(clean_input "$sel")
      printf '\n' >&2
      case "$sel" in
        "" ) entry=$(pick_default) ;;
        q|Q ) echo '已取消'; exit 0 ;;
        * ) entry=$(resolve_target "$sel") ;;
      esac
    else
      entry=$(pick_default)
    fi
  else
    entry=$(resolve_target "$target")
  fi
  if [[ "$entry" == UNMANAGED:* ]]; then
    local upath="${entry#UNMANAGED:}"
    local owner; owner=$(port_owner_cwd)
    if [ -n "$owner" ] && [ "$(readlink -f "$owner")" = "$upath" ]; then
      die "该检出正在运行中，不能移动/重新登记。请先停掉它。"
    fi
    if has_tty; then
      mode=$(adopt_prompt "$upath")
    else
      log "非交互环境：按“仅数据隔离”登记 $upath"
      mode=link
    fi
    entry=$(adopt_and_entry "$upath" "$mode")
  fi
  launch_entry "$entry" "$dry"
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
  if port_busy; then
    echo '  端口 127.0.0.1:3080：被占用'
    local pid cwd
    pid=$(ss -ltnp 2>/dev/null | awk '/127.0.0.1:3080/{gsub(/pid=/,"",$NF); gsub(/,.*/,"",$NF); print $NF; exit}')
    if [ -n "$pid" ] && [ -d "/proc/$pid/cwd" ]; then
      cwd=$(readlink "/proc/$pid/cwd")
      printf '  运行检出: %s\n' "$cwd"
      printf '  DSH_HOME: %s\n' "$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^DSH_HOME=' || echo '(默认 ~/.dsh)')"
    fi
  else
    echo '  端口 127.0.0.1:3080：空闲'
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
  local f="$LOG_DIR/web-$ver.log"
  [ -f "$f" ] || die "没有 $f（该版本还没启动过？用 rdsh logs --clean 清理全部）"

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
