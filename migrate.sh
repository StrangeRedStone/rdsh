#!/usr/bin/env bash
# =============================================================================
# migrate.sh —— DSH 跨版本迁移器（v1，2026-09-17）
#
# 把「升级一次要手工做的五步」固化成一条命令，并遵守原则 P1：
#   **只检测、只留痕、只放行** —— 不替用户做不可逆决定，也不阻止用户做。
#
# 资产分层（详见本仓库 docs/架构.md）：
#   L1 上游数据  sessions/ storages/ settings.yaml .credentials.yaml
#                → 原样搬，交给新版自己迁移（会话格式有 v0→v1→v2(→v3) 链）
#   L2 作者资产  skills/ lessons.md AGENTS.md .agent-presets/ facts.md backlog.md
#                → **不搬**：它们在稳定根 $BASE/.dsh-suite/shared/，各版本 home 内只建软链
#   L3 插件      plugins/ + profiles/web/{cordis.patch.yml,package.json}
#                → 复制 + 重建 symlink；API 有变时靠 compat_check 出断点报告
#
# 用法:
#   migrate.sh <源> <目标> [选项]
#     <源>/<目标>：版本号片段(0.1.3) / 检出目录名 / 数据目录路径
#   选项:
#     --items=a,b,c         只迁移这些内容（可选：sessions,storages,settings,credentials,assets,plugins,profile,probe；默认 all=全部，兼容旧行为）
#     --dry-run|--plan      只打印计划，不做任何写入
#     --sessions=none|all|file   会话策略；file 配合 --sessions-file（默认 none）
#     --sessions-file <f>   挑选迁移的会话 JSON（session-archive pick --select-only 产出）
#     --carry-sessions=all  兼容旧写法，等价 --sessions=all
#     --force|-f            接受已声明可忽略的检查失败（不会越过安全闸门）
#     --no-backup           跳过备份（不推荐；会写进回退基线备注）
#     --no-probe-live       探针不做实机实测门（默认做：隔离 home 启动 + 真实工具调用）
#
# 环境覆盖（默认与 Rdsh.sh 一致；便于隔离测试）:
#   DSH_DATA_ROOT   $BASE/.dsh          DSH_MANAGE_ROOT $BASE/dsh
#   DSH_BACKUP_ROOT $BASE/.dsh-suite/backup   DSH_SHARED_HOME $BASE/.dsh-suite/shared
#   （$BASE 默认 ~/Mapp；以上均可用环境变量或配置文件覆盖）
#
# 回退基线: 每次运行都把「源/目标/备份目录/会话策略/探针结论」记进**状态账本**
#           （$BASE/.dsh-suite/state/，唯一权威），再重生成 $DSH_BACKUP_ROOT/回退基线.md。
#           2026-09-29 起该 md 是**生成物**，不再手工追加 —— 手写历史留在 state/回退基线-历史.md。
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
DATA_ROOT="$(expand_tilde "${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}")";         [ -n "$DATA_ROOT" ]   || DATA_ROOT="$BASE/.dsh-suite/data"
BACKUP_ROOT="$(expand_tilde "${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}")";   [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-suite/backup"
SHARED_ROOT="$(expand_tilde "${RDSH_SHARED_HOME:-$(cfg_get SHARED_ROOT)}")";   [ -n "$SHARED_ROOT" ] || SHARED_ROOT="$BASE/.dsh-suite/shared"
PLUGIN_ROOT="$(expand_tilde "${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}")";   [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$BASE/.dsh-suite/plugins"
BASELINE="$BACKUP_ROOT/回退基线.md"

DRY=0
CARRY_SESSIONS=none
SESSIONS_MODE=""          # none|all|file（新接口；空=沿用 --carry-sessions）
SESSIONS_FILE=""
ITEMS="all"               # 逗号分隔的迁移内容项；all=全部（直接运行兼容旧行为）
FORCE=0
DO_BACKUP=1
PROBE_LIVE=1        # 探针 v2 的实机实测门（隔离 home 启动 + 真实工具调用）；--no-probe-live 可关
SRC_ARG=""
DST_ARG=""
ALL_ITEMS="sessions,storages,settings,credentials,assets,plugins,profile,probe"

log()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[migrate!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[migrate!]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
act()  { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

usage() { sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 参数 ----
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --dry-run|--plan) DRY=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --carry-sessions=*) CARRY_SESSIONS="${a#*=}"; shift ;;
    --carry-sessions) [ $# -ge 2 ] || die '--carry-sessions 需要值'; CARRY_SESSIONS="$2"; shift 2 ;;
    --sessions=file:*) SESSIONS_MODE=file; SESSIONS_FILE="${a#--sessions=file:}"; shift ;;
    --sessions=*) SESSIONS_MODE="${a#*=}"; shift ;;
    --sessions) [ $# -ge 2 ] || die '--sessions 需要值'; SESSIONS_MODE="$2"; shift 2 ;;
    --sessions-file=*) SESSIONS_MODE=file; SESSIONS_FILE="${a#*=}"; shift ;;
    --sessions-file) [ $# -ge 2 ] || die '--sessions-file 需要路径'; SESSIONS_MODE=file; SESSIONS_FILE="$2"; shift 2 ;;
    --items=*) ITEMS="${a#*=}"; shift ;;
    -a|--all) ITEMS="all"; shift ;;
    --items) [ $# -ge 2 ] || die '--items 需要值'; ITEMS="$2"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    --probe-live) PROBE_LIVE=1; shift ;;
    --no-probe-live) PROBE_LIVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知选项：$a（用 --help）" ;;
    *) if [ -z "$SRC_ARG" ]; then SRC_ARG="$a"; elif [ -z "$DST_ARG" ]; then DST_ARG="$a"; else die "多余参数：$a"; fi; shift ;;
  esac
done
case "$CARRY_SESSIONS" in none|all) ;; *) die "--carry-sessions 只能是 none 或 all" ;; esac
case "${SESSIONS_MODE:-$CARRY_SESSIONS}" in none|all|file) ;; *) die "--sessions 只能是 none|all|file（用 --sessions-file）" ;; esac
[ "$SESSIONS_MODE" = file ] && [ -z "$SESSIONS_FILE" ] && die '--sessions-file 需要一个 JSON 文件路径'
# items 归一化/校验
if [ "$ITEMS" = "all" ] || [ -z "$ITEMS" ]; then ITEMS="$ALL_ITEMS"; fi
_ITEMS_NORM=""
_IFS_SAVE="$IFS"; IFS=','
for _it in $ITEMS; do
  _it="$(printf '%s' "$_it" | tr -d '[:space:]')"
  [ -n "$_it" ] || continue
  case ",$ALL_ITEMS," in *",$_it,"*) ;; *) die "未知 items：$_it（可选：$ALL_ITEMS）" ;; esac
  case ",$_ITEMS_NORM," in *",$_it,"*) ;; *) _ITEMS_NORM="${_ITEMS_NORM:+$_ITEMS_NORM,}$_it" ;; esac
done
IFS="$_IFS_SAVE"
ITEMS="$_ITEMS_NORM"
[ -n "$ITEMS" ] || die '--items 不能为空；用 -a/--items all 或列具体项'
has_item() { case ",$ITEMS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
[ -n "$SRC_ARG" ] && [ -n "$DST_ARG" ] || { usage; exit 1; }

# ---- 解析：版本号片段 / 检出目录名 / 路径 → version|checkout|home ----
read_version() {
  local dir="$1" v=""
  [ -f "$dir/package.json" ] && v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$dir/package.json" | head -1)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$dir")"
}

resolve() {
  local arg="$1" i=0 d base ver
  [[ "$arg" == ~* ]] && arg="${arg/#\~/$HOME}"
  if [[ "$arg" == */* || "$arg" == .* ]] && [ -d "$arg" ]; then printf '%s|%s' "$(read_version "$arg")" "$arg"; return; fi
  # 第一遍：精确匹配（版本号或目录名）—— 优先，避免被 "v2.0.0-checkout" 这类目录抢走
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"; ver="$(read_version "$d")"
    if [ "$ver" = "$arg" ] || [ "$base" = "$arg" ]; then printf '%s|%s' "$ver" "$d"; return; fi
  done
  # 第二遍：片段匹配（唯一才算命中）
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"; ver="$(read_version "$d")"
    if [[ "$ver" == *"$arg"* ]] || [[ "$base" == *"$arg"* ]]; then
      [ "$i" = "1" ] && die "「$arg」匹配到多个检出，请给更精确的版本号/目录名"
      printf '%s|%s' "$ver" "$d"; i=1
    fi
  done
  [ "$i" = "1" ] || die "找不到匹配「$arg」的检出（看 $MANAGE_ROOT）"
}

SRC_INFO=$(resolve "$SRC_ARG"); SRC_VER="${SRC_INFO%%|*}"; SRC_CHECKOUT="${SRC_INFO#*|}"; SRC_HOME="$DATA_ROOT/$SRC_VER"
DST_INFO=$(resolve "$DST_ARG"); DST_VER="${DST_INFO%%|*}"; DST_CHECKOUT="${DST_INFO#*|}"; DST_HOME="$DATA_ROOT/$DST_VER"
[ "$SRC_HOME" != "$DST_HOME" ] || die "源与目标是同一个数据目录（$SRC_HOME），无需迁移"
[ -d "$SRC_CHECKOUT" ] || die "源检出不存在：$SRC_CHECKOUT"
[ -d "$DST_CHECKOUT" ] || die "目标检出不存在：$DST_CHECKOUT"
[ -d "$SRC_HOME" ] || die "源数据目录不存在：$SRC_HOME"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/migrate-$SRC_VER-to-$DST_VER-$TS"

# 解析会话策略（--sessions 优先；否则兼容 --carry-sessions）
SESSIONS_MODE="${SESSIONS_MODE:-$CARRY_SESSIONS}"
[ -n "$SESSIONS_MODE" ] || SESSIONS_MODE=none

# 把挑选出来的会话从源 home 拷到目标 home（只增不改；注册表交给首次启动重算）
copy_selected_sessions() {
  [ -f "$SESSIONS_FILE" ] || die "--sessions-file 不存在：$SESSIONS_FILE"
  local ids n=0 id src wsdir name
  ids="$(python3 - "$SESSIONS_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if isinstance(d,dict):
    ids=d.get('sessions') or d.get('ids') or d.get('sessionIds') or []
elif isinstance(d,list):
    ids=d
else:
    ids=[]
for x in ids:
    x=str(x).strip()
    if x:
        print(x[8:] if x.startswith('session-') else x)
PY
)" || die "读不了 selection JSON：$SESSIONS_FILE"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # 老 home 的会话目录可能是 session-<uuid>，也可能是裸 <uuid>；两种都认
    src="$(find "$SRC_HOME/sessions" -maxdepth 2 -type d \( -name "session-$id" -o -name "$id" \) -print -quit 2>/dev/null || true)"
    if [ -z "$src" ]; then warn "源 home 找不到会话 $id，跳过"; continue; fi
    wsdir="$(basename "$(dirname "$src")")"
    name="$(basename "$src")"
    local dst="$DST_HOME/sessions/$wsdir/$name"
    if find "$DST_HOME/sessions" -maxdepth 2 -type d \( -name "session-$id" -o -name "$id" \) -print -quit 2>/dev/null | grep -q .; then
      warn "目标已有会话 $id，跳过（只增不改）"; continue
    fi
    act "会话 $name → $wsdir"
    if [ "$DRY" = "0" ]; then
      mkdir -p "$(dirname "$dst")"
      rsync -a --exclude 'session.lock' "$src/" "$dst/"
    fi
    n=$((n+1))
  done <<< "$ids"
  log "挑选会话：计划/拷贝 $n 个"
}

# 目标 workspace.json 置为 initialized=false（下次启动按 cwd 重建归属）
mark_workspace_rebuild() {
  local ws="$DST_HOME/storages/workspace.json"
  [ -f "$ws" ] || return 0
  if [ "$DRY" = "1" ]; then act "把 $ws 的 global.initialized 置为 false"; return 0; fi
  cp -a "$ws" "$ws.bak-migrate-$(date +%Y%m%d-%H%M%S)"
  python3 - "$ws" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d.setdefault('global',{})['initialized']=False
json.dump(d,open(p,'w'),ensure_ascii=False,separators=(',',':'))
PY
  printf '  + 工作区索引置为待重建（initialized=false）\n'
}

# 合并 profile 清单：携带源 home 的本地依赖/ bundles（@local / link:*/plugins/*），不覆盖目标的新默认
merge_profile_manifest() {
  local src="$SRC_HOME/profiles/web/package.json" dst="$DST_HOME/profiles/web/package.json"
  [ -f "$src" ] || { printf '  - 源没有 profiles/web/package.json，跳过 profile 清单合并\n'; return 0; }
  mkdir -p "$DST_HOME/profiles/web"
  if [ ! -f "$dst" ]; then
    act "源 profile 清单 → 目标（目标此前无 profile；首次启动后需复核新版本默认 bundles）"
    [ "$DRY" = "0" ] && cp -a "$src" "$dst"
    return 0
  fi
  [ "$DRY" = "1" ] && { act "合并 profile 清单 $src → $dst（只加 @local/link*/plugins 依赖与对应 bundles）"; return 0; }
  local out
  out="$(python3 - "$src" "$dst" "$PLUGIN_ROOT" <<'PY'
import json,sys,os
src,dst,proot=sys.argv[1],sys.argv[2],sys.argv[3].rstrip('/')
s=json.load(open(src)); d=json.load(open(dst))
sdeps=s.get('dependencies',{}) or {}
ddeps=d.setdefault('dependencies',{})
added=[]
for k,v in sdeps.items():
    if not (k.startswith('@local/') or '/plugins/' in str(v)): continue
    name=k.split('/')[-1]
    nv=f'link:{proot}/{name}'
    if k not in ddeps:
        ddeps[k]=nv; added.append((k,nv))
sb=(s.get('dsh',{}) or {}).get('profile',{}).get('bundles',[]) or []
db=d.setdefault('dsh',{}).setdefault('profile',{}).setdefault('bundles',[])
addedb=[]
for b in sb:
    if b in db: continue
    if b.startswith('@local/') or b in ddeps:
        db.append(b); addedb.append(b)
json.dump(d,open(dst,'w'),ensure_ascii=False,indent=2)
open(dst,'a').write('\n')
for k,v in added: print('DEP\t'+k+'\t'+v)
for b in addedb: print('BUNDLE\t'+b)
PY
)" || { warn "profile 清单合并失败（$src → $dst），未改目标"; return 0; }
  if [ -z "$out" ]; then printf '  = profile 清单无需合并（目标已含源本地项）\n'; else printf '  + profile 清单合并：\n'; printf '%s\n' "$out" | sed 's/^/    /'; fi
  # 为所有 @local 依赖补 node_modules 软链（pnpm lock 不在这里改，后续 pnpm install 会补）
  python3 - "$dst" "$PLUGIN_ROOT" "$DST_HOME/profiles/web/node_modules" <<'PY'
import json,sys,os
dst,proot,nm=sys.argv[1],sys.argv[2].rstrip('/'),sys.argv[3]
d=json.load(open(dst))
for k,v in (d.get('dependencies',{}) or {}).items():
    if not (k.startswith('@local/') or '/plugins/' in str(v)): continue
    name=k.split('/')[-1]
    target=os.path.join(proot,name)
    if not os.path.isdir(target): continue
    scope,base=k.split('/')
    linkdir=os.path.join(nm,scope); os.makedirs(linkdir,exist_ok=True)
    link=os.path.join(linkdir,base)
    if os.path.lexists(link):
        try:
            if os.path.realpath(link)==os.path.realpath(target): continue
        except OSError: pass
        print('WARN link exists but points elsewhere: '+link, file=sys.stderr); continue
    os.symlink(os.path.relpath(target, start=linkdir), link)
    print('LINK '+link+' -> '+target)
PY
}


step "迁移计划（P1：只检测 / 只留痕 / 只放行）"
printf '  源   : %s  (home %s)\n' "$SRC_VER" "$SRC_HOME"
printf '  目标 : %s  (home %s)\n' "$DST_VER" "$DST_HOME"
printf '  作者资产根 : %s（L2：各版本 home 内只建软链，不复制）\n' "$SHARED_ROOT"
printf '  内容项     : %s\n' "$ITEMS"
printf '  会话策略   : %s%s\n' "$SESSIONS_MODE" "$([ "$SESSIONS_MODE" = file ] && printf '（%s）' "$SESSIONS_FILE")"
printf '  备份目录   : %s\n' "$BACKUP_DIR"
printf '  模式       : %s\n' "$([ "$DRY" = "1" ] && echo 'dry-run（不写入任何东西）' || echo '实际执行')"

# ---- 1. 前置检查（只读） ----
step "1/7 前置检查（只读）"
[ -d "$DST_HOME" ] && printf '  目标 home：已存在（%s 项）\n' "$(ls -A "$DST_HOME" 2>/dev/null | wc -l)" || printf '  目标 home：不存在，将创建\n'
if [ -f "$DST_CHECKOUT/.installed" ] && [ -d "$DST_CHECKOUT/node_modules" ]; then
  printf '  目标检出：已安装（node_modules + .installed）\n'
else
  warn "目标检出尚未安装：先跑 \`rdsh install $DST_VER\`，否则迁移完也起不来"
fi
# 原生模块前置：0.1.6 起新增 native/system（flock 的 N-API 模块），构建期必须能拿到 Node 头文件。
# 构建脚本按 `dirname(process.execPath)/../include/node` 找头文件，**不看 npm 的 nodedir 配置**。
if [ -d "$DST_CHECKOUT/native/system" ]; then
  NODE_INC="$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")/../include/node"
  if [ -f "$NODE_INC/node_api.h" ]; then
    printf '  原生构建头文件：%s ✅\n' "$(readlink -f "$NODE_INC")"
  else
    warn "目标检出含 native/system，但 Node 头文件不在 $NODE_INC —— 直接 install 会在构建期失败"
    warn "  修法 A（推荐）：sudo dnf install -y nodejs-devel（NodeSource 仓库，版本与已装 nodejs 对齐）"
    warn "  修法 B（免 sudo）：用自带头文件的 Node 跑构建（nvm / 官方 tarball 的 bin/node 置于 PATH 最前）"
    warn "  不要跳过该构建：native/system/packages/entry/src/flock.ts 直接 require bin/<libc>/system.node，缺了会话锁会抛错"
  fi
fi
for n in skills lessons.md AGENTS.md .agent-presets facts.md backlog.md; do
  [ -e "$SHARED_ROOT/$n" ] || warn "稳定根缺 $n（L2 资产不齐，建链会跳过后报缺）"
done
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q '127.0.0.1:3080$'; then
  warn "127.0.0.1:3080 已被占用（有实例在跑）：迁移本身只读源 home，可不停；但 \`rdsh start $DST_VER\` 前必须先停它"
fi
printf '  磁盘余量：%s\n' "$(df -h "$DATA_ROOT" | awk 'NR==2{print $4" 可用"}')"
printf '  内存可用：%s\n' "$(free -h | awk '/^Mem:/{print $7}')（目标检出需要 pnpm install/build 时留意）"
[ -n "$(ls -A "$SRC_HOME/sessions" 2>/dev/null || true)" ] && printf '  源 sessions：%s 个工作日录，%s\n' "$(ls "$SRC_HOME/sessions" | wc -l)" "$(du -sh "$SRC_HOME/sessions" 2>/dev/null | cut -f1)"

# ---- 2. 备份（留痕；只增不覆盖） ----
step "2/7 备份源数据（$([ "$DO_BACKUP" = "1" ] && echo 开启 || echo '已用 --no-backup 关闭')）"
if [ "$DO_BACKUP" = "1" ]; then
  if [ -e "$BACKUP_DIR" ]; then
    if [ "$DRY" = "1" ]; then
      warn "备份目录已存在（dry-run 不写入；实际执行请等下一秒或换目录）：$BACKUP_DIR"
    else
      die "备份目录已存在，请重跑：$BACKUP_DIR"
    fi
  fi
  act "mkdir -p $BACKUP_DIR"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$BACKUP_DIR"
    for item in sessions storages settings.yaml .credentials.yaml plugins profiles/web/cordis.patch.yml profiles/web/package.json; do
      if [ -e "$SRC_HOME/$item" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$item")"
        cp -a "$SRC_HOME/$item" "$BACKUP_DIR/$item"
        printf '  + %s\n' "$item"
      fi
    done
    cat > "$BACKUP_DIR/README-还原.md" <<EOF
# migrate.sh 备份（$TS）

- 来源：\`$SRC_HOME\`（$SRC_VER）→ 目标：\`$DST_HOME\`（$DST_VER）
- 会话策略：$SESSIONS_MODE

## 还原（把源版本恢复成迁移前状态）

\`\`\`bash
B="$BACKUP_DIR"; H="$SRC_HOME"
# 逐项拷回（只在需要时执行；这些路径原本就在源 home 里）
for i in sessions storages settings.yaml .credentials.yaml plugins; do
  [ -e "\$B/\$i" ] && cp -a "\$B/\$i" "\$H/"
done
[ -f "\$B/profiles/web/cordis.patch.yml" ] && { mkdir -p "\$H/profiles/web"; cp -a "\$B/profiles/web/cordis.patch.yml" "\$H/profiles/web/cordis.patch.yml"; }
[ -f "\$B/profiles/web/package.json" ] && { mkdir -p "\$H/profiles/web"; cp -a "\$B/profiles/web/package.json" "\$H/profiles/web/package.json"; }
\`\`\`
EOF
  fi
else
  warn '未备份：--no-backup。回退基线里会记一条「本次无备份」'
fi

# ---- 3. 目标 home 骨架 + L2 软链 ----
step "3/7 目标 home 骨架 + L2 作者资产软链"
act "mkdir -p $DST_HOME（chmod 700）"
[ "$DRY" = "0" ] && { mkdir -p "$DST_HOME"; chmod 700 "$DST_HOME"; }
if has_item assets; then
  # 资产清单直接取 Rdsh.sh 的 AUTHOR_ASSETS，避免两套逻辑漂移
  ASSETS=(skills lessons.md AGENTS.md .agent-presets facts.md backlog.md)
  if [ -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    if eval "$(grep -m1 '^AUTHOR_ASSETS=' "$MANAGE_ROOT/Rdsh.sh")" 2>/dev/null && [ "${#AUTHOR_ASSETS[@]}" -gt 0 ]; then
      ASSETS=("${AUTHOR_ASSETS[@]}")
      printf '  （资产清单取自 Rdsh.sh：%s）\n' "${ASSETS[*]}"
    fi
  fi
  mkdir -p "$SHARED_ROOT"
  for n in "${ASSETS[@]}"; do
    if [ -L "$DST_HOME/$n" ]; then printf '  = %-16s 已是软链\n' "$n"; continue; fi
    if [ -e "$DST_HOME/$n" ]; then warn "$n：目标 home 已有真文件，未动（请人工决定）"; continue; fi
    if [ ! -e "$SHARED_ROOT/$n" ]; then warn "$n：稳定根里没有，跳过"; continue; fi
    act "ln -s $SHARED_ROOT/$n $DST_HOME/$n"
    [ "$DRY" = "0" ] && ln -s "$SHARED_ROOT/$n" "$DST_HOME/$n"
    printf '  + %-16s 建链\n' "$n"
  done
else
  printf '  - 未选 assets，跳过作者资产软链\n'
fi

# ---- 4. L1 数据 ----
step "4/7 L1 上游数据（原样搬，交给新版自己迁移格式）"
copy_once() {  # <相对路径>：目标缺才拷，绝不覆盖
  local rel="$1"
  [ -e "$SRC_HOME/$rel" ] || return 0
  if [ -e "$DST_HOME/$rel" ]; then warn "$rel：目标已有，未动（P1：不替用户决定）"; return 0; fi
  act "cp -a $SRC_HOME/$rel → $DST_HOME/$rel"
  [ "$DRY" = "0" ] && cp -a "$SRC_HOME/$rel" "$DST_HOME/$rel"
  printf '  + %s\n' "$rel"
}
has_item storages && copy_once storages
has_item settings && copy_once settings.yaml
has_item credentials && copy_once .credentials.yaml
# ---- 4.5 settings.yaml：schema 感知携带（B8）----
# 为什么单独一步：settings.yaml 的顶层键随版本 schema 变（实测 0.1.3-alpha.2 有 8 个键、
# 0.1.6-alpha.1 有 12 个）。上面 copy_once 只在"目标为空"时整份拷，遇到"目标已有"就什么都不做；
# 这一步做**合并**：同名键取源值（用户的选择）、目标独有键保留（新 schema 自己的）、
# 源独有键附带并告警（新版本可能不认识）。旧文件先挪进回收站（可还原），并在账本里登记 sha 指纹。
if has_item settings; then
  if [ -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    step "4.5/7 settings.yaml（schema 感知携带 + 账本登记）"
    if [ "$DRY" = "1" ]; then
      bash "$MANAGE_ROOT/Rdsh.sh" settings carry "$SRC_HOME" "$DST_HOME" --dry-run 2>&1 | sed 's/^/    /' || warn 'settings 携带预演失败（不影响迁移）'
    else
      bash "$MANAGE_ROOT/Rdsh.sh" settings carry "$SRC_HOME" "$DST_HOME" 2>&1 | sed 's/^/    /' || warn 'settings 携带失败（文件仍由 L1 复制的那份保留）'
    fi
  else
    warn "找不到 $MANAGE_ROOT/Rdsh.sh → 跳过 settings schema 感知携带（只有 L1 的整份复制）"
  fi
else
  printf '  - 未选 settings，跳过 settings.yaml 携带\n'
fi
if has_item sessions; then
  case "$SESSIONS_MODE" in
    all ) copy_once sessions ;;
    file ) step "4.6/7 挑选会话（$SESSIONS_FILE）"; copy_selected_sessions ;;
    none )
      printf '  - sessions/ 按策略 none **不搬**（选择性可续：旧 home 冻结为只读归档）\n'
      printf '    要续写某个会话：先跑 session-archive pick --select-only 生成 selection，再用 --sessions-file 传入\n' ;;
  esac
else
  printf '  - 未选 sessions，跳过会话\n'
fi

# 4b. 工作区索引一致性（2026-09-17 实战教训）：
#     workspace.json 里带着源版本的 sessionIds 与 initialized=true。会话没跟过来时，
#     那些 id 成了悬空引用；而 WorkspaceRegistry **只在 initialized=false 时**按会话
#     header 的 cwd 重新归组，否则手工拷进来的会话永远显示「未分组」。
#     所以拷贝索引后必须把它置回待重建状态，让目标版本首次启动自己重建归属。
DST_WS="$DST_HOME/storages/workspace.json"
if { has_item storages || has_item sessions; } && [ -f "$DST_WS" ]; then
  if [ "$DRY" = "1" ]; then
    printf '  [dry-run] 把 %s 的 global.initialized 置为 false（下次启动按 cwd 重建工作区归属）\n' "$DST_WS"
  else
    cp -a "$DST_WS" "$DST_WS.bak-migrate-$(date +%Y%m%d-%H%M%S)"
    if python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("global",{})["initialized"]=False; json.dump(d, open(p,"w"), ensure_ascii=False, separators=(",",":"))' "$DST_WS"; then
      printf '  + 工作区索引置为待重建（initialized=false）→ 目标版本首次启动按会话 header 的 cwd 重新归组\n'
    else
      warn "置 initialized=false 失败：稍后手动跑 reindex-workspaces.sh 即可"
    fi
  fi
else
  printf '  - 目标 home 无 storages/workspace.json 或未选 storages/sessions（新版首次启动会自行 bootstrap）\n'
fi

# ---- 5. L3 插件 ----
if has_item plugins; then
step "5/7 L3 插件与装载清单（复制 + 重建 symlink）"
# 插件来源优先级：① 权威副本 $PLUGIN_ROOT（推荐：代码只此一份，避免版本间分叉）
#                    ② 退回"从源 home 复制"（权威副本尚未建立时）
if [ -d "$PLUGIN_ROOT" ] && [ -n "$(ls -A "$PLUGIN_ROOT" 2>/dev/null)" ]; then
  act "从权威副本安装插件：$PLUGIN_ROOT → $DST_HOME/plugins"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$DST_HOME/plugins"
    for d in "$PLUGIN_ROOT"/*/; do
      [ -d "$d" ] || continue
      b="$(basename "${d%/}")"
      [ -d "$DST_HOME/plugins/$b" ] && { warn "$b：目标已有，未动"; continue; }
      mkdir -p "$DST_HOME/plugins/$b"
      cp -a "$d." "$DST_HOME/plugins/$b/"
    done
    for f in README.md setup.sh; do
      [ -f "$SRC_HOME/plugins/$f" ] && cp -a "$SRC_HOME/plugins/$f" "$DST_HOME/plugins/" 2>/dev/null || true
    done
  fi
  printf '  （权威副本不含 node_modules / contracts.json：前者由 setup.sh 按目标检出重建，后者各 home 自带）\n'
elif [ -d "$SRC_HOME/plugins" ]; then
  warn "未发现权威副本 $PLUGIN_ROOT：退回从源 home 复制（建议先跑 plugin-sync.sh --init）"
  if [ -d "$DST_HOME/plugins" ]; then
    warn "目标 home 已有 plugins/：未整目录覆盖；请人工比对后合并"
  else
    act "复制 plugins/（排除 .deprecated-*）"
    if [ "$DRY" = "0" ]; then
      mkdir -p "$DST_HOME/plugins"
      for d in "$SRC_HOME"/plugins/*/; do
        b="$(basename "${d%/}")"
        case "$b" in .*) continue ;; esac
        cp -a "$d" "$DST_HOME/plugins/$b"
      done
      cp -a "$SRC_HOME/plugins/README.md" "$DST_HOME/plugins/" 2>/dev/null || true
      cp -a "$SRC_HOME/plugins/setup.sh" "$DST_HOME/plugins/" 2>/dev/null || true
    fi
    printf '  + plugins/（%s 个目录）\n' "$(find "$SRC_HOME/plugins" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | wc -l)"
  fi
fi
if [ -f "$DST_HOME/plugins/setup.sh" ]; then
  act "DSH_HOME=$DST_HOME bash $DST_HOME/plugins/setup.sh $DST_CHECKOUT（重建挂载链与依赖链）"
  if [ "$DRY" = "0" ]; then
    # 必须显式指定 DSH_HOME：setup.sh 默认取环境里的 DSH_HOME，否则会去改**源** home 的链接
    DSH_HOME="$DST_HOME" bash "$DST_HOME/plugins/setup.sh" "$DST_CHECKOUT" | sed 's/^/    /'
  fi
fi
printf '  提醒：插件的编译产物是针对**源码检出版本**打的；若新版 API 有变，需在目标检出里重新构建\n'
else
  printf '  - 未选 plugins，跳过插件复制/setup 链接\n'
fi

# ---- 5.5 profile：patch + package.json 清单（本地插件/ bundles） ----
if has_item profile; then
  step "5.5/7 profile：cordis.patch.yml + package.json 清单"
  if [ -f "$SRC_HOME/profiles/web/cordis.patch.yml" ]; then
    act "复制 cordis.patch.yml（目标已有则不动）"
    if [ "$DRY" = "0" ]; then
      mkdir -p "$DST_HOME/profiles/web"
      [ -e "$DST_HOME/profiles/web/cordis.patch.yml" ] || cp -a "$SRC_HOME/profiles/web/cordis.patch.yml" "$DST_HOME/profiles/web/cordis.patch.yml"
    fi
  else
    printf '  - 源没有 cordis.patch.yml，跳过\n'
  fi
  merge_profile_manifest
else
  printf '  - 未选 profile，跳过 patch 与 profile 清单合并\n'
fi

# ---- 6. 探针（compat-check v2：CLI + 自检 + 可选实机实测门） ----
PROBE_OUT=""
PROBE_RC=0
if has_item probe; then
step "6/7 探针：对目标 home 跑 compat-check v2（$([ "$PROBE_LIVE" = "1" ] && echo '静态 + 自检 + 实机实测门' || echo '静态 + 自检')）"
PROBE_CLI="$DST_HOME/plugins/compat-check/lib/cli.mjs"
PROBE_LEGACY="$DST_HOME/plugins/compat-check/lib/index.mjs"
PROBE_ARGS=(--home "$DST_HOME" --checkout "$DST_CHECKOUT" --scope all --selftest --from "$SRC_VER")
[ "$PROBE_LIVE" = "1" ] && PROBE_ARGS+=(--live)
if [ "$DRY" = "1" ]; then
  act "RDSH_BASE=$BASE node $PROBE_CLI ${PROBE_ARGS[*]} → 报告写入 $BACKUP_DIR/compat-report.md（退出码 = 最高严重度）"
elif [ -f "$PROBE_CLI" ]; then
  set +e
  PROBE_OUT=$(RDSH_BASE="$BASE" node "$PROBE_CLI" "${PROBE_ARGS[@]}" 2>&1)
  PROBE_RC=$?
  set -e
  if [ -n "$PROBE_OUT" ]; then
    [ "$DO_BACKUP" = "1" ] && printf '%s\n' "$PROBE_OUT" > "$BACKUP_DIR/compat-report.md"
    printf '%s\n' "$PROBE_OUT" | grep -E '^## 结论|^- (自检|实测门|检出已构建)|⛔|⚠️|ℹ️' | sed 's/^/    /' || true
    printf '  探针退出码 %s（0 可继续 / 1 有 WARN / 2 有 ERROR 或自检失败；P1：只提示不拦）\n' "$PROBE_RC"
  else
    warn '探针无输出（可能是目标 home 的 compat-check 依赖链未建好）'
  fi
elif [ -f "$PROBE_LEGACY" ]; then
  warn '目标 home 只有旧版探针（无 CLI）→ 这份报告不含自检与实测门'
  PROBE_OUT=$(RDSH_BASE="$BASE" node --input-type=module -e "
    const mod = await import('$PROBE_LEGACY')
    const tools = new Map()
    mod.apply({ tools: { register: (s) => tools.set(s.name, s) }, get: (n) => ({ __stub: n }) })
    console.log(String(await tools.get('compat_check').execute({ home: '$DST_HOME', checkout: '$DST_CHECKOUT', scope: 'all', fix: false })))
  " 2>&1 || true)
  if [ -n "$PROBE_OUT" ]; then
    [ "$DO_BACKUP" = "1" ] && printf '%s\n' "$PROBE_OUT" > "$BACKUP_DIR/compat-report.md"
    printf '%s\n' "$PROBE_OUT" | grep -E '^## 结论|^- 检出已构建|⚠️|ℹ️' | sed 's/^/    /' || true
  else
    warn '探针无输出（可能是目标 home 的 compat-check 依赖链未建好）'
  fi
else
  warn "目标 home 没有 compat-check，跳过探针"
fi
[ "$DRY" = "0" ] && printf '  提示：CLI 在 DSH 进程外运行（无真 ctx）→ C 维「服务运行时注册」不具结论性；启动目标版本后可在会话里用 compat_check 复跑（那里有真 ctx）\n'
else
  printf '  - 未选 probe，跳过兼容性探针\n'
fi

# ---- 7. 回退基线（状态账本） ----
# 2026-09-29 起：$BASELINE 是**生成物**（由 state 账本 + 流水渲染），所以这里不再手工追加，
# 而是通过窄接口把事实记进账本，再让它重新生成。Rdsh.sh 不在/账本没播种时只告警不致命 ——
# 迁移本身不该因为一个记账动作而失败（原则 P1）。
step "7/7 回退基线（记入状态账本 → 生成 $BASELINE）"
REC_BACKUP=""
[ "$DO_BACKUP" = "1" ] && REC_BACKUP="$BACKUP_DIR"
REC_PROBE="$(printf '%s\n' "$PROBE_OUT" | grep -m1 '^## 结论' || true)"
if [ "$DRY" = "1" ]; then
  printf '  [dry-run] 将记录一条迁移事件并重新生成 %s：\n' "$BASELINE"
  printf '    源=%s 目标=%s 会话策略=%s\n' "$SRC_VER" "$DST_VER" "$SESSIONS_MODE"
  printf '    备份=%s\n    探针=%s\n' "${REC_BACKUP:-（本次无备份）}" "${REC_PROBE:-（未跑或未取到）}"
elif [ -f "$MANAGE_ROOT/Rdsh.sh" ]; then
  if bash "$MANAGE_ROOT/Rdsh.sh" state record-migration "$SRC_VER" "$DST_VER" \
       --backup "$REC_BACKUP" --sessions "$SESSIONS_MODE" --probe "$REC_PROBE" 2>&1 | sed 's/^/  /'; then
    :
  else
    warn '状态账本记录失败（账本未播种？跑一次 `rdsh state --init`）—— 迁移本身不受影响'
  fi
else
  warn "找不到 $MANAGE_ROOT/Rdsh.sh，跳过账本记录（回退信息见下方提示）"
fi
if [ "$DRY" = "0" ] && [ -f "$BASELINE" ]; then
  printf '  视图已更新：%s（共 %s 个对象）\n' "$BASELINE" "$(grep -c '^| [^|]' "$BASELINE" 2>/dev/null || echo 0)"
fi

step "完成"
printf '  下一步：\`rdsh start %s\`（首次启动会走 Rdsh 的建链与安装检查）\n' "$DST_VER"
printf '  提示1：迁移后手工拷了会话、UI 里却是「未分组」时，跑：bash %s/reindex-workspaces.sh %s\n' "$MANAGE_ROOT" "$DST_VER"
printf '  提示2：确定性可续会话、或想改会话策略，重跑本脚本即可（幂等，不覆盖已有文件）\n'
printf '  提示3：插件代码只维护一份权威副本（%s）；改完用它检查/同步各 home：bash %s/plugin-sync.sh --check\n' "$PLUGIN_ROOT" "$MANAGE_ROOT"
[ "$DRY" = "1" ] && printf '\n（dry-run 结束：没有写入任何东西）\n'
exit 0
