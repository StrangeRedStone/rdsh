#!/bin/bash
# =============================================================================
# patch-manager.sh —— DSH 检出补丁管理（升级后能一条命令把改动重新打上）
#
# 背景：设置页那层改动是**打补丁进检出内置包**（用户决议 D4）。升级会换检出目录，
# 所以补丁必须能被"重放"，且**冲突时要停手**、绝不半应用把检出改坏。
#
# 补丁仓库布局（默认 $BASE/dsh-patches/，$BASE 默认 ~/Mapp）：
#   manifest.yaml          # 补丁集清单：顺序、涉及路径、基线与重建命令
#   <集名>/
#     ├── 0001-xxx.patch   # 按文件名顺序应用
#     └── README.md
#
# manifest.yaml 形状：
#   version: 1
#   sets:
#     - name: settings-plugin-prefs
#       description: 设置页「插件设置」相关改动
#       baseline: 0.1.6-alpha.1
#       paths: [packages/host/plugin-inventory, packages/client/ui-settings-plugin-inventory]
#       rebuild: ["pnpm exec tsc -b packages/host/plugin-inventory"]
#
# 用法：
#   patch-manager.sh list   [--repo R] [--patches P]
#   patch-manager.sh status [集名] [--repo R] [--patches P]
#   patch-manager.sh apply  [集名] [--repo R] [--patches P] [--dry-run] [--yes] [--no-build]
#   patch-manager.sh revert [集名] [--repo R] [--patches P] [--dry-run] [--yes]
#   patch-manager.sh export [集名] [--repo R] [--patches P] [--note 说明]
#
# 安全底线：
#   * apply/revert 前把涉及文件备份到 $BASE/.dsh-backup/patches-<时间戳>/；
#   * 任一补丁失败 → 回滚本次已应用的补丁并退出（检出保持原样）；
#   * 不删除任何绝对路径；不用 pkill/pgrep -f。
#
# 退出码：0 成功；1 参数/前置错误；2 有冲突或应用失败（检出已回滚）
# =============================================================================

set -u

SELF="$(readlink -f "$0")"
MODE="${1:-}"; shift || true

REPO=""; PATCHES=""; SET=""; DRY=0; YES=0; BUILD=1; NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO="${1:-}" ;;
    --patches) shift; PATCHES="${1:-}" ;;
    --note) shift; NOTE="${1:-}" ;;
    --dry-run|-n) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help) sed -n '2,45p' "$SELF"; exit 0 ;;
    -*) printf '未知参数：%s\n' "$1" >&2; exit 1 ;;
    *) SET="$1" ;;
  esac
  shift || true
done

log()  { printf '\033[1;34m[patch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[patch!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[patch!]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# ---- 基目录工具（与 rdsh 同一套解析）----
RDSH_CONFIG="$HOME/.config/rdsh/config"
cfg_get() {
  [ -f "$RDSH_CONFIG" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1 \
    | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}
expand_tilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
BASE="$(expand_tilde "${RDSH_BASE:-$(cfg_get BASE)}")"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
[ -n "$PATCHES" ] || PATCHES="$BASE/dsh-patches"
MANIFEST="$PATCHES/manifest.yaml"
BACKUP_ROOT="$BASE/.dsh-backup"
TS="$(date +%Y%m%d-%H%M%S)"

command -v python3 >/dev/null || die "需要 python3 解析 manifest.yaml"
[ -f "$MANIFEST" ] || die "找不到补丁清单：$MANIFEST（先建补丁集，或用 --patches 指定）"

# ---- 检出探测：显式 --repo > 运行中的 dsh 实例的 cwd > 报错 ----
if [ -z "$REPO" ]; then
  pid="$(ss -ltnpH 'sport = :3080' 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  if [ -n "$pid" ]; then REPO="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"; fi
fi
if [ -z "$REPO" ]; then
  die "没指定 --repo，也探测不到运行中的检出。请用 --repo <检出路径> 指定。"
fi
REPO="$(readlink -f "$REPO")"
[ -d "$REPO" ] || die "检出目录不存在：$REPO"

HAS_GIT=0
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && HAS_GIT=1

log "检出：$REPO（git=$HAS_GIT）"
log "补丁仓库：$PATCHES"

# ---- manifest 读取（python3 → TSV：name|baseline|paths(逗号)|rebuild(逗号)|description）----
manifest_dump() {
  python3 - "$MANIFEST" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
sets = m.get('sets') or []
order = m.get('order')
if order:
    by = {s.get('name'): s for s in sets}
    sets = [by[n] for n in order if n in by] + [s for s in sets if s.get('name') not in order]
for s in sets:
    name = s.get('name') or ''
    baseline = s.get('baseline') or ''
    paths = ','.join(s.get('paths') or [])
    rebuild = ' ;; '.join(s.get('rebuild') or [])
    desc = (s.get('description') or '').replace('\t', ' ').replace('\x1f', ' ')
    print('\x1f'.join([name, baseline, paths, rebuild, desc]))
PY
}

manifest_get() {  # <集名> → 同一 TSV（只那一行）
  manifest_dump | awk -F'\x1f' -v n="$1" '$1==n'
}

set_names() { manifest_dump | cut -f1; }

patch_files() {  # <集名> → 补丁文件的绝对路径（按文件名排序）
  local dir="$PATCHES/$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.patch' -type f 2>/dev/null | sort
}

# ---- 单个补丁的状态：clean | applied | conflict ----
# 判据：正向 --check 通过 = 可干净应用；反向 --check 通过 = 已应用；都不通过 = 冲突。
patch_state() {  # <repo> <patchfile>
  local repo="$1" pf="$2"
  if [ "$HAS_GIT" = "1" ]; then
    if git -C "$repo" apply --check --whitespace=nowarn "$pf" >/dev/null 2>&1; then printf 'clean'; return; fi
    if git -C "$repo" apply --check -R --whitespace=nowarn "$pf" >/dev/null 2>&1; then printf 'applied'; return; fi
    printf 'conflict'
    return
  fi
  if patch -p1 -d "$repo" --dry-run --forward --silent <"$pf" >/dev/null 2>&1; then printf 'clean'; return; fi
  if patch -p1 -d "$repo" --dry-run --reverse --silent <"$pf" >/dev/null 2>&1; then printf 'applied'; return; fi
  printf 'conflict'
}

# ---- 应用/回退一个补丁文件 ----
apply_one() {  # <repo> <patchfile> → 0/1
  local repo="$1" pf="$2"
  if [ "$HAS_GIT" = "1" ]; then
    git -C "$repo" apply --3way --whitespace=nowarn "$pf" 2>&1 && return 0
    warn "git apply --3way 失败，改用 patch -p1 --merge"
  fi
  patch -p1 -d "$repo" --forward --merge --silent <"$pf" 2>&1
}

revert_one() {  # <repo> <patchfile> → 0/1
  local repo="$1" pf="$2"
  if [ "$HAS_GIT" = "1" ]; then
    git -C "$repo" apply -R --whitespace=nowarn "$pf" 2>&1 && return 0
    warn "git apply -R 失败，改用 patch -R"
  fi
  patch -p1 -d "$repo" --reverse --silent <"$pf" 2>&1
}

# ---- 备份：把补丁涉及的文件复制到备份目录（用于人工回滚，也是 apply 失败的兜底）----
backup_paths() {  # <repo> <paths 逗号分隔> → 打印备份目录
  local repo="$1" paths="$2" dir="$BACKUP_ROOT/patches-$TS"
  mkdir -p "$dir"
  local IFS=','
  for p in $paths; do
    [ -n "$p" ] || continue
    if [ -e "$repo/$p" ]; then
      mkdir -p "$dir/$(dirname "$p")"
      cp -a "$repo/$p" "$dir/$p" 2>/dev/null || true
    fi
  done
  printf '%s' "$dir"
}

# ---- 重建（补丁改了 TS/客户端包后必须重建才生效）----
run_rebuild() {  # <repo> <rebuild 命令串> 
  local repo="$1" cmds="$2"
  [ -n "$cmds" ] || return 0
  local oldIFS="$IFS"; IFS=';'
  for c in $cmds; do
    c="$(printf '%s' "$c" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$c" ] || continue
    log "重建：$c"
    ( cd "$repo" && bash -lc "$c" ) || { warn "重建失败：$c（补丁已应用，但产物未更新）"; return 1; }
  done
  IFS="$oldIFS"
  return 0
}

# ------------------------------------------------------------------ list
cmd_list() {
  printf '%-28s %-14s %-6s %s\n' 集名 基线 补丁数 说明
  local n=0
  while IFS=$'\x1f' read -r name baseline paths rebuild desc; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    local count; count="$(patch_files "$name" | grep -c . || true)"
    printf '%-28s %-14s %-6s %s\n' "$name" "${baseline:-—}" "$count" "$desc"
  done < <(manifest_dump)
  [ "$n" -gt 0 ] || warn "清单里没有任何补丁集。"
}

# ------------------------------------------------------------------ status
cmd_status() {
  local rc=0
  while IFS=$'\x1f' read -r name baseline paths rebuild desc; do
    [ -n "$name" ] || continue
    [ -z "$SET" ] || [ "$SET" = "$name" ] || continue
    log "补丁集：$name（基线 ${baseline:-—}）"
    local files; files="$(patch_files "$name")"
    if [ -z "$files" ]; then warn "  该集目录下没有 .patch 文件"; continue; fi
    while IFS= read -r pf; do
      [ -n "$pf" ] || continue
      local st; st="$(patch_state "$REPO" "$pf")"
      case "$st" in
        clean)    printf '  %-46s 可干净应用\n' "$(basename "$pf")" ;;
        applied)  printf '  %-46s 已应用\n' "$(basename "$pf")" ;;
        conflict) printf '  %-46s \033[1;31m冲突\033[0m\n' "$(basename "$pf")"; rc=2 ;;
      esac
    done <<<"$files"
  done < <(manifest_dump)
  return "$rc"
}

# ------------------------------------------------------------------ apply
cmd_apply() {
  local applied=()
  while IFS=$'\x1f' read -r name baseline paths rebuild desc; do
    [ -n "$name" ] || continue
    [ -z "$SET" ] || [ "$SET" = "$name" ] || continue
    local files; files="$(patch_files "$name")"
    [ -n "$files" ] || continue
    # 先整体体检：该集里任何一条冲突就不动手（避免半应用）
    local blocked=0
    while IFS= read -r pf; do
      [ -n "$pf" ] || continue
      local st; st="$(patch_state "$REPO" "$pf")"
      if [ "$st" = "conflict" ]; then
        warn "冲突：$(basename "$pf") —— 该集不改动，先人工处理。"
        blocked=1
      fi
    done <<<"$files"
    [ "$blocked" = "0" ] || { rc=2; continue; }

    local dir; dir="$(backup_paths "$REPO" "$paths")"
    log "补丁集 $name：备份到 $dir"
    local failed=0; local done_list=()
    while IFS= read -r pf; do
      [ -n "$pf" ] || continue
      local st; st="$(patch_state "$REPO" "$pf")"
      if [ "$st" = "applied" ]; then log "  跳过（已应用）：$(basename "$pf")"; continue; fi
      if [ "$DRY" = "1" ]; then log "  [dry-run] 将应用：$(basename "$pf")"; continue; fi
      log "  应用：$(basename "$pf")"
      if ! apply_one "$REPO" "$pf"; then
        warn "  失败：$(basename "$pf")"
        failed=1; break
      fi
      done_list+=("$pf")
    done <<<"$files"

    if [ "$failed" = "1" ]; then
      warn "回滚本次该集已应用的补丁，保持检出原样…"
      for pf in "${done_list[@]:-}"; do
        [ -n "$pf" ] || continue
        revert_one "$REPO" "$pf" >/dev/null 2>&1 || warn "  回滚失败（需人工）：$(basename "$pf")"
      done
      rc=2; continue
    fi
    log "补丁集 $name 完成。"
    if [ "$DRY" = "0" ] && [ "$BUILD" = "1" ]; then run_rebuild "$REPO" "$rebuild" || rc=2; fi
  done < <(manifest_dump)
  return "${rc:-0}"
}

# ------------------------------------------------------------------ revert
cmd_revert() {
  while IFS=$'\x1f' read -r name baseline paths rebuild desc; do
    [ -n "$name" ] || continue
    [ -z "$SET" ] || [ "$SET" = "$name" ] || continue
    local files; files="$(patch_files "$name" | tac)"
    [ -n "$files" ] || continue
    log "回退补丁集：$name"
    while IFS= read -r pf; do
      [ -n "$pf" ] || continue
      local st; st="$(patch_state "$REPO" "$pf")"
      if [ "$st" = "clean" ]; then log "  跳过（未应用）：$(basename "$pf")"; continue; fi
      if [ "$DRY" = "1" ]; then log "  [dry-run] 将回退：$(basename "$pf")"; continue; fi
      if revert_one "$REPO" "$pf"; then log "  已回退：$(basename "$pf")"
      else warn "  回退失败：$(basename "$pf")（可用 git checkout -- <paths> 兜底）"; rc=2; fi
    done <<<"$files"
    if [ "$DRY" = "0" ] && [ "$BUILD" = "1" ]; then run_rebuild "$REPO" "$rebuild" || true; fi
  done < <(manifest_dump)
  return "${rc:-0}"
}

# ------------------------------------------------------------------ export
cmd_export() {
  [ "$HAS_GIT" = "1" ] || die "export 需要 git 检出（当前 $REPO 不是 git 仓库）"
  while IFS=$'\x1f' read -r name baseline paths rebuild desc; do
    [ -n "$name" ] || continue
    [ -z "$SET" ] || [ "$SET" = "$name" ] || continue
    [ -n "$paths" ] || { warn "补丁集 $name 未声明 paths，跳过。"; continue; }
    local dir="$PATCHES/$name"; mkdir -p "$dir"
    local IFS=','; local args=()
    for p in $paths; do [ -n "$p" ] && args+=("$p"); done
    IFS=$' \t\n'
    local out="$dir/$(date +%Y%m%d-%H%M%S)-$name.patch"
    if [ "$DRY" = "1" ]; then log "[dry-run] 将导出：$out（paths=${paths}）"; continue; fi
    # 坑（2026-09-18 实测）：`git diff` 只看**已跟踪**文件，新增文件还是 untracked，
    # 导出的补丁会缺文件 —— 应用干净、构建必炸。故先用 intent-to-add 把它们纳入
    # diff（只改索引、不改工作树），导出后立刻 git reset 复原索引。
    local untracked
    untracked="$(git -C "$REPO" ls-files --others --exclude-standard -- "${args[@]}" 2>/dev/null | head -1 || true)"
    if [ -n "$untracked" ]; then
      log "集内含新增文件，临时 git add -N 以纳入补丁（导出后复原索引）"
      git -C "$REPO" add -N -- "${args[@]}" >/dev/null 2>&1 || true
    fi
    ( cd "$REPO" && git diff --no-color --binary -- "${args[@]}" ) > "$out"
    if [ -n "$untracked" ]; then
      git -C "$REPO" reset -q -- "${args[@]}" >/dev/null 2>&1 || true
    fi
    if [ -s "$out" ]; then
      log "已导出：$out（$(grep -c '^@@' "$out" || true) 个 hunk）"
      # 注意：不能把 `[ -n "$NOTE" ] && printf ...` 留作函数最后一句 ——
      # NOTE 为空时它返回 1，会让整个函数（乃至脚本）以失败退出。
      if [ -n "$NOTE" ]; then printf '%s\n' "$NOTE" > "$dir/NOTE.md"; fi
    else
      warn "该集在检出里没有差异，删掉空文件：$out"; rm -f "$out"
    fi
  done < <(manifest_dump)
  return 0
}

case "$MODE" in
  list)   cmd_list ;;
  status) cmd_status ;;
  apply)  [ "$DRY" = "1" ] || [ "$YES" = "1" ] || die "apply 会改检出：请加 --yes 确认，或先看 --dry-run/status" ; cmd_apply ;;
  revert) [ "$DRY" = "1" ] || [ "$YES" = "1" ] || die "revert 会改检出：请加 --yes 确认，或先看 --dry-run/status" ; cmd_revert ;;
  export) cmd_export ;;
  ""|-h|--help) sed -n '2,45p' "$SELF" ;;
  *) die "未知子命令：$MODE（可用：list/status/apply/revert/export）" ;;
esac
rc=$?
[ "$rc" = "0" ] || warn "退出码 $rc（2 = 有冲突或应用失败）"
exit "$rc"
