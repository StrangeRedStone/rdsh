#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh —— **蛋生鸡**：把 rdsh 装进一台新机器，并做初始化配置
#
# 为什么单独一个脚本：新机器上**还没有 rdsh**，所以它不能依赖 Rdsh.sh 已就位。
# 它自己只做"取到本体"，之后一律把活交给刚装好的 Rdsh.sh（避免第二套实现）。
#
# 七步（每步都留痕；--dry-run 全程预演，一个字节都不写）：
#   1. 依赖自检       bash≥4 / git / rsync / jq / python3 / systemd-run / ss —— 缺谁明确报出
#   2. 取本体         clone 远端仓库（默认 SSH，失败自动试 HTTPS）/ --from 本地目录或 tarball（离线）
#                     目标已存在且是 git 仓库 → git pull --ff-only（**幂等**）
#   3. 定 BASE        建齐目录（数据/备份/状态/日志/插件/回收站…），权限 700
#   4. 写配置         ~/.config/rdsh/config —— **只补缺键，绝不覆盖已有值**
#   5. 落入口         <MANAGE_ROOT>/rdsh → Rdsh.sh；可选 ~/.local/bin/rdsh → 上面那个
#   6. 可选装 dsh     --with-dsh <版本|latest> → 交给 rdsh fetch + install
#   7. 验收           rdsh base / doctor / bridge --spec（三条只读）→ 打印下一步
#
# 用法：
#   bootstrap.sh                                  # 装到 ~/Mapp/dsh，配置写 ~/.config/rdsh/config
#   bootstrap.sh --base /opt/dsh                  # 换 BASE
#   bootstrap.sh --from ~/Downloads/rdsh.tar.gz   # 离线装机（或 --from <已 clone 的目录>）
#   bootstrap.sh --from .                          # 从当前目录（本身就是 clone）装
#   bootstrap.sh --with-dsh latest                 # 顺手装一个 dsh 版本
#   bootstrap.sh --dry-run                         # 只打印计划（可安全随时跑）
#
# 退出码：0 成功 / 1 参数错误 / 2 取本体失败 / 3 依赖缺失 / 4 配置或入口失败 / 5 验收失败
# =============================================================================
set -euo pipefail

VERSION_MARK="bootstrap.sh（rdsh 蛋生鸡）"

BASE="${RDSH_BASE:-$HOME/Mapp}"
DEST=""                    # rdsh 检出位置（默认 $BASE/dsh）
REPO="${RDSH_SELF_REPO:-git@github.com:StrangeRedStone/rdsh.git}"
REPO_HTTPS="https://github.com/StrangeRedStone/rdsh.git"
FROM=""
CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"
WITH_DSH=""
BIN_DIR="$HOME/.local/bin"
DRY=0
NO_LINK=0
NO_DEPS=0
LOG=""

die()  { printf '\033[1;31m[bootstrap!]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }
warn() { printf '\033[1;33m[bootstrap!]\033[0m %s\n' "$*" >&2; }
say()  { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
run()  { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
expand() { case "$1" in "~"|"~/"*) printf '%s' "${HOME}${1#\~}" ;; *) printf '%s' "$1" ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base) shift; BASE="${1:?--base 需要路径}" ;;
    --base=*) BASE="${1#--base=}" ;;
    --dir) shift; DEST="${1:?--dir 需要路径}" ;;
    --dir=*) DEST="${1#--dir=}" ;;
    --repo) shift; REPO="${1:?--repo 需要 URL}" ;;
    --repo=*) REPO="${1#--repo=}" ;;
    --from) shift; FROM="${1:?--from 需要目录或 tarball}" ;;
    --from=*) FROM="${1#--from=}" ;;
    --config) shift; CONFIG="${1:?--config 需要路径}" ;;
    --config=*) CONFIG="${1#--config=}" ;;
    --with-dsh) shift; WITH_DSH="${1:?--with-dsh 需要版本}" ;;
    --with-dsh=*) WITH_DSH="${1#--with-dsh=}" ;;
    --bin-dir) shift; BIN_DIR="${1:?--bin-dir 需要路径}" ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}" ;;
    --dry-run|-n) DRY=1 ;;
    --no-link) NO_LINK=1 ;;
    --no-deps-check) NO_DEPS=1 ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift || true
done

BASE="$(expand "$BASE")"; CONFIG="$(expand "$CONFIG")"; BIN_DIR="$(expand "$BIN_DIR")"
[ -n "$DEST" ] || DEST="$BASE/dsh"
DEST="$(expand "$DEST")"
[ -n "$FROM" ] && FROM="$(expand "$FROM")"

if [ "$DRY" = "1" ]; then
  LOG="$BASE/.dsh-suite/logs/bootstrap-<时间戳>.log（dry-run 不落盘）"
else
  mkdir -p "$BASE/.dsh-suite/logs"
  LOG="$BASE/.dsh-suite/logs/bootstrap-$(date +%Y%m%d-%H%M%S).log"
  # 之后的输出同时进日志（人看 stdout，事后看日志）
  exec > >(tee -a "$LOG") 2>&1
fi
say "$VERSION_MARK"
say "BASE=$BASE   检出=$DEST   配置=$CONFIG"
[ "$DRY" = "1" ] && warn 'dry-run：只打印计划，不写任何东西'
say "日志：$LOG"

# ---- 1. 依赖自检 ----
step "1/7 依赖自检"
MISSING=()
declare -A HINT=(
  [git]='git（dnf install git / apt install git）'
  [rsync]='rsync（dnf install rsync / apt install rsync）'
  [jq]='jq（dnf install jq / apt install jq）'
  [python3]='python3（dnf install python3 / apt install python3）'
  [systemd-run]='systemd（dnf install systemd / apt install systemd）'
  [ss]='iproute（dnf install iproute / apt install iproute2）'
  [sha256sum]='coreutils（几乎都自带）'
  [readlink]='coreutils'
  [find]='findutils'
)
printf '  %-12s %-8s %s\n' '命令' '版本' '说明'
for c in git rsync jq python3 systemd-run ss sha256sum readlink find; do
  if command -v "$c" >/dev/null 2>&1; then
    v="$("$c" --version 2>/dev/null | sed -n '1p' | cut -c1-30)" || v='-'
    [ -n "$v" ] || v='-'      # 注意：别用 `| head -1 ||` —— pipefail 下 head 早退会让上游吃 SIGPIPE，管道非零
    printf '  %-12s %-8s %s\n' "$c" "ok" "$v"
  else
    printf '  %-12s %-8s %s\n' "$c" "缺失" "${HINT[$c]:-}"
    MISSING+=("$c")
  fi
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then MISSING+=('bash>=4'); fi
printf '  %-12s %-8s %s\n' 'bash' "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" '需要 ≥4'
if [ "${#MISSING[@]}" -gt 0 ] && [ "$NO_DEPS" != "1" ]; then
  warn "缺 ${#MISSING[@]} 项：${MISSING[*]}"
  warn '装齐再跑；确知自己在做什么可用 --no-deps-check 跳过'
  exit 3
fi
[ "${#MISSING[@]}" -gt 0 ] && warn "缺依赖但被 --no-deps-check 放行：${MISSING[*]}"

# ---- 2. 取本体 ----
step "2/7 取本体（rdsh 脚本本体；**不含任何 dsh 检出**）"
if [ -n "$FROM" ]; then
  case "$FROM" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar)
      [ -f "$FROM" ] || die "找不到 tarball：$FROM" 2
      say "  离线：解包 $FROM → $DEST"
      if [ "$DRY" = "0" ]; then
        mkdir -p "$DEST"
        tar -xf "$FROM" -C "$DEST" --strip-components=1 2>/dev/null || tar -xf "$FROM" -C "$DEST"
      fi
      ;;
    *)
      [ -d "$FROM" ] || die "--from 既不是目录也不是 tarball：$FROM" 2
      say "  离线：从本地目录取脚本 $FROM → $DEST"
      if [ "$DRY" = "0" ]; then
        mkdir -p "$DEST"
        for f in "$FROM"/*.sh; do [ -f "$f" ] && cp -p "$f" "$DEST/"; done
        [ -d "$FROM/tools" ] && { mkdir -p "$DEST/tools"; cp -p "$FROM"/tools/*.sh "$DEST/tools/" 2>/dev/null || true; }
      fi
      ;;
  esac
elif [ -d "$DEST/.git" ]; then
  say "  已存在 git 检出 → 就地更新（git pull --ff-only，幂等）"
  if [ "$DRY" = "0" ]; then
    git -C "$DEST" pull --ff-only || warn "pull 失败（离线？有本地改动？）→ 继续用现有副本"
  else
    printf '  [dry-run] git -C %s pull --ff-only\n' "$DEST"
  fi
elif [ -e "$DEST" ]; then
  warn "$DEST 已存在但不是 git 检出 → **不动它**（要重装请先手工改名或移走）"
else
  say "  clone $REPO → $DEST"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$(dirname "$DEST")"
    if ! git clone --quiet "$REPO" "$DEST" 2>/dev/null; then
      warn "SSH clone 失败 → 改试 HTTPS（$REPO_HTTPS）"
      git clone --quiet "$REPO_HTTPS" "$DEST" || die "clone 失败：检查网络/SSH key/仓库地址（--repo 可指定）" 2
    fi
  else
    printf '  [dry-run] git clone %s %s\n' "$REPO" "$DEST"
  fi
fi
[ "$DRY" = "0" ] && [ -f "$DEST/Rdsh.sh" ] || { [ "$DRY" = "1" ] || die "取本体后没有 $DEST/Rdsh.sh" 2; }

# ---- 3. 定 BASE + 建目录 ----
step "3/7 定 BASE 与目录结构"
say "  BASE=$BASE"
for d in "$DEST" "$BASE/.dsh-suite/data" "$BASE/.dsh-suite/shared" "$BASE/.dsh-suite/backup" \
         "$BASE/.dsh-suite/logs" "$BASE/.dsh-suite/state" "$BASE/.dsh-suite/run" \
         "$BASE/.dsh-suite/plugins" "$BASE/.dsh-suite/patches" "$BASE/.dsh-suite/trash"; do
  if [ -d "$d" ]; then printf '  = %s\n' "$d"; else printf '  + %s\n' "$d"; run mkdir -p "$d"; fi
done
[ "$DRY" = "0" ] && chmod 700 "$BASE/.dsh-suite" 2>/dev/null || true

# ---- 4. 写配置（只补缺键） ----
step "4/7 写配置（**只补缺键，绝不覆盖已有值**）"
cfg_set_missing() {  # <KEY> <VALUE> <注释>
  local k="$1" v="$2" c="${3:-}" cur=""
  if [ -f "$CONFIG" ]; then
    cur="$(sed -nE "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$CONFIG" | tail -1)"  # ${k} 的花括号是必须的：$k[[ 会被当成数组下标
  fi
  if [ -n "$cur" ]; then
    printf '  = %-16s 已有：%s（不动）\n' "$k" "$cur"; return 0
  fi
  printf '  + %-16s %s\n' "$k" "$v"
  if [ "$DRY" = "0" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    [ -s "$CONFIG" ] || printf '# rdsh 配置（bootstrap %s 生成；纯 KEY=VALUE，不会被 source）\n' "$(date +%F)" >> "$CONFIG"
    [ -n "$c" ] && printf '%s\n' "$c" >> "$CONFIG"
    printf '%s=%s\n' "$k" "$v" >> "$CONFIG"
  fi
}
if [ -f "$CONFIG" ]; then say "  配置文件已存在：$CONFIG"; else say "  新建配置文件：$CONFIG"; fi
cfg_set_missing BASE "$BASE" '# 单一旋钮：下面所有默认值都由它推导'
# 其余根**显式写出**，指向 .dsh-suite/ 布局 —— 与上层创建的目录、以及迁移后的真实机器一致。
# （只写 BASE 的话，rdsh 会用旧的 $BASE/.dsh-* 默认值，于是"建了一处、用另一处"。）
cfg_set_missing DATA_ROOT    "$BASE/.dsh-suite/data"     '# 每版本数据根'
cfg_set_missing SHARED_ROOT  "$BASE/.dsh-suite/shared"   '# 与版本无关的作者资产（软链共享）'
cfg_set_missing BACKUP_ROOT  "$BASE/.dsh-suite/backup"   '# 备份/快照/回滚点'
cfg_set_missing LOG_DIR      "$BASE/.dsh-suite/logs"     '# 启动日志'
cfg_set_missing STATE_ROOT   "$BASE/.dsh-suite/state"    '# 状态账本（唯一权威）'
cfg_set_missing RUN_DIR      "$BASE/.dsh-suite/run"      '# 实例注册表（注解层）'
cfg_set_missing DEBUG_ROOT   "$BASE/.dsh-suite/debug"    '# 调试沙箱'
cfg_set_missing PLUGIN_ROOT  "$BASE/.dsh-suite/plugins"  '# 插件权威副本'
cfg_set_missing PATCHES      "$BASE/.dsh-suite/patches"  '# 补丁'
cfg_set_missing TRASH_ROOT   "$BASE/.dsh-suite/trash"    '# 回收站（"永不 rm"的落点）'
chmod 600 "$CONFIG" 2>/dev/null || true

# ---- 5. 落入口 ----
step "5/7 落 rdsh 入口"
if [ "$NO_LINK" = "1" ]; then
  say '  --no-link：跳过入口软链'
else
  L1="$DEST/rdsh"
  if [ -L "$L1" ] || [ ! -e "$L1" ]; then
    printf '  %s %s → Rdsh.sh\n' "$([ -L "$L1" ] && echo '=' || echo '+')" "$L1"
    if [ "$DRY" = "0" ]; then ln -sfn "$DEST/Rdsh.sh" "$L1"; chmod +x "$DEST/Rdsh.sh" 2>/dev/null || true; fi
  else
    warn "  $L1 已存在且不是软链 → 不动（手工确认）"
  fi
  if [ -d "$BIN_DIR" ] || [ "$DRY" = "0" ]; then
    L2="$BIN_DIR/rdsh"
    if [ -L "$L2" ] || [ ! -e "$L2" ]; then
      printf '  + %s → %s\n' "$L2" "$L1"
      run mkdir -p "$BIN_DIR"
      if [ "$DRY" = "0" ]; then ln -sfn "$L1" "$L2"; fi
      case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "  $BIN_DIR 不在 PATH 里 → 加一行：export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
    else
      warn "  $L2 已存在且不是软链 → 不动"
    fi
  fi
fi

# ---- 6. 可选：装一个 dsh ----
step "6/7 可选：装一个 dsh 版本"
if [ -n "$WITH_DSH" ]; then
  if [ "$DRY" = "1" ]; then
    printf '  [dry-run] RDSH_CONFIG=%s bash %s fetch %s && ... install\n' "$CONFIG" "$DEST/Rdsh.sh" "$WITH_DSH"
  else
    say "  rdsh fetch $WITH_DSH"
    RDSH_CONFIG="$CONFIG" RDSH_BASE="$BASE" bash "$DEST/Rdsh.sh" fetch "$WITH_DSH" || warn 'fetch 失败 → 之后可重跑 `rdsh fetch <版本>`'
    RDSH_CONFIG="$CONFIG" RDSH_BASE="$BASE" bash "$DEST/Rdsh.sh" install "$WITH_DSH" || warn 'install 失败 → 之后可重跑 `rdsh install <版本>`'
  fi
else
  say '  未指定 --with-dsh → 只装 rdsh 本体（之后自己 `rdsh fetch <版本>`）'
fi

# ---- 7. 验收 ----
step "7/7 验收（三条只读命令）"
if [ "$DRY" = "1" ]; then
  printf '  [dry-run] rdsh base / rdsh doctor --quiet / rdsh bridge --spec\n'
else
  R=(env RDSH_CONFIG="$CONFIG" RDSH_BASE="$BASE" bash "$DEST/Rdsh.sh")
  "${R[@]}" base 2>&1 | sed 's/^/  /' | head -8
  "${R[@]}" doctor --quiet >/dev/null 2>&1 && say '  doctor：干净' || warn '  doctor：有 warn/error（正常，装完先看一遍）'
  if "${R[@]}" bridge --spec --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("  bridge：能力",len(d["capabilities"]),"个")' 2>/dev/null; then :; else warn '  bridge：契约读取失败'; fi
fi

printf '\n'
say '完成。下一步：'
cat <<EOF
  1) 让 PATH 生效（若刚加了 $BIN_DIR）： export PATH="$BIN_DIR:\$PATH"
  2) 装第一个 dsh：      rdsh fetch latest && rdsh install latest
  3) 看一眼环境：        rdsh base && rdsh doctor
  4) 装插件/作者资产：   把 author 资产放到 $BASE/.dsh-suite/shared（或 rdsh restore）
  5) 之后自更新：        rdsh selfupdate（拉仓库 → 语法+冒烟+隐私守卫 → 失败自动回滚）
  日志：$LOG
EOF
