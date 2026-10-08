#!/usr/bin/env bash
# =============================================================================
# doctor.sh —— rdsh 一键只读体检（B2）
#
# 定位：**验证引擎**。restore / retire / migrate 都调它，而不是各自再写一套半吊子自检
#   （2026-09-26 的遗留教训：`rdsh stop` 与 `rdsh-restart.sh` 的归属校验就是两处实现，会漂移）。
#
# 铁律（P1）：
#   1) **全程只读** —— 不建目录、不写文件、不发信号；
#   2) **必须报出"检查了几个对象"**，且总数为 0 时报 error（不许"零检查却报全绿"）；
#   3) 退出码 = 最高严重度：0 = 无发现 / 1 = 有 warn / 2 = 有 error。
#
# 用法:
#   doctor.sh [--only <维度,…>] [--json] [--quiet]
#   维度: entries(检出) homes(数据) links(软链) plugins(插件) state(账本)
#         instances(实例) logs(日志) disk(磁盘) config(配置)
#
# 环境覆盖（默认与 Rdsh.sh 同一套规则）：RDSH_BASE / RDSH_CONFIG / RDSH_MANAGE_ROOT /
#   RDSH_DATA_ROOT / RDSH_BACKUP_ROOT / RDSH_SHARED_HOME / RDSH_STATE_ROOT / RDSH_RUN_DIR /
#   RDSH_DEBUG_ROOT / RDSH_PLUGIN_ROOT / DSH_LOG_DIR
# =============================================================================
set -uo pipefail

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
  if [ ! -f "$MANAGE_ROOT/doctor.sh" ] && [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    _self="$(dirname "$(readlink -f "$0")")"
    [ -f "$_self/doctor.sh" ] && MANAGE_ROOT="$_self"
  fi
fi
DATA_ROOT="$(expand_tilde "${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}")";     [ -n "$DATA_ROOT" ]   || DATA_ROOT="$BASE/.dsh"
BACKUP_ROOT="$(expand_tilde "${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}")"; [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-backup"
SHARED_ROOT="$(expand_tilde "${RDSH_SHARED_HOME:-$(cfg_get SHARED_ROOT)}")"; [ -n "$SHARED_ROOT" ] || SHARED_ROOT="$BASE/.dsh-shared"
PLUGIN_ROOT="$(expand_tilde "${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}")";  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$BASE/dsh-plugins"
LOG_DIR="$(expand_tilde "${DSH_LOG_DIR:-$(cfg_get LOG_DIR)}")";           [ -n "$LOG_DIR" ]     || LOG_DIR="$BASE/.dsh-logs"
STATE_ROOT="$(expand_tilde "${RDSH_STATE_ROOT:-$(cfg_get STATE_ROOT)}")"; [ -n "$STATE_ROOT" ] || STATE_ROOT="$BASE/.dsh-suite/state"
RUN_DIR="$(expand_tilde "${RDSH_RUN_DIR:-$(cfg_get RUN_DIR)}")";          [ -n "$RUN_DIR" ]     || RUN_DIR="$BASE/.dsh-suite/run"
DEBUG_ROOT="$(expand_tilde "${RDSH_DEBUG_ROOT:-$(cfg_get DEBUG_ROOT)}")"; [ -n "$DEBUG_ROOT" ] || DEBUG_ROOT="$BASE/.dsh-suite/debug"
STATE_KV="$STATE_ROOT/versions.kv"
STATE_JOURNAL="$STATE_ROOT/journal.log"
BASELINE_MD="$BACKUP_ROOT/回退基线.md"
INSTANCES_DIR="$RUN_DIR/instances"

MODE_TEXT=1; ONLY=""; QUIET=0; FIX_LINKS=0; APPLY=0
# 入口链检查的"根"：默认 $HOME；冒烟用 RDSH_ENTRY_ROOT 指到临时目录（**绝不为测试动真机入口**）
ENTRY_ROOT="${RDSH_ENTRY_ROOT:-$HOME}"
ENTRY_BIN_DIR="${RDSH_ENTRY_BIN_DIR:-$ENTRY_ROOT/.local/bin}"
ENTRY_DESKTOP="${RDSH_ENTRY_DESKTOP:-$ENTRY_ROOT/.local/share/applications/dsh.desktop}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE_TEXT=0 ;;
    --only) shift; ONLY="${1:-}" ;;
    --fix-links) FIX_LINKS=1 ;;
    --apply) APPLY=1 ;;
    --only=*) ONLY="${1#--only=}" ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
    *) echo "[doctor!] 未知参数：$1（--help 看用法）" >&2; exit 1 ;;
  esac
  shift || true
done

# ---------------- 发现收集 ----------------
LEVELS=(); DIMS=(); MSGS=(); DIM_LINES=()
N_ERROR=0; N_WARN=0; N_INFO=0; N_OBJECTS=0

esc() { printf '%s' "$1" | tr '\n\t' '  ' | tr -d '"\\'; }

find_f() {  # <级别> <维度> <消息>
  local lv="$1" dim="$2"; shift 2
  local msg="$*"
  LEVELS+=("$lv"); DIMS+=("$dim"); MSGS+=("$msg")
  case "$lv" in
    error) N_ERROR=$((N_ERROR+1)) ;;
    warn)  N_WARN=$((N_WARN+1)) ;;
    info)  N_INFO=$((N_INFO+1)) ;;
  esac
}

want() {  # <维度> → 0/1（--only 过滤）
  [ -z "$ONLY" ] && return 0
  local o
  IFS=',' read -ra _o <<< "$ONLY"
  for o in "${_o[@]}"; do
    [ -n "$o" ] || continue
    case "$1" in *"$o"*) return 0 ;; esac
  done
  return 1
}
say() { [ "$MODE_TEXT" = "1" ] || return 0; [ "$QUIET" = "1" ] && return 0; printf '  %s\n' "$*"; }

read_version() {
  local dir="$1" v=""
  [ -f "$dir/package.json" ] && v=$(grep -m1 '"version"' "$dir/package.json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$dir")"
}

# 条目：version|dir|data
ENTRIES=()
load_entries() {
  ENTRIES=()
  local d base ver data
  if [ -f "$MANAGE_ROOT/.map" ]; then
    while IFS='|' read -r kind k v || [ -n "${kind:-}" ]; do
      [ -n "${kind:-}" ] || continue
      case "$kind" in
        dir) : ;;
        ext) [ -d "$k" ] && ENTRIES+=("$(read_version "$k")|$k|${v:-$DATA_ROOT/$(read_version "$k")}") ;;
      esac
    done < "$MANAGE_ROOT/.map"
  fi
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    base=$(basename "${d%/}")
    [ -f "$d/package.json" ] || continue
    ver=$(read_version "${d%/}")
    data="$DATA_ROOT/$ver"
    # .map 的 dir 行可把某检出的数据改指别处
    if [ -f "$MANAGE_ROOT/.map" ]; then
      row="$(awk -F'|' -v k="$base" '$1=="dir" && $2==k { print $3; exit }' "$MANAGE_ROOT/.map" 2>/dev/null || true)"
      [ -n "$row" ] && data="$row"
    fi
    ENTRIES+=("$ver|${d%/}|$data")
  done
}
entry_ver()  { printf '%s' "${1%%|*}"; }
entry_dir()  { local r="$1"; r="${r#*|}"; printf '%s' "${r%%|*}"; }
entry_data() { printf '%s' "${1##*|}"; }

# ---------------- 1. 检出 ----------------
dim_entries() {
  say ''
  say '== 1/10 检出（版本 / 安装状态 / .installed 回声）=='
  load_entries
  local n="${#ENTRIES[@]}"
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("检出 $n")
  if [ "$n" = "0" ]; then
    find_f error entries "MANAGE_ROOT 下没有任何检出（$MANAGE_ROOT）"
    say '  [error] 没有任何检出'
    return
  fi
  find_f ok entries "$n 个检出"
  say "  [ok]    $n 个检出"
  local e dir nm ver
  for e in "${ENTRIES[@]}"; do
    dir="$(entry_dir "$e")"; nm="$(basename "$dir")"; ver="$(entry_ver "$e")"
    if [ ! -d "$dir/node_modules" ]; then
      find_f warn entries "$nm：缺 node_modules（未安装）"; say "  [warn]  $nm：缺 node_modules"
    fi
    if [ ! -f "$dir/.installed" ]; then
      find_f warn entries "$nm：缺 .installed"; say "  [warn]  $nm：缺 .installed"
    elif ! grep -q '^key=' "$dir/.installed" 2>/dev/null; then
      find_f info entries "$nm：.installed 是旧式空文件（跑 rdsh state --init 升级为 KEY=VALUE 回声）"
      say "  [info]  $nm：.installed 还是旧式空文件"
    fi
    if [ -d "$dir/.git" ] && ! grep -qxF '.installed' "$dir/.git/info/exclude" 2>/dev/null; then
      find_f warn entries "$nm：.installed 未进 .git/info/exclude（会以 ?? 出现在 git status）"
      say "  [warn]  $nm：.installed 未进 .git/info/exclude"
    fi
  done
  # 同版本多份（B7）：数据 home 撞车是**真问题**（会互相写 workspace.json/settings）
  local v dirs e dh dupe_v
  # 注意：把 entry_ver 放进循环时必须**自己补换行** —— 它内部是 printf '%s'（无换行），
  # 直接循环会把所有版本号拼成一行，uniq -d 永远为空（这个 bug 让"同版本多份"检查静默失效）
  dupe_v="$(for e in "${ENTRIES[@]}"; do printf '%s\n' "$(entry_ver "$e")"; done | sort | uniq -d)"
  if [ -n "$dupe_v" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      dirs=""
      for e in "${ENTRIES[@]}"; do [ "$(entry_ver "$e")" = "$v" ] && dirs="$dirs $(entry_dir "$e")"; done
      find_f warn entries "同版本多份检出：$v →$dirs（各有次号与独立数据 home 才安全；跑 rdsh install / state --init 分配次号）"
      say "  [warn]  同版本多份：$v"
    done <<< "$dupe_v"
    # 数据 home 撞车检查
    local -a homes=()
    for e in "${ENTRIES[@]}"; do homes+=("$(entry_data "$e")"); done
    dh="$(printf '%s\n' "${homes[@]}" | sort | uniq -d)"
    [ -n "$dh" ] && { find_f error entries "多份检出共用一个数据 home：$dh（会互相写 workspace.json/settings）"; say "  [error] 数据 home 撞车：$dh"; }
  fi
}

# 账本列号：**从表头解析**，不写死 —— 字段顺序变了 doctor 也不该跟着错
kv_col() {  # <字段名> → 列号（解析不到返回 1）
  local want="$1" hdr n f
  [ -f "$STATE_KV" ] || return 1
  hdr="$(sed -nE 's/^# 字段:[[:space:]]*(.*)$/\1/p' "$STATE_KV" | head -1)"
  if [ -n "$hdr" ]; then
    n="$(awk -F'|' -v w="$want" '{for(i=1;i<=NF;i++) if($i==w){print i; exit}}' <<<"$hdr")"
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  fi
  # 表头缺这个字段（老 kv）→ 用内置字段顺序兜底（越界只会取到空值，不会取错）
  n=1
  for f in key version role role_set_at installed_at source commit built_at migrated_from baseline_for dir data note settings settings_sha; do
    [ "$f" = "$want" ] && { printf '%s' "$n"; return 0; }
    n=$((n+1))
  done
  return 1
}
kv_get() {  # <对象键> <字段> → 值
  # 关键：列号为空时**必须直接返回空** —— `awk -v c="" ... print $c` 里 $c 会退化成 $0，
  # 把整行当成字段值（B8 实测踩到：老表头没有 settings 字段 → "settings 文件丢了" 误报）
  local col; col="$(kv_col "$2")" || return 0
  [ -n "$col" ] || return 0
  awk -F'|' -v k="$1" -v c="$col" '$1==k && !/^#/{print $c; exit}' "$STATE_KV"
}
kv_by_dir() {  # <检出目录> → 对象键
  local col; col="$(kv_col dir)" || return 0
  awk -F'|' -v d="$1" -v c="$col" '$c==d && !/^#/{print $1; exit}' "$STATE_KV"
}

# ---------------- 2. 数据 home ----------------
dim_homes() {
  say ''
  say '== 2/10 数据 home（存在 / 权限 / 体积）=='
  local e data n=0 used
  for e in "${ENTRIES[@]:-}"; do
    [ -n "$e" ] || continue
    data="$(entry_data "$e")"; n=$((n+1))
    if [ ! -d "$data" ]; then
      find_f warn homes "$(entry_ver "$e")：数据目录不存在（$data）"; say "  [warn]  $(entry_ver "$e")：数据目录不存在"
      continue
    fi
    local perm; perm="$(stat -c '%a' "$data" 2>/dev/null || echo '?')"
    [ "$perm" != "700" ] && { find_f info homes "$(entry_ver "$e")：数据目录权限 $perm（惯例 700）"; say "  [info]  $(entry_ver "$e")：权限 $perm"; }
    if [ -z "$(ls -A "$data" 2>/dev/null)" ]; then
      find_f info homes "$(entry_ver "$e")：数据目录为空（首启会自动初始化）"
    fi
  done
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("数据 home $n")
  say "  [ok]    $n 个数据目录已核对"
}

# ---------------- 3. 软链完整性（核心：09-19 事故就是这里） ----------------
fix_links() {  # 断链分类 + 重指（默认 dry-run；--apply 才动；改前写备份清单）
  local -a brokens=()
  local e data b nscan=0
  for e in "${ENTRIES[@]:-}"; do
    [ -n "$e" ] || continue
    data="$(entry_data "$e")"; [ -d "$data" ] || continue
    nscan=$((nscan + $(find "$data" -type l 2>/dev/null | wc -l)))
    while IFS= read -r b; do [ -n "$b" ] && brokens+=("$b"); done < <(find "$data" -xtype l 2>/dev/null || true)
  done
  # 这一维没走普通维度循环 → 自己把"检查了几个对象"计上，否则会撞"零对象=error"守卫（误报）
  N_OBJECTS=$((N_OBJECTS+nscan)); DIM_LINES+=("软链 $nscan（断 ${#brokens[@]}）")
  say ''
  say "== 断链修复（$(printf '%s' "${#brokens[@]}") 条；$([ "$APPLY" = "1" ] && echo '--apply 执行' || echo 'dry-run')）=="
  if [ "${#brokens[@]}" = "0" ]; then say '  [ok]    没有断链，无需修'; return 0; fi
  local bk="" n_fix=0 n_own=0 n_sib=0 n_unknown=0
  if [ "$APPLY" = "1" ]; then
    bk="$BACKUP_ROOT/links-fix-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$bk"
    { echo '# link|old_target|new_target'; } > "$bk/links.kv"
  fi
  # 每个 home 对应的检出（用于"改指自己的检出"这一优先候选）
  local home_ck=""
  for b in "${brokens[@]}"; do
    local t rel ck home cand own sib
    t="$(readlink "$b" 2>/dev/null || true)"
    [ -n "$t" ] || continue
    home="${b#"$DATA_ROOT"/}"; home="${DATA_ROOT}/${home%%/*}"
    ck=""; for e in "${ENTRIES[@]:-}"; do [ "$(entry_data "$e")" = "$home" ] && ck="$(entry_dir "$e")"; done
    own=""; sib=""
    if [ -n "$ck" ]; then
      # 候选①：把"检出根之后的那段相对路径"挂到本 home **自己的**检出上（语义最正确）
      local rest="${t#*/dsh/*/}"                    # node_modules/.pnpm/node_modules/<pkg>
      if [ "$rest" != "$t" ] && [ -n "$rest" ] && [ -e "$ck/$rest" ]; then own="$ck/$rest"; fi
      # 候选②：目标里那个检出目录已不存在 → 在它的兄弟目录里找同一相对路径
      local miss="${t%%/node_modules/*}"            # …/dsh/<旧检出名>
      if [ -n "$miss" ] && [ "$miss" != "$t" ] && [ ! -e "$miss" ]; then
        local parent oldbn cand2 rest2
        parent="$(dirname "$miss")"; oldbn="$(basename "$miss")"; rest2="${t#"$miss"/}"
        for cand2 in "$parent"/*/; do
          [ -d "$cand2" ] || continue
          [ "$(basename "$cand2")" = "$oldbn" ] && continue
          if [ -e "${cand2%/}/$rest2" ]; then sib="${cand2%/}/$rest2"; break; fi
        done
      fi
    fi
    cand="${own:-$sib}"
    if [ -n "$cand" ]; then
      if [ "$APPLY" = "1" ]; then
        printf '%s|%s|%s\n' "$b" "$t" "$cand" >> "$bk/links.kv"
        ln -sfn "$cand" "$b" && n_fix=$((n_fix+1))
      else
        printf '  [%s] %s\n        %s\n     →  %s\n' "$([ -n "$own" ] && echo 自己检出 || echo 同版本兄弟)" "${b#"$DATA_ROOT"/}" "$t" "$cand"
        n_fix=$((n_fix+1))
      fi
      [ -n "$own" ] && n_own=$((n_own+1)) || n_sib=$((n_sib+1))
    else
      n_unknown=$((n_unknown+1))
      [ "$APPLY" != "1" ] && printf '  [无法自动判定] %s\n        → %s\n' "${b#"$DATA_ROOT"/}" "$t"
    fi
  done
  if [ "$APPLY" = "1" ]; then
    say "  [ok]    重指 $n_fix 条（自己的检出 $n_own / 同版本兄弟 $n_sib / 无法判定 $n_unknown）；备份清单：$bk/links.kv"
    say "          还原：while IFS='|' read -r l o n; do [ -n \"\${l:-}\" ] && ln -sfn \"\$o\" \"\$l\"; done < $bk/links.kv"
    find_f ok links "断链修复：重指 $n_fix 条（备份 $bk/links.kv）$([ "$n_unknown" -gt 0 ] && printf '，%s 条未能判定' "$n_unknown")"
  else
    say "  计划重指 $n_fix 条（自己的检出 $n_own / 同版本兄弟 $n_sib / 无法判定 $n_unknown）"
    say '  执行：rdsh doctor --fix-links --apply'
    find_f info links "断链可修复 $n_fix 条，未判定 $n_unknown 条（dry-run；--apply 才动）"
  fi
  return 0
}

dim_links() {
  say ''
  say '== 3/10 软链完整性（断链 / 分叉）=='
  local e data nlink=0 nbroken=0 nm b
  local -a brokens=()
  for e in "${ENTRIES[@]:-}"; do
    [ -n "$e" ] || continue
    data="$(entry_data "$e")"; nm="$(basename "$(entry_dir "$e")")"
    [ -d "$data" ] || continue
    local c; c="$(find "$data" -type l 2>/dev/null | wc -l)"
    nlink=$((nlink+c))
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      nbroken=$((nbroken+1)); brokens+=("$b")
    done < <(find "$data" -xtype l 2>/dev/null || true)
  done
  N_OBJECTS=$((N_OBJECTS+nlink)); DIM_LINES+=("软链 $nlink（断 $nbroken）")
  if [ "$nlink" = "0" ]; then
    find_f info links "所有数据 home 里一条软链都没有（按设计稳定根资产应建成软链，可能未建链）"
    say '  [info]  0 条软链（未建链？）'
  else
    say "  [ok]    扫了 $nlink 条软链"
  fi
  if [ "$nbroken" -gt 0 ]; then
    # 把 09-19 那类"插件加载链"单独点名，因为断掉会让所有插件 failed to import
    local plugbroken=0
    for b in "${brokens[@]}"; do case "$b" in *profiles/node_modules/*|*/plugins/*/node_modules/*) plugbroken=$((plugbroken+1)) ;; esac; done
    # **按 home 分组报数**（一次甩几百行路径没法用）
    local grp line
    grp="$(for b in "${brokens[@]}"; do h="${b#"$DATA_ROOT"/}"; printf '%s\n' "${DATA_ROOT}/${h%%/*}"; done | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"
    find_f error links "$nbroken 条断链（$([ "$plugbroken" -gt 0 ] && printf '其中 %s 条在插件/依赖加载链上（profiles/node_modules、plugins/*/node_modules）' "$plugbroken" || printf '无加载链')；按 home：$(printf '%s' "$grp" | sed "s|$DATA_ROOT/||g"))"
    say "  [error] $nbroken 条断链（按 home：$(printf '%s' "$grp" | sed "s|$DATA_ROOT/||g"))"
    printf '          %s\n' "${brokens[@]:0:4}"
    say '          典型原因：检出被改名/移动 → 链里的绝对路径失效（真机 2026-09-30 实例）'
    say '          修复：rdsh doctor --fix-links（先 dry-run 看分类，--apply 才改；改前自动写备份清单）'
  else
    find_f ok links "无断链"
    say '  [ok]    0 条断链'
  fi
  # 分叉：home 里是真文件、而稳定根也有同名资产 → 写进去就分叉
  local asset
  for e in "${ENTRIES[@]:-}"; do
    [ -n "$e" ] || continue
    data="$(entry_data "$e")"
    [ -d "$data" ] || continue
    for asset in skills lessons.md AGENTS.md .agent-presets facts.md backlog.md; do
      if [ -e "$data/$asset" ] && [ ! -L "$data/$asset" ] && [ -e "$SHARED_ROOT/$asset" ]; then
        find_f info links "$(basename "$(entry_dir "$e")")：$asset 是真文件（未建链到稳定根）→ 已分叉"
        say "  [info]  $(basename "$(entry_dir "$e")")：$asset 已分叉（真文件）"
      fi
    done
  done
}

# ---------------- 3.5 入口链（B11：rdsh 不总是健全） ----------------
# 回答"命令还能不能用、图标还能不能点"：rdsh 是**便利层**，它断了用户就该有降级路径。
dim_entry() {
  say ''
  say '== 3.5/10 入口链（rdsh 命令 / 桌面图标 / PATH）=='
  local n=0 bad=0
  # ① 规范入口路径（**只查这一处**；用 command -v 会被"真机那套"遮住，隔离夹具就测不出来）
  local l0="$ENTRY_BIN_DIR/rdsh"
  n=$((n+1))
  if [ -L "$l0" ] || [ -e "$l0" ]; then
    if [ -e "$l0" ] && [ -x "$l0" ]; then
      say "  [ok]    入口：$l0 → $(readlink "$l0" 2>/dev/null || echo '（实文件）')"
    else
      find_f error entry "入口 $l0 不可用（断链或不可执行）→ 修复：ln -sfn $MANAGE_ROOT/Rdsh.sh $l0"
      say "  [error] 入口不可用：$l0"; bad=1
    fi
  else
    find_f warn entry "入口不存在：$l0 → 修复：bash $MANAGE_ROOT/bootstrap.sh --base $BASE（或 ln -sfn $MANAGE_ROOT/Rdsh.sh $l0）"
    say "  [warn]  入口不存在：$l0"; bad=1
  fi
  # ①b PATH 实际解析到哪个（信息级：可能有别的同名命令抢先）
  local which; which="$(PATH="$ENTRY_BIN_DIR:$PATH" command -v rdsh 2>/dev/null || true)"
  if [ -n "$which" ]; then
    if [ "$which" = "$l0" ]; then say "  [info]  PATH 解析：$which"
    else find_f info entry "PATH 里的 rdsh 不是规范入口：$which（期望 $l0）"; say "  [info]  PATH 解析到别处：$which"; fi
  else
    find_f warn entry "PATH 里找不到 rdsh（$ENTRY_BIN_DIR 也不在 PATH？）"
    say "  [warn]  PATH 里找不到 rdsh"
  fi
  # ② <检出>/rdsh → Rdsh.sh
  local l1="$MANAGE_ROOT/rdsh"
  if [ -L "$l1" ] || [ -e "$l1" ]; then
    if [ -e "$l1" ]; then say "  [ok]    $l1 → 可解析"; else
      find_f warn entry "$l1 是断链 → 修复：ln -sfn $MANAGE_ROOT/Rdsh.sh $l1"
      say "  [warn]  $l1 是断链"; bad=1
    fi
    n=$((n+1))
  else
    find_f info entry "$l1 不存在（非必需；bootstrap 会建）"
    say "  [info]  $l1 不存在"
  fi
  # ③ 桌面图标的 Exec
  if [ -f "$ENTRY_DESKTOP" ]; then
    local ex; ex="$(sed -nE 's/^Exec=(.*)$/\1/p' "$ENTRY_DESKTOP" | head -1 | awk '{print $1}')"
    n=$((n+1))
    if [ -n "$ex" ]; then
      local exp; exp="$(expand_tilde "$ex")"
      if [ -x "$exp" ]; then say "  [ok]    桌面图标 Exec 可用：$ex"
      else
        find_f error entry "桌面图标 $(basename "$ENTRY_DESKTOP") 的 Exec 指向不可执行/不存在的路径：$ex → 修复：重建入口软链后 update-desktop-database ~/.local/share/applications"
        say "  [error] 桌面图标 Exec 失效：$ex"; bad=1
      fi
    else
      find_f info entry "桌面图标没有 Exec 行（$ENTRY_DESKTOP）"
    fi
  else
    say "  [info]  无桌面图标文件（$ENTRY_DESKTOP；非必需）"
  fi
  # ④ 入口目录在 PATH 里吗
  case ":$PATH:" in
    *":$ENTRY_BIN_DIR:"*) say "  [ok]    入口目录在 PATH 里：$ENTRY_BIN_DIR" ;;
    *) find_f warn entry "入口目录不在 PATH 里：$ENTRY_BIN_DIR → 加一行 export PATH=\"$ENTRY_BIN_DIR:\$PATH\""
       say "  [warn]  入口目录不在 PATH：$ENTRY_BIN_DIR"; bad=1 ;;
  esac
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("入口链 $n（异常 $bad）")
  if [ "$n" = "0" ]; then
    find_f error entry "入口链一点都没查到（ENTRY_ROOT=$ENTRY_ROOT）"
  fi
  # 降级路径一句话：随时可脱离 rdsh 启动
  say "  [info]  降级启动（不依赖 rdsh）：cd <检出> && DSH_HOME=<该版本数据 home> pnpm dsh web --port 3080"
  say "  [info]  应急卡：$MANAGE_ROOT/应急启动.md（重装 rdsh：bash $MANAGE_ROOT/bootstrap.sh --from <目录|tarball>）"
}

# ---------------- 4. 插件一致性 ----------------
dim_plugins() {
  say ''
  say '== 4/10 插件（权威副本 ↔ 各 home）=='
  local ncanon=0
  if [ -d "$PLUGIN_ROOT" ]; then ncanon="$(find "$PLUGIN_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"; fi
  N_OBJECTS=$((N_OBJECTS+ncanon)); DIM_LINES+=("插件权威 $ncanon")
  if [ ! -d "$PLUGIN_ROOT" ]; then
    find_f info plugins "没有插件权威副本（$PLUGIN_ROOT）"
    say '  [info]  没有插件权威副本'
    N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("插件权威 0")
    return
  fi
  say "  [ok]    权威副本 $ncanon 个"
  local sync="$MANAGE_ROOT/plugin-sync.sh" out nwarn
  if [ -f "$sync" ]; then
    local rc=0
    out="$(bash "$sync" --status 2>&1)"; rc=$?
    nwarn="$(printf '%s\n' "$out" | grep -c '⚠️' || true)"
    if [ "$rc" != 0 ]; then
      # 2026-10-08 修的**假绿**：原来只看输出里有没有 ⚠️；脚本崩溃时没有 ⚠️，计数为 0，
      # 于是被当成"各 home 与权威一致"。检查器静默失败却报绿，是最贵的一类 bug。
      find_f error plugins "plugin-sync.sh --status 异常退出（rc=$rc）→ 一致性**无法判断**，不能当作一致"
      say "  [error] plugin-sync.sh --status 退出码 $rc（输出尾部：$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140)）"
    elif [ -z "$out" ]; then
      find_f error plugins "plugin-sync.sh --status 没有任何输出 → 检查器静默失败，无法判断一致性"
      say '  [error] plugin-sync.sh --status 无输出（检查器没干活）'
    elif [ "${nwarn:-0}" -gt 0 ]; then
      find_f warn plugins "$nwarn 处 home 插件与权威副本不一致（细节：bash $MANAGE_ROOT/plugin-sync.sh --check；--sync 前先看方向守卫；有意的分叉可忽略）"
      say "  [warn]  $nwarn 处 home 插件与权威不一致"
    else
      find_f ok plugins "各 home 与权威一致"
      say '  [ok]    各 home 插件与权威一致'
    fi
  else
    find_f info plugins "找不到 plugin-sync.sh，跳过一致性比对"
  fi
}

# ---------------- 5. 状态账本 ----------------
dim_state() {
  say ''
  say '== 5/10 状态账本（唯一权威）=='
  if [ ! -f "$STATE_KV" ]; then
    find_f info state "账本未播种（跑 rdsh state --init）；角色信息不可用"
    say '  [info]  账本未播种'
    N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("账本 0（未播种）")
    return
  fi
  local n=0 k dir data role bad=0 nbase=0 jn stale=0
  jn="$(grep -c '' "$STATE_JOURNAL" 2>/dev/null || echo 0)"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    n=$((n+1))
    role="$(kv_get "$k" role)"
    dir="$(kv_get "$k" dir)"
    data="$(kv_get "$k" data)"
    case " installed current baseline retire-candidate retired " in
      *" $role "*) ;;
      *) find_f warn state "$k：角色非法「$role」"; bad=$((bad+1)) ;;
    esac
    if [ -n "$dir" ] && [ ! -d "$dir" ]; then
      find_f warn state "$k：账本里的检出不存在（$dir）"; say "  [warn]  $k：检出不存在"
    fi
    [ -n "$data" ] && [ ! -d "$data" ] && { find_f info state "$k：账本里的数据目录不存在（$data）"; }
    if [ "$role" = "baseline" ]; then
      nbase=$((nbase+1))
      if { [ -n "$dir" ] && [ ! -d "$dir" ]; } || { [ -n "$data" ] && [ ! -d "$data" ]; }; then
        find_f error state "$k 是回退基线，但它的检出或数据不完整 → 回退能力不成立"
      fi
    fi
    # settings.yaml（B8）：账本登记的路径与 sha 是否与磁盘一致（漂移可见）
    local sfile ssha sreg
    sfile="$(kv_get "$k" settings)"; sreg="$(kv_get "$k" settings_sha)"
    if [ -n "$sfile" ]; then
      if [ ! -f "$sfile" ]; then
        find_f warn state "$k：账本登记的 settings 不存在（$sfile）"; say "  [warn]  $k：settings 文件丢了"
      else
        ssha="$(sha256sum "$sfile" 2>/dev/null | cut -c1-8)"
        if [ -n "$sreg" ] && [ "$sreg" != "$ssha" ]; then
          find_f info state "$k：settings.yaml 与账本指纹不符（账本 $sreg → 磁盘 $ssha）—— 文件被改过或换过版本"
          say "  [info]  $k：settings 指纹漂移（$sreg → $ssha）"
        fi
      fi
    elif [ -n "$(kv_get "$k" data)" ] && [ ! -f "$(kv_get "$k" data)/settings.yaml" ]; then
      :   # 该 home 本来就没有 settings.yaml（dsh 首启才写）→ 正常，不报
    fi
    # 回声一致性：比**内容**（role/key），不比流水行号 —— 流水行号是游标，
    # 任何单对象事件都会让其它回声"落后一位"，拿它当问题是噪声（元资产陷阱）
    local echof="$dir/.installed"
    if [ -f "$echof" ] && grep -q '^key=' "$echof" 2>/dev/null; then
      local ekey erole
      ekey="$(sed -nE 's/^key=(.*)$/\1/p' "$echof" | tail -1)"
      erole="$(sed -nE 's/^role=(.*)$/\1/p' "$echof" | tail -1)"
      if [ "$ekey" != "$k" ] || [ "$erole" != "$role" ]; then
        stale=$((stale+1))
      fi
    fi
  done < <(awk -F'|' '!/^#/ && NF>0 && $1!="" {print $1}' "$STATE_KV")
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("账本对象 $n")
  say "  [ok]    账本 $n 个对象（流水 $jn 行）"
  [ "$nbase" = "0" ] && { find_f warn state "没有任何对象是 baseline → 出问题时没有明确的回退目标"; say '  [warn]  没有 baseline'; }
  [ "$stale" -gt 0 ] && { find_f info state "$stale 个检出的 .installed 回声落后于流水（跑 rdsh state sync 刷新）"; say "  [info]  $stale 个回声陈旧"; }
  if [ -f "$BASELINE_MD" ] && ! head -1 "$BASELINE_MD" | grep -q 'rdsh-generated'; then
    find_f info state "回退基线.md 不是生成物（手写遗留？跑 rdsh state --init 会留档并改为生成）"
    say '  [info]  回退基线.md 是手写文件'
  fi
}

# ---------------- 6. 实例 ----------------
dim_instances() {
  say ''
  say '== 6/10 运行实例（ss + /proc 真相层）=='
  command -v ss >/dev/null 2>&1 || { find_f info instances '没有 ss，无法探测实例'; N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("实例 n/a"); return; }
  local rows p pid dir home cmd n=0
  declare -A seen_home=()
  rows="$(ss -ltnpH 2>/dev/null | awk '{p=$4; sub(/.*:/,"",p); if (p ~ /^[0-9]+$/) print p}' | sort -un)"
  for p in $rows; do
    pid="$(ss -ltnpH "sport = :$p" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    [ -n "$pid" ] || continue
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmd" in *"bin.ts web"*|*"dsh web"*) ;; *) continue ;; esac
    dir="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    home="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -nE 's/^DSH_HOME=(.*)$/\1/p' | head -1 || true)"
    n=$((n+1))
    say "  [ok]    :$p pid=$pid ${home:-（默认 home）}"
    if [ -n "$home" ]; then
      local rh; rh="$(readlink -f "$home" 2>/dev/null || printf '%s' "$home")"
      if [ -n "${seen_home[$rh]:-}" ]; then
        find_f error instances "端口 $p 与 ${seen_home[$rh]} 共用同一个 DSH_HOME（$rh）→ 会互相写 workspace/settings"
      fi
      seen_home[$rh]="$p"
    fi
    if [ -f "$STATE_KV" ] && [ -n "$dir" ]; then
      local key; key="$(kv_by_dir "$dir")"
      [ -z "$key" ] && find_f info instances "端口 $p 的检出不在账本里（$dir）"
    fi
  done
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("实例 $n")
  say "  [ok]    在跑 $n 个实例"
  local d eid
  if [ -d "$DEBUG_ROOT" ]; then
    for d in "$DEBUG_ROOT"/*.env; do
      [ -f "$d" ] || continue
      eid="$(basename "$d" .env)"
      [ -d "$DEBUG_ROOT/$eid" ] || find_f warn instances "调试环境 $eid 有清单但 home 不存在"
    done
  fi
}

# ---------------- 7. 日志 ----------------
dim_logs() {
  say ''
  say '== 7/10 启动日志（权限 / 报错扫描）=='
  if [ ! -d "$LOG_DIR" ]; then
    find_f info logs "没有日志目录（$LOG_DIR）"; say '  [info]  无日志目录'
    N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("日志 0"); return
  fi
  local perm; perm="$(stat -c '%a' "$LOG_DIR" 2>/dev/null || echo '?')"
  [ "$perm" != "700" ] && find_f warn logs "日志目录权限 $perm（含访问 token，惯例 700）"
  local f n=0 bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    local fp; fp="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
    [ "$fp" != "600" ] && find_f info logs "$(basename "$f") 权限 $fp（惯例 600）"
    if [ "$n" -le 5 ]; then
      local c; c="$(grep -cE 'failed to import|Error:|ERROR ' "$f" 2>/dev/null || true)"
      [ "${c:-0}" -gt 0 ] && { bad=$((bad+1)); find_f warn logs "$(basename "$f")：$c 处 import/error 字样（用 rdsh logs 看，token 已打码）"; }
    fi
  done < <(ls -1t "$LOG_DIR"/web-*.log 2>/dev/null | head -5 || true)
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("日志 $n")
  say "  [ok]    扫了 $n 个日志文件（其中 $bad 个有 import/error 字样）"
}

# ---------------- 8. 磁盘 / 内存 ----------------
dim_disk() {
  say ''
  say '== 8/10 磁盘与内存余量 =='
  local dfout pct avail
  if dfout="$(df -Pk "$BASE" 2>/dev/null | tail -1)"; then
    pct="$(printf '%s' "$dfout" | awk '{gsub("%","",$5); print $5}')"
    avail="$(printf '%s' "$dfout" | awk '{printf "%.1f", $4/1048576}')"
    N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("磁盘 ${pct}% 已用")
    if [ "${pct:-0}" -ge 95 ]; then
      find_f error disk "$BASE 所在分区已用 ${pct}%（可用 ${avail}G）"
    elif [ "${pct:-0}" -ge 85 ]; then
      find_f warn disk "$BASE 所在分区已用 ${pct}%（可用 ${avail}G）"
    else
      find_f ok disk "分区已用 ${pct}%，可用 ${avail}G"
      say "  [ok]    已用 ${pct}%，可用 ${avail}G"
    fi
  fi
  if command -v free >/dev/null 2>&1; then
    local freem; freem="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
    if [ -n "${freem:-}" ]; then
      N_OBJECTS=$((N_OBJECTS+1)); DIM_LINES+=("内存可用 ${freem}MB")
      if [ "$freem" -lt 1024 ]; then
        find_f warn disk "可用内存 ${freem}MB —— 启动新实例（构建/加载）可能吃力"
      else
        say "  [ok]    内存可用 ${freem}MB"
      fi
    fi
  fi
  # 衍生物体积（B3 的 du 会细化；这里只报总量前三）
  local d sz
  for d in "$BACKUP_ROOT" "$LOG_DIR" "$DEBUG_ROOT" "$DATA_ROOT"; do
    [ -d "$d" ] || continue
    sz="$(du -sh "$d" 2>/dev/null | cut -f1 || true)"
    [ -n "$sz" ] && say "          $(printf '%-28s' "$d") $sz"
  done
}

# ---------------- 9. 配置 ----------------
dim_config() {
  say ''
  say '== 9/10 配置解析 =='
  local n=0
  [ -f "$RDSH_CONFIG" ] && { n=$((n+1)); say "  [ok]    配置文件 $RDSH_CONFIG"; } || { find_f info config "配置文件不存在（$RDSH_CONFIG，用默认值）"; say '  [info]  无配置文件'; }
  local v over=""
  for v in RDSH_BASE RDSH_MANAGE_ROOT RDSH_DATA_ROOT RDSH_BACKUP_ROOT RDSH_SHARED_HOME RDSH_STATE_ROOT RDSH_RUN_DIR RDSH_DEBUG_ROOT RDSH_PLUGIN_ROOT DSH_LOG_DIR; do
    n=$((n+1))
    [ -n "${!v:-}" ] && over="$over $v"
  done
  N_OBJECTS=$((N_OBJECTS+n)); DIM_LINES+=("配置旋钮 $n")
  if [ -n "$over" ]; then
    find_f info config "环境变量正在覆盖配置：$over（改配置文件不会生效）"
    say "  [info]  环境变量覆盖：$over"
  else
    say '  [ok]    无环境变量覆盖'
  fi
  say "  [ok]    BASE=$BASE"
}

# ---------------- 跑 ----------------
# **维度之间不许依赖副作用**：ENTRIES 在这儿统一加载一次。
# 踩过：ENTRIES 只在 dim_entries 里 load，于是 `doctor --only links` 拿到空数组 →
# "扫了 0 条软链"，全靠零对象守卫才没报成"一切正常"。
load_entries
if [ "$FIX_LINKS" = "1" ]; then
  fix_links
else
  DIMS_ALL=(entries homes links entry plugins state instances logs disk config)
  for dim in "${DIMS_ALL[@]}"; do
    want "$dim" || continue
    "dim_$dim"
  done
fi

# 零检查必须报错（路线图已知风险：不许"零检查却报全绿"）
if [ "$N_OBJECTS" = "0" ]; then
  find_f error meta "检查对象总数为 0 —— 说明什么都没查到（配置/路径不对？），拒绝报「一切正常」"
fi

# ---------------- 汇总 ----------------
EXIT=0
[ "$N_WARN" -gt 0 ] && EXIT=1
[ "$N_ERROR" -gt 0 ] && EXIT=2

if [ "$MODE_TEXT" = "1" ]; then
  echo
  echo '== 汇总 =='
  printf '  检查了：%s —— 共 %s 个对象\n' "$(IFS='、'; echo "${DIM_LINES[*]:-无}")" "$N_OBJECTS"
  printf '  error %s / warn %s / info %s\n' "$N_ERROR" "$N_WARN" "$N_INFO"
  summ_i=0
  while [ "$summ_i" -lt "${#MSGS[@]}" ]; do
    [ "${LEVELS[$summ_i]}" = "error" ] || [ "${LEVELS[$summ_i]}" = "warn" ] || { summ_i=$((summ_i+1)); continue; }
    printf '  [%s] %s\n' "${LEVELS[$summ_i]}" "${MSGS[$summ_i]}"
    summ_i=$((summ_i+1))
  done
  case "$EXIT" in
    0) echo '  结论：没有发现需要动作的问题。' ;;
    1) echo '  结论：有 warn（不阻塞）。' ;;
    2) echo '  结论：有 error，建议先处理再继续。' ;;
  esac
else
  printf '{"checked":%s,"error":%s,"warn":%s,"info":%s,"dims":[' "$N_OBJECTS" "$N_ERROR" "$N_WARN" "$N_INFO"
  first=1
  for d in "${DIM_LINES[@]}"; do
    [ "$first" = "1" ] || printf ','
    printf '"%s"' "$(esc "$d")"; first=0
  done
  printf '],"findings":['
  i=0; first=1
  while [ "$i" -lt "${#MSGS[@]}" ]; do
    [ "${LEVELS[$i]}" = "ok" ] && { i=$((i+1)); continue; }
    [ "$first" = "1" ] || printf ','
    printf '{"level":"%s","dim":"%s","msg":"%s"}' "$(esc "${LEVELS[$i]}")" "$(esc "${DIMS[$i]}")" "$(esc "${MSGS[$i]}")"
    first=0; i=$((i+1))
  done
  printf ']}\n'
fi

exit "$EXIT"
