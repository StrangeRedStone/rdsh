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
#                → **不搬**：它们在稳定根 $BASE/.dsh-shared/，各版本 home 内只建软链
#   L3 插件      plugins/ + profiles/web/cordis.patch.yml
#                → 复制 + 重建 symlink；API 有变时靠 compat_check 出断点报告
#
# 用法:
#   migrate.sh <源> <目标> [选项]
#     <源>/<目标>：版本号片段(0.1.3) / 检出目录名 / 数据目录路径
#   选项:
#     --dry-run              只打印计划，不做任何写入
#     --carry-sessions=all   连 sessions/ 一起搬（默认 none：选择性可续，旧 home 冻结为归档）
#     --no-backup            跳过备份（不推荐；会写进回退基线备注）
#
# 环境覆盖（默认与 Rdsh.sh 一致；便于隔离测试）:
#   DSH_DATA_ROOT   $BASE/.dsh          DSH_MANAGE_ROOT $BASE/dsh
#   DSH_BACKUP_ROOT $BASE/.dsh-backup   DSH_SHARED_HOME $BASE/.dsh-shared
#   （$BASE 默认 ~/Mapp；以上均可用环境变量或配置文件覆盖）
#
# 回退基线: 每次运行都会把「源/目标/备份目录/还原命令/探针结论」追加进
#           $DSH_BACKUP_ROOT/回退基线.md（只追加，不覆盖）。
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
BASELINE="$BACKUP_ROOT/回退基线.md"

DRY=0
CARRY_SESSIONS=none
DO_BACKUP=1
SRC_ARG=""
DST_ARG=""

log()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[migrate!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[migrate!]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
act()  { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

usage() { sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 参数 ----
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    --carry-sessions=*) CARRY_SESSIONS="${a#*=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知选项：$a（用 --help）" ;;
    *) if [ -z "$SRC_ARG" ]; then SRC_ARG="$a"; elif [ -z "$DST_ARG" ]; then DST_ARG="$a"; else die "多余参数：$a"; fi ;;
  esac
done
case "$CARRY_SESSIONS" in none|all) ;; *) die "--carry-sessions 只能是 none 或 all" ;; esac
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

step "迁移计划（P1：只检测 / 只留痕 / 只放行）"
printf '  源   : %s  (home %s)\n' "$SRC_VER" "$SRC_HOME"
printf '  目标 : %s  (home %s)\n' "$DST_VER" "$DST_HOME"
printf '  作者资产根 : %s（L2：各版本 home 内只建软链，不复制）\n' "$SHARED_ROOT"
printf '  会话策略   : %s\n' "$CARRY_SESSIONS"
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
  if [ -e "$BACKUP_DIR" ]; then die "备份目录已存在，请重跑：$BACKUP_DIR"; fi
  act "mkdir -p $BACKUP_DIR"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$BACKUP_DIR"
    for item in sessions storages settings.yaml .credentials.yaml plugins profiles/web/cordis.patch.yml; do
      if [ -e "$SRC_HOME/$item" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$item")"
        cp -a "$SRC_HOME/$item" "$BACKUP_DIR/$item"
        printf '  + %s\n' "$item"
      fi
    done
    cat > "$BACKUP_DIR/README-还原.md" <<EOF
# migrate.sh 备份（$TS）

- 来源：\`$SRC_HOME\`（$SRC_VER）→ 目标：\`$DST_HOME\`（$DST_VER）
- 会话策略：$CARRY_SESSIONS

## 还原（把源版本恢复成迁移前状态）

\`\`\`bash
B="$BACKUP_DIR"; H="$SRC_HOME"
# 逐项拷回（只在需要时执行；这些路径原本就在源 home 里）
for i in sessions storages settings.yaml .credentials.yaml plugins; do
  [ -e "\$B/\$i" ] && cp -a "\$B/\$i" "\$H/"
done
[ -f "\$B/profiles/web/cordis.patch.yml" ] && cp -a "\$B/profiles/web/cordis.patch.yml" "\$H/profiles/web/cordis.patch.yml"
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
copy_once storages
copy_once settings.yaml
copy_once .credentials.yaml
if [ "$CARRY_SESSIONS" = "all" ]; then
  copy_once sessions
else
  printf '  - sessions/ 按策略 none **不搬**（选择性可续：旧 home 冻结为只读归档）\n'
  printf '    要续写某个会话，复制那一个目录即可，例如：\n'
  printf '      cp -a "%s/sessions/<工作区目录>/<会话目录>" "%s/sessions/<工作区目录>/"\n' "$SRC_HOME" "$DST_HOME"
  printf '    （注意：只读打开不会改盘；一旦在新版里**续写**，该会话磁盘格式会升级，旧版就读不回了）\n'
fi

# 4b. 工作区索引一致性（2026-09-17 实战教训）：
#     workspace.json 里带着源版本的 sessionIds 与 initialized=true。会话没跟过来时，
#     那些 id 成了悬空引用；而 WorkspaceRegistry **只在 initialized=false 时**按会话
#     header 的 cwd 重新归组，否则手工拷进来的会话永远显示「未分组」。
#     所以拷贝索引后必须把它置回待重建状态，让目标版本首次启动自己重建归属。
DST_WS="$DST_HOME/storages/workspace.json"
if [ -f "$DST_WS" ]; then
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
  printf '  - 目标 home 无 storages/workspace.json（新版首次启动会自行 bootstrap）\n'
fi

# ---- 5. L3 插件 ----
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
if [ -f "$SRC_HOME/profiles/web/cordis.patch.yml" ]; then
  act "复制 cordis.patch.yml"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$DST_HOME/profiles/web"
    [ -e "$DST_HOME/profiles/web/cordis.patch.yml" ] || cp -a "$SRC_HOME/profiles/web/cordis.patch.yml" "$DST_HOME/profiles/web/cordis.patch.yml"
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

# ---- 6. 探针（在目标 home 上跑 compat_check） ----
PROBE_OUT=""
step "6/7 探针：对目标 home 跑 compat_check（断点报告）"
PROBE="$DST_HOME/plugins/compat-check/lib/index.mjs"
if [ "$DRY" = "1" ]; then
  act "node <import $PROBE> → 报告写入 $BACKUP_DIR/compat-report.md"
elif [ -f "$PROBE" ]; then
  PROBE_OUT=$(node --input-type=module -e "
    const mod = await import('$PROBE')
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
[ "$DRY" = "0" ] && printf '  提示：探针在 DSH 进程外运行（桩 ctx）→ C 维度「服务是否运行时注册」不具结论性；启动目标版本后请用 compat_check 再复跑一次\n'

# ---- 7. 回退基线 ----
step "7/7 回退基线（$BASELINE，只追加）"
BASELINE_BLOCK=$(cat <<EOF

## $TS ｜ $SRC_VER → $DST_VER
- 源 home：\`$SRC_HOME\`
- 目标 home：\`$DST_HOME\`
- 会话策略：$CARRY_SESSIONS
- 备份目录：$( [ "$DO_BACKUP" = "1" ] && printf '`%s`' "$BACKUP_DIR" || printf '**本次无备份（--no-backup）**' )
- 探针结论：$(printf '%s\n' "$PROBE_OUT" | grep -m1 '^## 结论' || echo '（未跑或未取到）')
- 回退动作：停掉目标版本实例 → \`rdsh start $SRC_VER\`（源 home 全程只读，未被修改）
$( [ "$DO_BACKUP" = "1" ] && printf -- '- 还原命令：见 `%s/README-还原.md`\n' "$BACKUP_DIR" )
EOF
)
if [ "$DRY" = "1" ]; then
  printf '  [dry-run] 将追加以下内容：\n%s\n' "$BASELINE_BLOCK" | sed 's/^/  /'
else
  [ -f "$BASELINE" ] || printf '# 回退基线（migrate.sh 自动追加；原则 P1：只写不拦）\n' > "$BASELINE"
  printf '%s\n' "$BASELINE_BLOCK" >> "$BASELINE"
  printf '  已追加一节（共 %s 节）\n' "$(grep -c '^## ' "$BASELINE")"
fi

step "完成"
printf '  下一步：\`rdsh start %s\`（首次启动会走 Rdsh 的建链与安装检查）\n' "$DST_VER"
printf '  提示1：迁移后手工拷了会话、UI 里却是「未分组」时，跑：bash %s/reindex-workspaces.sh %s\n' "$MANAGE_ROOT" "$DST_VER"
printf '  提示2：确定性可续会话、或想改会话策略，重跑本脚本即可（幂等，不覆盖已有文件）\n'
printf '  提示3：插件代码只维护一份权威副本（%s）；改完用它检查/同步各 home：bash %s/plugin-sync.sh --check\n' "$PLUGIN_ROOT" "$MANAGE_ROOT"
[ "$DRY" = "1" ] && printf '\n（dry-run 结束：没有写入任何东西）\n'
