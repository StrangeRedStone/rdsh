#!/usr/bin/env bash
# =============================================================================
# plugin-sync.sh —— 用户插件的一致性检查与同步（解决 L3「插件在版本间分叉」）
#
# 背景：每个版本的数据根下都有一份 plugins/（升级时由 migrate.sh 复制）。于是同一插件
#   在新旧 home 各存一份，改一处另一处不会跟着变（2026-09-17 真实升级中踩到：
#   compat_check 的修复只落在 0.1.6 那份）。本脚本给插件引入**唯一权威副本**：
#
#     权威副本（canonical）: $BASE/dsh-plugins/<插件名>/     ← 代码只此一份
#     各版本 home 里的副本  : $DSH_HOME/plugins/<插件名>/     ← 可被 --sync 覆盖
#
# 口径（重要）：
#   - 参与比对的 = 代码：package.json / lib/ / src/ 等
#   - **排除** node_modules/（那是指向具体检出的软链，天生按版本不同）
#   - **排除** contracts.json（它是"本 home 验证过哪些版本"的记录，各 home 本就不同）
#
# 用法:
#   plugin-sync.sh --check                 # 只读：列出各 home 与权威副本的差异
#   plugin-sync.sh --sync <版本|--all>     # 权威 → home（先备份被覆盖的目录）
#   plugin-sync.sh --adopt <版本>          # 反向：把某个 home 的插件提升为权威（改好之后用）
#   plugin-sync.sh --init [<版本>]         # 首次建立权威副本（默认取最新版本 home）
#   plugin-sync.sh --status                # 一览：各 home 的插件与权威的关系
#   通用选项: --dry-run / --base <目录>（覆盖 $BASE）
#
# 环境: RDSH_BASE / RDSH_MANAGE_ROOT / RDSH_DATA_ROOT / RDSH_BACKUP_ROOT / RDSH_CONFIG
# =============================================================================
set -euo pipefail

RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"
cfg_get() {
  [ -f "$RDSH_CONFIG" ] || return 0
  local v
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}

MODE=""; TARGET=""; DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --check|--status) MODE="$a" ;;
    --sync|--adopt|--init) MODE="$a" ;;
    --all) TARGET="--all" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --base) TARGET="__BASE_NEXT__" ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知选项：$a" >&2; exit 2 ;;
    *) if [ "$TARGET" = "__BASE_NEXT__" ]; then BASE_OVERRIDE="$a"; TARGET=""; else TARGET="$a"; fi ;;
  esac
done

BASE="${BASE_OVERRIDE:-$(cfg_get BASE)}"; [ -n "$BASE" ] || BASE="${RDSH_BASE:-$HOME/Mapp}"
MANAGE_ROOT="${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}"; [ -n "$MANAGE_ROOT" ] || MANAGE_ROOT="$BASE/dsh"
DATA_ROOT="${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}";       [ -n "$DATA_ROOT" ]   || DATA_ROOT="$BASE/.dsh"
BACKUP_ROOT="${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}"; [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-backup"
CANON="${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}";       [ -n "$CANON" ]       || CANON="$BASE/dsh-plugins"

log()  { printf '\033[1;34m[plugins]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[plugins!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[plugins!]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
act()  { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

read_version() {
  local d="$1" v=""
  [ -f "$d/package.json" ] && v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$d/package.json" | head -1)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$d")"
}

versions() {  # 所有"有 plugins/ 的数据目录"对应的版本（**必须逐行输出**：read_version 不带换行）
  local d v
  for d in "$DATA_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/plugins" ] || continue
    v="$(read_version "$MANAGE_ROOT/$(basename "$d")" 2>/dev/null || basename "$d")"
    printf '%s\n' "$v"
  done
}
home_of() {  # <版本> → 数据目录
  local v="$1" d
  for d in "$DATA_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/plugins" ] || continue
    if [ "$(basename "$d")" = "$v" ] || [ "$(read_version "$MANAGE_ROOT/$(basename "$d")" 2>/dev/null)" = "$v" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}
plugin_names() {  # 某个 plugins 目录下的插件名（排除 . 开头与 setup.sh/README.md）
  local dir="$1" e
  [ -d "$dir" ] || return 0
  for e in "$dir"/*/; do
    [ -d "$e" ] || continue
    e="$(basename "${e%/}")"
    case "$e" in .*) continue ;; esac
    printf '%s\n' "$e"
  done
}

# 目录内最新文件的时间戳（用于"目标比权威更新"的守卫）
newest_mtime() {
  find "$1" -type f -not -path '*/node_modules/*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1
}

# 代码摘要：排除 node_modules 与 contracts.json
digest() {
  local dir="$1"
  [ -d "$dir" ] || { printf 'MISSING'; return; }
  ( cd "$dir" && find . -type f -not -path './node_modules/*' -not -name 'contracts.json' -print0 \
      | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-12 )
}
# 差异明细（同样口径）
diff_files() {
  local a="$1" b="$2"
  diff -rq --exclude=node_modules --exclude=contracts.json "$a" "$b" 2>/dev/null | sed 's/^/      /' || true
}

show_status() {
  step "权威副本：$CANON"
  if [ -d "$CANON" ]; then
    local n=0 p
    for p in $(plugin_names "$CANON"); do n=$((n+1)); printf '  - %-14s %s\n' "$p" "$(digest "$CANON/$p")"; done
    printf '  共 %s 个插件\n' "$n"
  else
    warn "权威副本还不存在（先跑 plugin-sync.sh --init）"
  fi

  step "各版本 home"
  local v h
  for v in $(versions); do
    h="$(home_of "$v")" || continue
    printf '  %-18s %s\n' "$v" "$h/plugins"
    local p
    for p in $(plugin_names "$h/plugins"); do
      if [ ! -d "$CANON/$p" ]; then printf '    %-14s ⚠️ 权威副本里没有\n' "$p"; continue; fi
      if [ "$(digest "$CANON/$p")" = "$(digest "$h/plugins/$p")" ]; then
        printf '    %-14s ✅ 一致\n' "$p"
      else
        printf '    %-14s ⚠️ 与权威不同\n' "$p"
      fi
    done
  done
  return 0
}

cmd_check() {
  [ -d "$CANON" ] || die "权威副本不存在：$CANON（先跑 --init）"
  step "一致性检查（口径：代码；排除 node_modules/ 与 contracts.json/）"
  local v h p drift=0 checked=0 homes=0
  for v in $(versions); do
    h="$(home_of "$v")" || continue
    printf '  %s\n' "$v"; homes=$((homes+1))
    for p in $(plugin_names "$h/plugins"); do
      checked=$((checked+1))
      if [ ! -d "$CANON/$p" ]; then warn "    $p：权威副本里没有（本 home 独有）"; drift=$((drift+1)); continue; fi
      if [ "$(digest "$CANON/$p")" = "$(digest "$h/plugins/$p")" ]; then
        printf '    %-14s ✅\n' "$p"
      else
        # 用 LC_ALL=C 让 diff 输出可机器判读；三类严格区分（多出文件不算"不一致"）
        local d content extras missingFiles
        d="$(LC_ALL=C diff -rq --exclude=node_modules --exclude=contracts.json "$CANON/$p" "$h/plugins/$p" 2>/dev/null || true)"
        content=$(printf '%s\n' "$d" | grep -c '^Files ' || true)
        extras=$(printf '%s\n' "$d" | grep -c "^Only in $h/plugins/$p" || true)
        missingFiles=$(printf '%s\n' "$d" | grep -c "^Only in $CANON/$p" || true)
        if [ "${content:-0}" -gt 0 ] || [ "${missingFiles:-0}" -gt 0 ]; then
          printf '    %-14s ⚠️ 不一致（内容不同 %s 个文件／目标缺 %s 个）：\n' "$p" "${content:-0}" "${missingFiles:-0}"
          printf '%s\n' "$d" | grep -E '^Files |^Only in '"$CANON/$p" | sed 's/^/      /'
          drift=$((drift+1))
        else
          printf '    %-14s ✅ 代码一致（目标多出 %s 个历史残留文件，未删）\n' "$p" "${extras:-0}"
        fi
        if [ "${extras:-0}" -gt 0 ] && [ "${content:-0}" -gt 0 ]; then
          printf '       ℹ️ 另有 %s 个目标独有文件（保留，不删）：\n' "$extras"
          printf '%s\n' "$d" | grep "^Only in $h/plugins/$p" | sed 's/^/        /'
        fi
      fi
    done
  done
  # 反向：权威里有、某 home 没有
  local missing=""
  for p in $(plugin_names "$CANON"); do
    for v in $(versions); do
      h="$(home_of "$v")" || continue
      [ -d "$h/plugins/$p" ] || missing="$missing $v/$p"
    done
  done
  [ -n "$missing" ] && warn "以下 home 缺插件（较新版本才有的；回退用的旧 home 通常**不需要**补）：$missing"
  echo
  log "共检查 $checked 个插件副本（$homes 个 home）"
  if [ "$checked" = "0" ]; then
    warn '⚠️ 一个对象都没检查到 —— 这通常意味着版本识别或目录结构不对，**不能当作通过**'
    return 0
  fi
  if [ "$drift" = "0" ]; then log '结论：✅ 各 home 与权威副本一致'
  else log "结论：⚠️ $drift 处不一致（用 --sync <版本> 或 --adopt <版本> 处理）"; fi
  return 0
}

cmd_sync() {
  [ -d "$CANON" ] || die "权威副本不存在：$CANON（先跑 --init）"
  [ -n "$TARGET" ] || die '用法：plugin-sync.sh --sync <版本|--all>'
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local list=()
  if [ "$TARGET" = "--all" ]; then
    local v; for v in $(versions); do list+=("$v"); done
  else
    list=("$TARGET")
  fi
  step "权威 → home（先备份被覆盖的插件目录）"
  local v h p dst bak
  for v in "${list[@]}"; do
    h="$(home_of "$v")" || die "找不到该版本的数据目录：$v"
    printf '  %s（%s）\n' "$v" "$h"
    for p in $(plugin_names "$CANON"); do
      [ -d "$CANON/$p" ] || continue
      dst="$h/plugins/$p"; bak="$BACKUP_ROOT/plugin-sync-$ts/$v/$p"
      if [ -d "$dst" ] && [ "$(digest "$CANON/$p")" = "$(digest "$dst")" ]; then printf '    %-14s = 已一致\n' "$p"; continue; fi
      # 守卫：目标里有比权威副本更新的文件（常见于"在某个 home 里直接改好并部署"）→ 默认不覆盖
      if [ -d "$dst" ] && [ "$FORCE" != "1" ]; then
        t_new="$(newest_mtime "$dst")"; c_new="$(newest_mtime "$CANON/$p")"
        if [ -n "$t_new" ] && [ -n "$c_new" ] && awk -v a="$t_new" -v b="$c_new" 'BEGIN{exit !(a>b)}'; then
          warn "    $p：目标比权威副本更新（$(date -d "@${t_new%.*}" '+%m-%d %H:%M') > $(date -d "@${c_new%.*}" '+%m-%d %H:%M')）—— 跳过"
          warn "         若那份才是最新的：plugin-sync.sh --adopt $v（反向提升）；确实要覆盖：--force"
          continue
        fi
      fi
      act "同步 $p → $dst（旧副本备份到 $bak）"
      [ "$DRY" = "1" ] && continue
      mkdir -p "$(dirname "$bak")"
      [ -d "$dst" ] && cp -a "$dst" "$bak"
      mkdir -p "$dst"
      cp -a "$CANON/$p/." "$dst/"          # 覆盖同名文件；不动 node_modules（权威里没有它）
      printf '    %-14s ✅ 已同步（校验和 %s）\n' "$p" "$(digest "$dst")"
    done
  done
  [ "$DRY" = "1" ] || log "备份根：$BACKUP_ROOT/plugin-sync-$ts"
}

cmd_adopt() {  # 把某个 home 的插件提升为权威
  [ -n "$TARGET" ] || die '用法：plugin-sync.sh --adopt <版本>'
  local h; h="$(home_of "$TARGET")" || die "找不到该版本的数据目录：$TARGET"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  step "home → 权威（来源：$h/plugins）"
  [ -d "$CANON" ] && { act "备份现有权威副本到 $BACKUP_ROOT/plugin-sync-$ts/canonical"; [ "$DRY" = "1" ] || { mkdir -p "$BACKUP_ROOT/plugin-sync-$ts"; cp -a "$CANON" "$BACKUP_ROOT/plugin-sync-$ts/canonical"; }; }
  local p
  for p in $(plugin_names "$h/plugins"); do
    act "adopt $p"
    [ "$DRY" = "1" ] && continue
    mkdir -p "$CANON/$p"
    ( cd "$h/plugins/$p" && find . -type f -not -path './node_modules/*' -not -name 'contracts.json' -print0 \
        | xargs -0 -I{} cp -a --parents {} "$CANON/$p/" )
    printf '    %-14s ✅（校验和 %s）\n' "$p" "$(digest "$CANON/$p")"
  done
  log '权威副本已更新。其它 home 可用 --check 看差异、--sync 跟上。'
}

cmd_init() {
  local src_v="${TARGET:-}" h
  if [ -n "$src_v" ]; then h="$(home_of "$src_v")" || die "找不到该版本的数据目录：$src_v"
  else
    # 默认取"看起来最新"的一个：数据目录 mtime 最新
    local best="" d
    for d in "$DATA_ROOT"/*/; do d="${d%/}"; [ -d "$d/plugins" ] || continue; if [ -z "$best" ] || [ "$d" -nt "$best" ]; then best="$d"; fi; done
    [ -n "$best" ] || die "在 $DATA_ROOT 下找不到任何带 plugins/ 的数据目录"
    h="$best"
  fi
  step "建立权威副本：$h/plugins → $CANON"
  [ -e "$CANON" ] && die "权威副本已存在：$CANON（如要重建，先移走它；或用 --adopt 覆盖）"
  local p
  for p in $(plugin_names "$h/plugins"); do
    act "init $p"
    [ "$DRY" = "1" ] && continue
    mkdir -p "$CANON/$p"
    ( cd "$h/plugins/$p" && find . -type f -not -path './node_modules/*' -not -name 'contracts.json' -print0 \
        | xargs -0 -I{} cp -a --parents {} "$CANON/$p/" )
    printf '    %-14s ✅\n' "$p"
  done
  log "权威副本就绪（不含 node_modules / contracts.json）。下一步：plugin-sync.sh --check"
}

case "$MODE" in
  --status|"") show_status ;;
  --check) cmd_check ;;
  --sync) cmd_sync ;;
  --adopt) cmd_adopt ;;
  --init) cmd_init ;;
  *) die "未知模式：$MODE" ;;
esac
