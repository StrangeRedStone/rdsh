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
#   rdsh backup [<目标>|--all] [--snapshot|--full] [--state] [--verify] [--keep N]
#       rdsh backup --list [<版本>] | --verify <快照目录>
#                                         # 数据 home / 状态账本的**本地**快照。--snapshot 用
#                                         #   rsync --link-dest 做增量（未变的文件是硬链接）；
#                                         #   --verify 逐文件核查；--keep N 保留策略（超出的进回收站）
#   rdsh restore --list | --type <类> [--from <源>] [--file <相对路径>] [--diff] [--merge]
#                                         # 从本地快照 / 本地克隆 / 远端仓库恢复；data/state **只本地**；
#                                         #   凭据默认不恢复；记忆三库默认按条目追加；收尾自动调 doctor
#   rdsh du [--purge <类>] [--older-than Nd] [--yes] [--force] [--json]
#                                         # rdsh 衍生物账本：回收站/备份快照/调试沙箱/fetch 临时/
#                                         #   注册表陈旧/启动日志的体积与份数。**默认只列不删**；
#                                         #   --purge 才真删（backup/fetch 必须给 --older-than，
#                                         #   trash 项小于 RDSH_TRASH_KEEP_DAYS=7 天要 --force）
#   rdsh trash ls | restore <条目名|--last> [--force]
#                                         # 回收站（永不 rm 的落点）：条目带清单与还原命令
#   rdsh logs [-f] [版本|序号] [-o]       # 查看/打开启动日志（--clean 清理旧日志）
#   rdsh base [路径] [--unset]            # 查看/设置基目录（只改 rdsh 的指向，不搬动任何数据）
#   rdsh patch list|status|apply|revert|export  # 检出补丁管理（转发 patch-manager.sh）
#                                         #   apply/revert 会改检出：默认要 --yes，支持 --dry-run
#   rdsh fetch --list [--refresh]         # 列远端可用版本（GitHub API 列举 + 10 分钟缓存；失败回退 git ls-remote）
#   rdsh fetch <版本> [--dir <名>] [--tarball] [--full] [--install] [--dry-run]
#                                         # 拉取指定版本检出到 $BASE/dsh/（默认 git clone --depth 1，与官方源码装法一致，
#                                         #   后续 rdsh patch export / 上游 diff 可用；--tarball 改走归档：更小更稳但无 .git）
#   rdsh doctor [--only <维度,…>] [--json] [--quiet]
#                                         # 一键**只读**体检（转发 doctor.sh）：检出/数据 home/软链完整性/
#                                         #   插件一致性/状态账本/实例/日志/磁盘内存/配置 九个维度；
#                                         #   必报"检查了几个对象"，总数为 0 时报 error；
#                                         #   退出码 0=无发现 1=有 warn 2=有 error（restore/retire/migrate 共用它）
#   rdsh scan --path <目录> | --staged [--repo <目录>] | --files <文件>...
#                                         # **隐私守卫**（转发 scan-secrets.sh）：扫私钥/令牌/凭据文件/
#                                         #   会话数据（error）与绝对家目录/邮箱/大文件（warn）；
#                                         #   报告不回显敏感值；必报"扫了几个文件"，0 个报 error；
#                                         #   退出码 0 干净 / 1 有 warn / 2 有 error（--strict 把 warn 当 error）
#   rdsh help
#
# 状态账本（state，B1 起）—— 回答"谁是什么角色"，是 rdsh 唯一的权威状态源：
#   rdsh state [list]                     # 列出账本（对象键/角色/安装时间/来源/检出/数据）
#   rdsh state show <目标>                # 看某个对象的全部字段
#   rdsh state role <目标> <角色>         # 改角色：current|baseline|retire-candidate|retired
#   rdsh state render                     # 重新生成 $BACKUP_ROOT/回退基线.md（人读视图）
#   rdsh state sync [<目标>|--all]        # 把账本回写成各检出的 .installed（刷新回声）
#   rdsh state journal [-n N]             # 看事件流水（只追加，永不改写历史）
#   rdsh state --init [--dry-run]         # 首次播种：从现有检出 + 旧 回退基线.md 反向推断，
#                                         #   逐条打印它推断了什么；旧手写历史移入
#                                         #   $STATE_ROOT/回退基线-历史.md 留档（不删）
#   rdsh state record-migration <源> <目标> [--backup DIR] [--sessions S] [--probe 结论]
#                                         # migrate.sh 专用的窄接口：只追加迁移事件 + 两个字段
#   账本落点：$BASE/.dsh-suite/state/{versions.kv,journal.log}（700）
#   回声：各检出里的 .installed（KEY=VALUE；存在仍表示"已构建"，并已加进 .git/info/exclude）
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
#     # 需要时可逐项覆盖：MANAGE_ROOT= / DATA_ROOT= / BACKUP_ROOT= / SHARED_ROOT= / LOG_DIR= / STATE_ROOT=
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
_state="$(expand "${RDSH_STATE_ROOT:-$(cfg_get STATE_ROOT)}")"
_trash="$(expand "${RDSH_TRASH:-$(cfg_get TRASH_ROOT)}")"
_patches="$(expand "${RDSH_PATCHES:-$(cfg_get PATCHES)}")"
_mydsh="$(expand "${RDSH_MYDSH_REPO:-$(cfg_get MYDSH_REPO)}")"
_plugin="$(expand "${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}")"

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
# 状态账本（唯一权威）：回答"谁是什么角色"。此前三份手写状态（检出里的 .installed、
# 实例注册表、$BACKUP_ROOT/回退基线.md）会漂移；现在收成一处，其余是它的回声/视图。
STATE_ROOT="${_state:-$BASE/.dsh-suite/state}"
STATE_KV="$STATE_ROOT/versions.kv"        # 当前真值（本工具唯一可写状态源）
STATE_JOURNAL="$STATE_ROOT/journal.log"   # 只追加的事件流水（审计）
STATE_HISTORY="$STATE_ROOT/回退基线-历史.md" # 迁移期手写历史的留档（首次 --init 时移入）
BASELINE_MD="$BACKUP_ROOT/回退基线.md"     # 人读视图：由上面三者生成，不再手写
# 回收站（"永不 rm" 的落点）。**默认与 BASE 同一文件系统**：跨设备 mv 会退化成"复制+删除"，
# 慢且需要额外空间；旧默认 /tmp 还可能是 tmpfs（≈内存），搬 GB 级目录有 OOM 风险。
TRASH_ROOT="${_trash:-$BASE/.dsh-suite/trash}"
TRASH_INDEX="$TRASH_ROOT/index.log"        # 只追加的回收流水
TRASH_KEEP_DAYS="${RDSH_TRASH_KEEP_DAYS:-7}" # 小于这个天数的回收项，purge 需要 --force
PATCHES_ROOT="${_patches:-$BASE/dsh-patches}"   # 补丁仓（与 patch-manager.sh 同默认）
PLUGIN_ROOT="${_plugin:-$BASE/dsh-plugins}"      # 插件权威副本（与 plugin-sync.sh 同默认）
SNAP_ROOT="$BACKUP_ROOT/snapshots"               # 增量快照根（每版本一目录，内含各时间戳快照）
STATE_SNAP_ROOT="$BACKUP_ROOT/state-snapshots"   # 状态账本的本地快照（按用户裁定：state 只本地备份，不进仓）
MYDSH_REPO="${_mydsh:-}"                         # 「我的 dsh」本地克隆路径（restore --from 可省）
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
  if [ "${#ENTRIES[@]}" -eq 0 ]; then
    # state/du 这类子命令在"还没有任何检出"时也要能跑（只看账本/只看衍生物）
    [ "${ALLOW_NO_ENTRIES:-0}" = "1" ] && return 0
    die "未找到任何 dsh 检出（$MANAGE_ROOT 下无版本目录，也无 .map 外部登记）"
  fi
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

entry_key() {  # <entry> → state 账本里的对象键。B1 用版本号；B7 起同版本多份会带 -2 次号
  local ver; ver=$(entry_field "$1" 1)
  printf '%s' "$ver"
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
  local i=1 e ver dir base data key role
  printf '\n可用 dsh 版本：\n'
  for e in "${ENTRIES[@]}"; do
    ver=$(entry_field "$e" 1); dir=$(entry_field "$e" 2); base=$(entry_field "$e" 3); data=$(entry_field "$e" 4)
    key=$(entry_key "$e"); role="$(state_role_of "$key")"
    printf '  [%d] %-14s %-12s %-16s 检出: %s\n' "$i" "$ver" "$(built_status "$dir")" "$role" "$base"
    printf '       数据: %s (%s)\n' "$data" "$(data_state "$data")"
    i=$((i+1))
  done
  printf '       角色来自状态账本：rdsh state（current/baseline/retire-candidate/retired/installed）\n'
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
    # 自愈：检出就绪但账本里没有它 → 补登记（只写事实，不改角色）
    state_sync_checkout "$dir" || true
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
  state_record_install "$dir"
  log '安装完成(.installed + 状态账本已登记)'
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
  local p
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
  # 整个环境（home + 清单文件）作为**一个**回收条目挪走：清单里带逐项还原命令
  local -a srcs=()
  for x in $ids; do
    [ -e "$(debug_home "$x")" ] && srcs+=("$(debug_home "$x")")
    [ -e "$(debug_env_file "$x")" ] && srcs+=("$(debug_env_file "$x")")
  done
  if [ "${#srcs[@]}" -gt 0 ]; then
    trash_mv --label "debug-${ids// /+}" --reason "调试环境删除：$ids" "${srcs[@]}" || warn '回收条目创建失败'
    log "已挪走：$ids"
  else
    warn '没有需要挪走的东西'
  fi
  log "还原：rdsh trash ls 看条目 → rdsh trash restore <条目>（或直接照 .rdsh-trash.kv 里的 restore.N 行）"
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

# ---------------- backup：数据 home 与状态账本 的**本地**快照 ----------------
# 为什么是本地：会话数据（sessions/storages/workspace.json）不进任何仓库（隐私），
# 恢复只从本地指定目录读。state 账本同理（用户 2026-09-29 裁定）。
# 两种模式：
#   --full（默认，兼容旧行为）  cp -a 全量
#   --snapshot                 rsync -a --link-dest=<上一份> → 未变化的文件是**硬链接**，
#                              只存变化，GB 级数据天天跑才可持续
# 布局：$BACKUP_ROOT/snapshots/<版本>/<时间戳>/{MANIFEST.kv, 文件…}
#       $BACKUP_ROOT/state-snapshots/<时间戳>/{MANIFEST.kv, 账本…}
backup_stamp() { date +%Y%m%d-%H%M%S; }
snap_dir_of()  { printf '%s/%s' "$SNAP_ROOT" "$1"; }
snap_latest()  { ls -1dt "$(snap_dir_of "$1")"/*/ 2>/dev/null | sed -n '1p' || true; }
snap_count()   { du_count "$(snap_dir_of "$1")"/*/; }
snap_files()   { [ -d "$1" ] || { printf '0'; return 0; }; find "$1" -mindepth 1 -type f ! -name MANIFEST.kv 2>/dev/null | wc -l; }
snap_meta()    { [ -d "$1" ] || return 0; find "$1" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null | sort; }

snap_manifest() {  # <快照目录> <字段> → 值
  sed -nE "s/^$2=(.*)$/\1/p" "$1/MANIFEST.kv" 2>/dev/null | tail -1
}

snap_write_manifest() {  # <快照目录> <版本> <源> <模式> [link-dest]
  local d="$1" ver="$2" src="$3" mode="$4" ld="${5:-}"
  local n sz
  n="$(snap_files "$d")"          # snap_files 已排除 MANIFEST.kv（别在这里再减 1）
  sz="$(du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
  ( umask 077
    { printf 'version=%s\nat=%s\nsource=%s\nmode=%s\nlink_dest=%s\nfiles=%s\nsize=%s\n' \
        "$ver" "$(date -Is)" "$src" "$mode" "$ld" "$n" "$sz"
    } > "$d/MANIFEST.kv" )
}

snap_verify() {  # <快照目录> → 0 一致 / 1 有差异；打印核查了几个文件
  local d="$1"
  [ -d "$d" ] || { warn "不是目录：$d"; return 1; }
  [ -f "$d/MANIFEST.kv" ] || { warn "缺 MANIFEST.kv（不是 rdsh 快照？）：$d"; return 1; }
  local src mode files_claim
  src="$(snap_manifest "$d" source)"; mode="$(snap_manifest "$d" mode)"; files_claim="$(snap_manifest "$d" files)"
  local n_snap; n_snap="$(snap_files "$d")"
  log "核查快照：$d（模式 ${mode:-?}，源 ${src:-?}）"
  printf '  快照内文件：%s 个（清单记 %s 个）\n' "$n_snap" "${files_claim:-?}"
  local bad=0
  [ "$n_snap" = "${files_claim:-$n_snap}" ] || { warn '文件数与清单不符'; bad=1; }
  # **内部一致性**（判据的基石）：MANIFEST 是最后写的，快照定稿后不该再有文件比它新。
  # 这条既能抓"快照被就地改动"，又不会被"源在快照之后正常变化"误伤 ——
  # 所以不用"快照 vs 源"的差异当失败（那是不可靠的判据，源变了差异自然有）。
  local touched=""
  touched="$(find "$d" -type f ! -name MANIFEST.kv -newer "$d/MANIFEST.kv" 2>/dev/null | wc -l)"
  if [ "${touched:-0}" = "0" ]; then
    printf '  [ok] %s 个文件都在定稿时间之前（快照未被就地改动）\n' "$n_snap"
  else
    warn "$touched 个文件比 MANIFEST 还新 → 快照定稿后被改动过（或源在快照后又在同路径写过）"
    find "$d" -type f ! -name MANIFEST.kv -newer "$d/MANIFEST.kv" 2>/dev/null | sed -n '1,5p' | sed 's/^/      /'
    bad=1
  fi
  local unreadable; unreadable="$(find "$d" -type f ! -readable 2>/dev/null | wc -l)"
  [ "${unreadable:-0}" = "0" ] || { warn "$unreadable 个文件不可读"; bad=1; }
  if [ -d "$src" ]; then
    # 与源比对只作**参考信息**，不当失败判据
    local ndiff
    ndiff="$(diff <(snap_meta "$src") <(snap_meta "$d") 2>/dev/null | grep -c '^[<>]' || true)"
    printf '  参考：与源逐文件比（体积+mtime）%s 行不同（源在快照后可能正常变过，不代表快照坏了）\n' "${ndiff:-0}"
  else
    printf '  源已不在（%s）→ 只做内部一致性核查\n' "${src:-?}"
  fi
  return "$bad"
}

snap_prune() {  # <版本> <保留份数>：超出的挪进回收站（永不 rm）
  local ver="$1" keep="$2" i=0 d
  case "$keep" in ''|*[!0-9]*) die "--keep 需要正整数（收到：$keep）" ;; esac
  [ "$keep" -ge 1 ] || die '--keep 需要 ≥1'
  local n; n="$(snap_count "$ver")"
  if [ "$n" -le "$keep" ]; then log "快照 $n 份 ≤ 保留 $keep 份，无需清理"; return 0; fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    i=$((i+1))
    if [ "$i" -gt "$keep" ]; then
      trash_mv --label "snapshot-$ver-$(basename "$d")" --reason "备份保留策略：--keep $keep" "$d" || warn "挪走失败：$d"
    fi
  done < <(ls -1dt "$(snap_dir_of "$ver")"/*/ 2>/dev/null || true)
  log "保留最新 $keep 份，其余已挪进回收站（rdsh trash ls 可还原）"
}

backup_one() {  # <版本> <源目录> <模式> [标签] [dry|live] → **stdout 只返回快照路径**
  local ver="$1" src="$2" mode="$3" label="${4:-}" flag="${5:-live}"
  local dry=0; [ "$flag" = "dry" ] && dry=1
  # 注意：本函数的 **stdout 只用于返回快照路径**（会被 $( ) 捕获），
  # 所有叙述/进度必须走 stderr —— 否则日志会被吞进变量、路径也脏掉（本批踩到）。
  [ -d "$src" ] || { warn "源不存在，跳过：$src" >&2; return 1; }
  local dest_dir dest prev=""
  dest_dir="$(snap_dir_of "$ver")"
  dest="$dest_dir/$(backup_stamp)"
  local _k=2                      # 同一秒内连做两次 → 目录名会撞，加序号
  while [ -e "$dest" ]; do dest="$dest_dir/$(backup_stamp)-$_k"; _k=$((_k+1)); done
  [ "$mode" = "snapshot" ] && prev="$(snap_latest "$ver")"
  if [ "$dry" = "1" ]; then
    printf '  [dry-run] %s → %s（%s%s）\n' "$src" "$dest" "$mode" "${prev:+，硬链接基准 $(basename "$prev")}" >&2
    return 0
  fi
  local sz_before=0
  sz_before="$(du -sk "$dest_dir" 2>/dev/null | cut -f1 || echo 0)"
  mkdir -p "$dest"
  if [ "$mode" = "snapshot" ]; then
    command -v rsync >/dev/null || { rmdir "$dest" 2>/dev/null || true; die '增量快照需要 rsync（没有它就用默认的全量备份）'; }
    log "快照 $ver：rsync -a --delete${prev:+ --link-dest=$(basename "$prev")} …" >&2
    local -a args=(-a --delete)
    [ -n "$prev" ] && args+=(--link-dest="$prev")
    if ! rsync "${args[@]}" "$src/" "$dest/"; then
      trash_mv --label "snapshot-failed-$ver" --reason 'rsync 失败的半成品' "$dest" || true
      die "rsync 失败，半成品已挪进回收站：$dest"
    fi
  else
    if ! cp -a "$src/." "$dest/"; then
      trash_mv --label "backup-failed-$ver" --reason 'cp 失败的半成品' "$dest" || true
      die "cp -a 失败，半成品已挪进回收站：$dest"
    fi
  fi
  snap_write_manifest "$dest" "$ver" "$src" "$mode" "${prev:-}"
  # 「实际新增」= 版本目录 du 的差（du 在同一次遍历里对硬链接只算一次）——
  # 表观大小 `du -sh $dest` 会把与旧快照共享的硬链接也计入，直接报它会误导。
  local sz_after=0 added=0
  sz_after="$(du -sk "$dest_dir" 2>/dev/null | cut -f1 || echo 0)"
  added=$(( sz_after - ${sz_before:-0} )); [ "$added" -lt 0 ] && added=0
  { printf 'added_kb=%s\n' "$added"; } >> "$dest/MANIFEST.kv"
  # 边界（实测过的坑）：**不要**把快照文件置只读来"防篡改" —— `--link-dest` 的快速校验
  # 比的是"全部保留属性"，快照文件只读(0444)与源(0644)权限不同 → rsync 认为文件变了 →
  # 不再硬链接，增量快照当场退化成全量。篡改由 `--verify`（比 MANIFEST 新的文件）来发现。
  log "快照完成：$dest（$(snap_manifest "$dest" files) 个文件）" >&2
  if [ -n "$prev" ]; then
    log "  实际新增 $(numfmt --to=iec $(( added * 1024 )) 2>/dev/null || printf '%sKB' "$added")；表观 $(du -sh "$dest" 2>/dev/null | cut -f1)（其余与 $(basename "$prev") 共享硬链接）" >&2
  else
    log "  实际占用 $(du -sh "$dest" 2>/dev/null | cut -f1)" >&2
  fi
  printf '%s\n' "$dest"
}

backup_state() {  # [dry|live]：把状态账本快照到本地（不进仓库）；**stdout 只返回快照路径**
  local dry=0; [ "${1:-live}" = "dry" ] && dry=1
  [ -d "$STATE_ROOT" ] || { warn "没有状态账本（$STATE_ROOT）→ 跳过" >&2; return 0; }
  local dest="$STATE_SNAP_ROOT/$(backup_stamp)"
  if [ "$dry" = "1" ]; then printf '  [dry-run] %s → %s（state 只本地备份，不进仓库）\n' "$STATE_ROOT" "$dest" >&2; return 0; fi
  mkdir -p "$dest"
  if ! cp -a "$STATE_ROOT/." "$dest/"; then
    trash_mv --label 'state-snapshot-failed' --reason 'cp 失败的半成品' "$dest" || true
    die "状态账本快照失败，半成品已挪进回收站：$dest"
  fi
  snap_write_manifest "$dest" 'state' "$STATE_ROOT" 'full' ''
  log "状态账本快照完成：$dest（$(du -sh "$dest" 2>/dev/null | cut -f1)）" >&2
  printf '%s\n' "$dest"
}

backup_list() {  # [<版本>]
  local only="${1:-}"
  log "快照根：$SNAP_ROOT"
  local d ver s
  if [ -d "$SNAP_ROOT" ]; then
    for d in "$SNAP_ROOT"/*/; do
      [ -d "$d" ] || continue
      ver="$(basename "$d")"
      [ -n "$only" ] && [ "$ver" != "$only" ] && continue
      printf '  %-16s %s 份  共 %s\n' "$ver" "$(du_count "$d"*/)" "$(du_size "$d")"
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        local ak show
        ak="$(snap_manifest "$s" added_kb)"
        if [ -n "$ak" ]; then show="$(numfmt --to=iec $(( ak * 1024 )) 2>/dev/null || printf '%sKB' "$ak") 新增"
        else show="$(snap_manifest "$s" size)"; fi
        printf '      %-18s %-12s %s 个文件  %-9s %s\n' "$(basename "$s")" "$show" \
          "$(snap_manifest "$s" files)" "$(snap_manifest "$s" mode)" \
          "$([ -n "$(snap_manifest "$s" link_dest)" ] && printf '硬链接自 %s（表观 %s）' "$(basename "$(snap_manifest "$s" link_dest)")" "$(snap_manifest "$s" size)")"
      done < <(ls -1dt "$d"*/ 2>/dev/null || true)
    done
  else
    printf '  （还没有任何快照）\n'
  fi
  printf '  %-16s %s 份  共 %s\n' '状态账本' "$(du_count "$STATE_SNAP_ROOT"/*/)" "$(du_size "$STATE_SNAP_ROOT")"
  printf '  旧式全量备份（%s 下）：%s 个目录\n' "$BACKUP_ROOT" "$(du_count "$BACKUP_ROOT"/*/)"
}

cmd_backup() {
  local ver_arg="" mode="full" want_state=0 verify=0 keep="" do_list=0 dry=0 verify_only="" label="" a
  local -a rest=()
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --snapshot) mode="snapshot" ;;
      --full) mode="full" ;;
      --state) want_state=1 ;;
      --all) ver_arg="__ALL__" ;;
      --verify) verify=1 ;;
      --keep) shift; keep="${1:-}" ;;
      --keep=*) keep="${a#--keep=}" ;;
      --list) do_list=1 ;;
      --label) shift; label="${1:-}" ;;
      --label=*) label="${a#--label=}" ;;
      --dry-run|-n) dry=1 ;;
      -*) die "未知选项：$a（rdsh backup [<目标>|--all] [--snapshot|--full] [--state] [--verify] [--keep N] [--list] [--dry-run]）" ;;
      *) rest+=("$a") ;;
    esac
    shift || true
  done
  if [ "$verify" = "1" ] && [ "${#rest[@]}" -gt 0 ] && [ -f "${rest[0]}/MANIFEST.kv" ]; then
    verify_only="${rest[0]}"          # 兼容：rdsh backup --verify <快照目录>
  fi
  if [ -n "$verify_only" ]; then snap_verify "$verify_only"; return $?; fi
  [ -n "$keep" ] && case "$keep" in ''|*[!0-9]*) die "--keep 需要正整数（收到：$keep）" ;; esac
  [ -n "$ver_arg" ] || ver_arg="${rest[0]:-}"     # 位置参数（版本/序号）也认
  if [ "$do_list" = "1" ]; then backup_list "${rest[0]:-}"; return 0; fi
  [ -n "$ver_arg" ] || [ "$want_state" = "1" ] || die '用法: rdsh backup <目标|--all> [--snapshot] [--state] [--verify] [--keep N] [--dry-run]
       rdsh backup --list [<版本>]
       rdsh backup --verify <快照目录>'

  local failed=0
  if [ "$want_state" = "1" ] || [ "$ver_arg" = "__ALL__" ]; then
    backup_state "$([ "$dry" = "1" ] && echo dry || echo live)" || failed=$((failed+1))
  fi
  if [ "$ver_arg" = "__ALL__" ]; then
    local e ver data snap
    for e in "${ENTRIES[@]:-}"; do
      [ -n "$e" ] || continue
      ver="$(entry_field "$e" 1)"; data="$(entry_field "$e" 4)"
      [ -d "$data" ] || { warn "$ver：无数据目录，跳过"; continue; }
      snap="$(backup_one "$ver" "$data" "$mode" "$label" "$([ "$dry" = "1" ] && echo dry || echo live)")" || failed=$((failed+1))
      if [ "$verify" = "1" ] && [ -n "$snap" ] && [ -f "$snap/MANIFEST.kv" ]; then snap_verify "$snap" || failed=$((failed+1)); fi
      if [ -n "$keep" ] && [ "$dry" != "1" ]; then snap_prune "$ver" "$keep"; fi
    done
  elif [ -n "$ver_arg" ]; then
    local entry; entry="$(resolve_target "$ver_arg")"
    [[ "$entry" == UNMANAGED:* ]] && die '该检出未纳入管理'
    local ver data snap
    ver="$(entry_field "$entry" 1)"; data="$(entry_field "$entry" 4)"
    [ -d "$data" ] || die "版本 $ver 尚无数据目录（$data）"
    snap="$(backup_one "$ver" "$data" "$mode" "$label" "$([ "$dry" = "1" ] && echo dry || echo live)")" || failed=$((failed+1))
    if [ "$verify" = "1" ] && [ -n "$snap" ] && [ -f "$snap/MANIFEST.kv" ]; then snap_verify "$snap" || failed=$((failed+1)); fi
    if [ -n "$keep" ] && [ "$dry" != "1" ]; then snap_prune "$ver" "$keep"; fi
  fi
  [ "$failed" = "0" ] || { warn "$failed 项未完成"; return 1; }
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
  printf '  状态账本   : %s（唯一权威）\n' "$STATE_ROOT"
  printf '  回收站     : %s（同文件系统：%s）\n' "$TRASH_ROOT" "$( [ -d "$TRASH_ROOT" ] && [ "$(trash_fs_of "$TRASH_ROOT")" = "$(trash_fs_of "$BASE")" ] && echo 是 || echo '否/待建' )"
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

# ---------------- state：状态账本（唯一权威） ----------------
# 定位：回答"谁是什么角色"。此前三份手写状态（检出里的 .installed、实例注册表、
# $BACKUP_ROOT/回退基线.md）必然漂移；本模块把它们收成一处：
#   权威 : $STATE_KV      —— 当前真值；本工具唯一可写状态源，原子替换（tmp+mv）
#   流水 : $STATE_JOURNAL —— **只追加**；行格式 时间|事件|对象|细节
#   回声 : <检出>/.installed —— KEY=VALUE；存在仍表示"已构建"，并已加进 .git/info/exclude
#   视图 : $BASELINE_MD   —— 人读；由上面三者生成，不再手写
# 原则不变（P1）：只检测、只留痕、只放行；历史只追加，删除留墓碑。
STATE_FIELDS="key version role role_set_at installed_at source commit built_at migrated_from baseline_for dir data note"
STATE_ROLES="installed current baseline retire-candidate retired"

state_ensure() {
  mkdir -p "$STATE_ROOT"; chmod 700 "$STATE_ROOT" 2>/dev/null || true
  if [ ! -f "$STATE_KV" ]; then
    ( umask 077
      { printf '# rdsh state —— DSH 对象状态账本（唯一权威；由 rdsh 写入，手改前请先备份）\n'
        printf '# 字段: %s\n' "$(printf '%s' "$STATE_FIELDS" | tr ' ' '|')"
        printf '# 角色: installed(已安装未定) | current(当前在用) | baseline(回退基线) | retire-candidate(可删) | retired(已退役)\n'
      } > "$STATE_KV" )
  fi
  [ -f "$STATE_JOURNAL" ] || ( umask 077; printf '# rdsh journal —— 只追加的事件流水（时间|事件|对象|细节）\n' > "$STATE_JOURNAL" )
}

state_journal() {  # <事件> <对象键> [细节...]
  state_ensure
  local ev="$1"; shift || true
  local key="$1"; shift || true
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr '\n' ' ' | tr '|' '/')"
  ( umask 077; printf '%s|%s|%s|%s\n' "$(date -Is)" "$ev" "$key" "$detail" >> "$STATE_JOURNAL" )
}

state_col_of() {  # <字段名> → 列号
  local i=1 f
  for f in $STATE_FIELDS; do
    [ "$f" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i+1))
  done
  return 1
}

state_kv_get() {  # <对象键> <字段> → 值（无则空）
  [ -f "$STATE_KV" ] || return 0
  local col; col="$(state_col_of "$2")" || return 0
  awk -F'|' -v k="$1" -v c="$col" '!/^#/ && NF>0 && $1==k { print $c; exit }' "$STATE_KV"
}

state_kv_has() {  # <对象键>
  [ -n "$(state_kv_get "$1" key)" ]
}

state_kv_set() {  # <对象键> <字段> <值>：行不存在则新建；原子替换
  state_ensure
  local col; col="$(state_col_of "$2")" || die "state: 未知字段“$2”"
  local v; v="$(printf '%s' "$3" | tr '\n' ' ' | tr '|' '/')"
  local nf; nf="$(printf '%s' "$STATE_FIELDS" | wc -w)"
  local tmp="$STATE_KV.tmp.$$"
  ( umask 077
    awk -F'|' -v OFS='|' -v k="$1" -v c="$col" -v v="$v" -v nf="$nf" '
      /^#/ { print; next }
      NF==0 { next }
      { if ($1==k) { found=1; $c=v } print }
      END {
        if (!found) {
          row=""
          for (i=1;i<=nf;i++) row = row ((i==1)?"":"|") ((i==c)?v:"")
          print row
        }
      }' "$STATE_KV" > "$tmp" ) && mv -f "$tmp" "$STATE_KV"
}

state_keys() {  # 所有对象键（按账本顺序）
  [ -f "$STATE_KV" ] || return 0
  awk -F'|' '!/^#/ && NF>0 && $1!="" { print $1 }' "$STATE_KV"
}

state_role_of() {  # <对象键> → 角色（无则 -）
  local r; r="$(state_kv_get "$1" role)"
  printf '%s' "${r:--}"
}

state_key_for_dir() {  # <检出目录> → 对象键（按 dir 字段找）
  [ -f "$STATE_KV" ] || return 0
  local col; col="$(state_col_of dir)" || return 0
  awk -F'|' -v d="$1" -v c="$col" '!/^#/ && NF>0 && $c==d { print $1; exit }' "$STATE_KV"
}

state_current_key() {  # 账本里 role=current 的对象（无则空）
  awk -F'|' '!/^#/ && NF>0 && $3=="current" { print $1; exit }' "$STATE_KV" 2>/dev/null || true
}

state_commit_of() {  # <检出目录> → 短 commit（无 git 则空）
  [ -d "$1/.git" ] && git -C "$1" rev-parse --short HEAD 2>/dev/null || true
}

state_source_of() {  # <检出目录> → 来源（远端 URL / 本地路径）
  local dir="$1" url=""
  if [ -d "$dir/.git" ]; then url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"; fi
  if [ -n "$url" ]; then printf 'git:%s' "$url"; else printf 'local:%s' "$dir"; fi
}

state_data_for_dir() {  # <检出目录> → 该检出的数据目录（.map 优先，其次 DATA_ROOT/<版本>）
  local dir="$1" e=""
  if [ "${#ENTRIES[@]}" -gt 0 ]; then
    e="$(entry_by_dir "$dir" 2>/dev/null || true)"
    [ -n "$e" ] && { entry_field "$e" 4; return 0; }
  fi
  printf '%s/%s' "$DATA_ROOT" "$(read_version "$dir")"
}

state_git_exclude() {  # <检出目录>：把 .installed 写进 .git/info/exclude（本地，不进上游）
  local dir="$1" xf="$1/.git/info/exclude"
  [ -d "$dir/.git" ] || return 0
  mkdir -p "$dir/.git/info" 2>/dev/null || return 0
  [ -f "$xf" ] || : > "$xf"
  grep -qxF '.installed' "$xf" 2>/dev/null || printf '.installed\n' >> "$xf"
}

state_echo_installed() {  # <检出目录>：把账本回写成 .installed（KEY=VALUE）
  local dir="$1" key; [ -n "$dir" ] || return 0
  key="$(state_key_for_dir "$dir")"
  [ -n "$key" ] || return 0
  local n; n="$(grep -c '' "$STATE_JOURNAL" 2>/dev/null || echo 0)"
  ( umask 022
    { printf '# rdsh —— 检出状态回声；权威是 %s（可由 rdsh state render 重建）\n' "$STATE_KV"
      printf 'key=%s\n'            "$key"
      printf 'version=%s\n'        "$(state_kv_get "$key" version)"
      printf 'role=%s\n'           "$(state_kv_get "$key" role)"
      printf 'installed_at=%s\n'   "$(state_kv_get "$key" installed_at)"
      printf 'source=%s\n'         "$(state_kv_get "$key" source)"
      printf 'commit=%s\n'         "$(state_kv_get "$key" commit)"
      printf 'built_at=%s\n'       "$(state_kv_get "$key" built_at)"
      printf 'migrated_from=%s\n'  "$(state_kv_get "$key" migrated_from)"
      printf 'baseline_for=%s\n'   "$(state_kv_get "$key" baseline_for)"
      printf 'state_journal_lines=%s\n' "$n"
    } > "$dir/.installed" )
}

state_set_role() {  # <对象键> <角色> [依据]
  local key="$1" role="$2" why="${3:-}"
  case " $STATE_ROLES " in *" $role "*) ;; *) die "state: 角色只能是 $STATE_ROLES（收到：$role）" ;; esac
  # 不凭空造对象：打错名字必须报错，而不是静默新建一行幽灵记录
  state_kv_has "$key" || die "state: 账本里没有对象“$key”（rdsh state list 看全部；先 rdsh state --init 播种）"
  state_kv_set "$key" role "$role"
  state_kv_set "$key" role_set_at "$(date -Is)"
  state_journal role "$key" "$role${why:+（$why）}"
  local d; d="$(state_kv_get "$key" dir)"
  [ -n "$d" ] && state_echo_installed "$d" 2>/dev/null || true
  log "角色已改：$key → $role"
}

state_record_install() {  # <检出目录> [角色]：安装完成时登记（幂等）
  local dir ver key role other inst built src
  dir="$(readlink -f "$1")"
  ver="$(read_version "$dir")"
  key="$(state_key_for_dir "$dir")"; [ -n "$key" ] || key="$ver"
  other="$(state_kv_get "$key" dir)"
  if [ -n "$other" ] && [ "$other" != "$dir" ]; then
    warn "同版本第二份检出：账本键 $key 已指向 $other → 本次不覆盖（同版本共存的 -2 次号是 B7 的事）"
    return 1
  fi
  role="${2:-}"
  if [ -z "$role" ]; then
    role="$(state_kv_get "$key" role)"
    if [ -z "$role" ]; then
      if [ -z "$(state_current_key)" ]; then role=current; else role=installed; fi
    fi
  fi
  inst="$(state_kv_get "$key" installed_at)"
  if [ -z "$inst" ]; then
    # 首次登记：有 .installed 就用它的 mtime（事实），否则记当下
    inst="$( ( [ -f "$dir/.installed" ] && date -Is -r "$dir/.installed" ) 2>/dev/null || date -Is )"
  fi
  built="$( ( [ -f "$dir/.installed" ] && date -Is -r "$dir/.installed" ) 2>/dev/null || date -Is )"
  src="$(state_source_of "$dir")"
  state_kv_set "$key" key "$key"
  state_kv_set "$key" version "$ver"
  state_kv_set "$key" role "$role"
  state_kv_set "$key" installed_at "$inst"
  state_kv_set "$key" built_at "$built"
  state_kv_set "$key" source "$src"
  state_kv_set "$key" commit "$(state_commit_of "$dir")"
  state_kv_set "$key" dir "$dir"
  state_kv_set "$key" data "$(state_data_for_dir "$dir")"
  state_git_exclude "$dir"
  state_echo_installed "$dir"
  state_journal install "$key" "dir=$dir role=$role source=$src"
  log "已登记状态：$key（role=$role）"
}

state_sync_checkout() {  # <检出目录>：账本缺该目录时补登记（只写事实）
  local dir; dir="$(readlink -f "$1")"
  [ -n "$(state_key_for_dir "$dir")" ] && return 0
  state_record_install "$dir" || true
}

state_running_versions() {  # 正在跑的实例对应的版本（去重；只用于展示）
  local p _pid ver _dir _data _kind _id _unit _st
  while IFS='|' read -r p _pid ver _dir _data _kind _id _unit _st; do
    [ -n "$p" ] || continue
    [ -n "$ver" ] || continue
    printf '%s\n' "$ver"
  done <<< "$(instances_live)" | sort -u || true
  return 0
}

state_running_keys() {  # 正在跑的实例 → 账本对象键（宿主状态不会污染隔离环境）
  # 匹配顺序：账本 dir 字段 → 已管理条目（首次播种时账本还是空的，得靠后者）
  # 注意：`while read` 读到 EOF 会返回非零，管道 + pipefail 会把它当失败 → 必须兜底
  local p _pid ver dir _data _kind _id _unit _st k e
  while IFS='|' read -r p _pid ver dir _data _kind _id _unit _st; do
    [ -n "$p" ] || continue
    k="$(state_key_for_dir "$dir" 2>/dev/null || true)"
    if [ -z "$k" ] && [ "${#ENTRIES[@]}" -gt 0 ]; then
      e="$(entry_by_dir "$dir" 2>/dev/null || true)"
      [ -n "$e" ] && k="$(entry_key "$e")"
    fi
    [ -n "$k" ] && printf '%s\n' "$k"
  done <<< "$(instances_live)" | sort -u || true
  return 0
}

state_baseline_hint_from_md() {  # <旧回退基线.md> → 推"最后一条回退动作的目标版本"
  local f="$1" v=""
  [ -f "$f" ] || return 0
  v="$(grep -oE 'rdsh (start|run) [^ `)]+' "$f" 2>/dev/null | tail -1 | awk '{print $3}')"
  [ -n "$v" ] || v="$(grep -oE '源 home：[[:space:]]*[^ ]+' "$f" 2>/dev/null | tail -1 | sed -E 's|.*/||')"
  printf '%s' "$v"
}

state_sync() {  # [<目标>|--all]：把账本回写成 .installed（刷新回声）+ 补 .git/info/exclude
  [ -f "$STATE_KV" ] || { warn "账本不存在（先 rdsh state --init）"; return 1; }
  local arg="${1:-}" k n=0 d
  if [ -n "$arg" ] && [ "$arg" != "--all" ]; then
    k="$(state_key_for_arg "$arg")" || die "账本里没有对象匹配“$arg”（rdsh state list 看全部）"
    d="$(state_kv_get "$k" dir)"
    [ -n "$d" ] && { state_echo_installed "$d"; state_git_exclude "$d"; }
    log "已刷新回声：$k"
    return 0
  fi
  local total; total="$(state_keys | grep -c . || true)"
  state_journal sync - "刷新 $total 个检出的回声"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    d="$(state_kv_get "$k" dir)"
    [ -n "$d" ] || continue
    state_echo_installed "$d" && n=$((n+1))
    state_git_exclude "$d"
  done < <(state_keys)
  log "已刷新 $n 个检出的 .installed 回声"
}

state_record_migration() {  # <源> <目标> [--backup DIR] [--sessions S] [--probe 结论] [--dry-run]
  # 给 migrate.sh 用的窄接口：只追加一条迁移事件 + 两个字段，不碰角色（角色是人或"在跑的实例"定的）
  local src="" dst="" backup="" sessions="" probe="" dry=0 a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --backup)     shift; backup="${1:-}" ;;
      --backup=*)   backup="${a#--backup=}" ;;
      --sessions)   shift; sessions="${1:-}" ;;
      --sessions=*) sessions="${a#--sessions=}" ;;
      --probe)      shift; probe="${1:-}" ;;
      --probe=*)    probe="${a#--probe=}" ;;
      --dry-run|-n) dry=1 ;;
      -*) die "未知选项：$a（state record-migration <源> <目标> [--backup DIR] [--sessions S] [--probe 结论] [--dry-run]）" ;;
      *) if [ -z "$src" ]; then src="$a"; elif [ -z "$dst" ]; then dst="$a"; else die "多余参数：$a"; fi ;;
    esac
    shift || true
  done
  [ -n "$src" ] && [ -n "$dst" ] || die '用法: rdsh state record-migration <源> <目标> [--backup DIR] [--sessions S] [--probe 结论] [--dry-run]'
  local s d
  s="$(state_key_for_arg "$src" 2>/dev/null || true)"
  d="$(state_key_for_arg "$dst" 2>/dev/null || true)"
  if [ -z "$s" ] || [ -z "$d" ]; then
    warn "账本里找不到：$([ -z "$s" ] && printf '源=%s ' "$src")$([ -z "$d" ] && printf '目标=%s' "$dst")"
    warn '先播种账本：rdsh state --init'
    return 1
  fi
  if [ "$dry" = "1" ]; then
    printf '  [dry-run] 将记录迁移事件：%s → %s（backup=%s sessions=%s probe=%s）\n' \
      "$s" "$d" "${backup:-无}" "${sessions:-未记}" "${probe:-未取到}"
    return 0
  fi
  state_kv_set "$d" migrated_from "$s"
  state_kv_set "$s" baseline_for "$d"
  state_journal migrate "$d" "from=$s backup=${backup:-无} sessions=${sessions:-未记} probe=${probe:-未取到}"
  state_echo_installed "$(state_kv_get "$d" dir)" 2>/dev/null || true
  state_echo_installed "$(state_kv_get "$s" dir)" 2>/dev/null || true
  state_render_baseline || true
  log "已记录迁移：$s → $d"
  log "回退动作：停掉 $d 的实例 → rdsh start $s（源 home 全程只读）"
}

state_render_baseline() {  # 生成人读视图 $BASELINE_MD（拒绝覆盖手写文件）
  state_ensure
  if [ -f "$BASELINE_MD" ] && ! head -1 "$BASELINE_MD" | grep -q 'rdsh-generated'; then
    warn "$BASELINE_MD 没有 rdsh 生成标记（像是手写文件）→ 不覆盖。先跑：rdsh state --init"
    return 1
  fi
  mkdir -p "$(dirname "$BASELINE_MD")"
  local tmp="$BASELINE_MD.tmp.$$" k
  ( umask 077
    { printf '<!-- rdsh-generated —— 本文件由 rdsh 生成，勿手改；权威：%s -->\n' "$STATE_KV"
      printf '# 回退基线（生成于 %s）\n\n' "$(date -Is)"
      printf '> 回答两个问题：**万一要退，退到哪个版本？怎么退？** 角色定义见 `rdsh state`。\n\n'
      printf '## 当前对象与角色\n\n'
      printf '| 对象 | 版本 | 角色 | 安装时间 | 来源 | commit | 检出 |\n|---|---|---|---|---|---|---|\n'
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        printf '| %s | %s | %s | %s | %s | %s | `%s` |\n' \
          "$k" "$(state_kv_get "$k" version)" "$(state_kv_get "$k" role)" \
          "$(state_kv_get "$k" installed_at)" "$(state_kv_get "$k" source)" \
          "$(state_kv_get "$k" commit)" "$(state_kv_get "$k" dir)"
      done < <(state_keys)
      printf '\n## 事件流水（最近 40 条；全文见 `%s`）\n\n```\n' "$STATE_JOURNAL"
      grep -v '^#' "$STATE_JOURNAL" 2>/dev/null | tail -40 || true
      printf '```\n'
      if [ -f "$STATE_HISTORY" ]; then
        printf '\n---\n\n## 迁移期历史（2026-09-29 之前手写，原文留档）\n\n'
        cat "$STATE_HISTORY"
      fi
    } > "$tmp"
  ) && mv -f "$tmp" "$BASELINE_MD"
  log "已生成 $BASELINE_MD"
}

state_init() {  # 首次播种：从检出 + 旧 回退基线.md 反向推断，逐条打印依据
  local dry=0 a
  for a in "$@"; do case "$a" in --dry-run|-n) dry=1 ;; *) die "未知选项：$a（state --init [--dry-run]）" ;; esac; done
  [ "$dry" = "1" ] || state_ensure     # --dry-run 不落任何盘（连目录都不建）
  echo "账本：$STATE_KV"
  echo "流水：$STATE_JOURNAL"
  echo
  local e dir ver key registered=0 inferred=0 dup=0
  for e in "${ENTRIES[@]:-}"; do
    [ -n "$e" ] || continue
    dir="$(readlink -f "$(entry_field "$e" 2)")"
    ver="$(entry_field "$e" 1)"
    key="$(entry_key "$e")"
    if state_kv_has "$key"; then
      printf '  已登记  %-18s %s\n' "$key" "$dir"; registered=$((registered+1)); continue
    fi
    local other; other="$(state_kv_get "$key" dir)"
    if [ -n "$other" ] && [ "$other" != "$dir" ]; then
      warn "同版本第二份检出：键 $key 已指向 $other → 跳过 $dir（-2 次号是 B7 的事）"
      dup=$((dup+1)); continue
    fi
    local inst built src com
    if [ -f "$dir/.installed" ]; then
      inst="$(date -Is -r "$dir/.installed" 2>/dev/null || date -Is)"
      built="$inst"
      printf '  推断    %-18s 安装=%s（依据：.installed 的 mtime）\n' "$key" "$inst"
    else
      inst="$(date -Is -r "$dir" 2>/dev/null || date -Is)"
      built=""
      printf '  推断    %-18s 安装=%s（依据：检出目录 mtime；无 .installed）\n' "$key" "$inst"
    fi
    src="$(state_source_of "$dir")"; com="$(state_commit_of "$dir")"
    printf '          %-18s 来源=%s  commit=%s\n' '' "$src" "${com:-?}"
    inferred=$((inferred+1))
    [ "$dry" = "1" ] && continue
    state_kv_set "$key" key "$key"
    state_kv_set "$key" version "$ver"
    state_kv_set "$key" installed_at "$inst"
    state_kv_set "$key" built_at "$built"
    state_kv_set "$key" source "$src"
    state_kv_set "$key" commit "$com"
    state_kv_set "$key" dir "$dir"
    state_kv_set "$key" data "$(state_data_for_dir "$dir")"
    state_kv_set "$key" role installed
    state_kv_set "$key" note '由 state --init 播种'
    state_git_exclude "$dir"
    state_echo_installed "$dir"
    state_journal init "$key" "installed_at=$inst（推断）.installed mtime；source=$src"
  done

  # ---- 角色推断：只写有依据的，且逐条打印依据 ----
  local cur base hintfile="$BASELINE_MD" ncur
  ncur="$(state_running_keys | grep -c . || true)"
  cur="$(state_running_keys | sed -n '1p' || true)"   # sed 读尽输入，不用 head（避免提前关管 → SIGPIPE）
  if [ "${ncur:-0}" -gt 1 ]; then
    warn "有多个版本在运行 → current 不自动写，请用：rdsh state role <对象> current"
    cur=""
  fi
  base="$(state_baseline_hint_from_md "$hintfile")"
  echo
  if [ -n "$cur" ]; then
    printf '  角色推断 %-18s → current（依据：该版本正在运行，来自 ss + /proc）\n' "$cur"
  else
    printf '  角色推断 %-18s → （未定：没有唯一在跑的版本）\n' '-'
  fi
  if [ -n "$base" ] && [ "$base" != "$cur" ]; then
    printf '  角色推断 %-18s → baseline（依据：旧 %s 最后一条回退动作的目标）\n' "$base" "$BASELINE_MD"
  fi
  if [ "$dry" != "1" ]; then
    if [ -n "$cur" ] && state_kv_has "$cur"; then
      state_set_role "$cur" current '推断：该版本正在运行（ss+/proc）'
    fi
    if [ -n "$base" ] && [ "$base" != "$cur" ] && state_kv_has "$base"; then
      state_set_role "$base" baseline '推断：旧回退基线.md 最后一条回退动作的目标'
    fi
  fi

  # ---- 旧手写回退基线：移入历史留档（mv，不删），再生成人读视图 ----
  echo
  if [ -f "$BASELINE_MD" ] && ! head -1 "$BASELINE_MD" | grep -q 'rdsh-generated'; then
    if [ "$dry" = "1" ]; then
      printf '  [dry-run] 将把 %s 移入 %s（原文留档），随后重新生成人读视图\n' "$BASELINE_MD" "$STATE_HISTORY"
    else
      if [ ! -f "$STATE_HISTORY" ]; then
        mv "$BASELINE_MD" "$STATE_HISTORY"
        state_journal history "$BASELINE_MD" "移入 $STATE_HISTORY 留档（原文未改）"
        log "旧手写基线已留档：$STATE_HISTORY（还原：mv \"$STATE_HISTORY\" \"$BASELINE_MD\"）"
      else
        warn "$STATE_HISTORY 已存在 → 本次不再移动 $BASELINE_MD（请人工合并后删）"
      fi
      state_render_baseline || true
    fi
  elif [ "$dry" != "1" ]; then
    state_render_baseline || true
  fi
  echo
  log "播种完成：已登记 $registered 个，本次推断 $inferred 个，因同版本多份跳过 $dup 个"
  log "下一步：核对角色（rdsh state list），需要时 rdsh state role <对象> <角色>"
}

state_list() {
  if [ ! -f "$STATE_KV" ]; then
    warn "账本还不存在（$STATE_KV）。先跑：rdsh state --init"
    return 0
  fi
  local n; n="$(state_keys | grep -c . || true)"
  if [ "${n:-0}" = "0" ]; then
    warn "账本还是空的。先跑：rdsh state --init"
    return 0
  fi
  printf '\n状态账本（%s）—— %s 个对象：\n' "$STATE_KV" "$n"
  printf '  %-18s %-9s %-22s %-11s %s\n' '对象' '角色' '安装时间' 'commit' '检出'
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    printf '  %-18s %-9s %-22s %-11s %s\n' "$k" "$(state_role_of "$k")" \
      "$(state_kv_get "$k" installed_at)" "$(state_kv_get "$k" commit)" "$(state_kv_get "$k" dir)"
  done < <(state_keys)
  echo
  printf '  数据目录：\n'
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    printf '    %-18s %s\n' "$k" "$(state_kv_get "$k" data)"
  done < <(state_keys)
}

state_key_for_arg() {  # <目标串> → 对象键（检出 → 字面键 → 版本片段唯一命中）
  local arg="$1" e k hit="" n=0
  if [ "${#ENTRIES[@]}" -gt 0 ]; then
    e="$(resolve_target "$arg" 2>/dev/null || true)"
    case "$e" in UNMANAGED:*|"") ;; *) entry_key "$e"; return 0 ;; esac
  fi
  if state_kv_has "$arg"; then printf '%s' "$arg"; return 0; fi
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in *"$arg"*) hit="$k"; n=$((n+1)) ;; esac
  done < <(state_keys)
  [ "$n" = "1" ] && { printf '%s' "$hit"; return 0; }
  return 1
}

state_show() {
  local arg="${1:-}"; [ -n "$arg" ] || die '用法: rdsh state show <目标>'
  local key; key="$(state_key_for_arg "$arg")" || die "账本里没有对象匹配“$arg”（rdsh state list 看全部）"
  printf '\n对象：%s\n' "$key"
  local f
  for f in $STATE_FIELDS; do
    printf '  %-14s %s\n' "$f" "$(state_kv_get "$key" "$f")"
  done
  echo
  printf '  事件流水（该对象）：\n'
  grep -F "|$key|" "$STATE_JOURNAL" 2>/dev/null | sed 's/^/    /' || true
}

state_journal_tail() {
  local n=40 a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in -n|--lines) shift; n="${1:-40}" ;; *) die "未知选项：$a（journal [-n N]）" ;; esac
    shift || true
  done
  [ -f "$STATE_JOURNAL" ] || { warn "流水还不存在（$STATE_JOURNAL）。先跑：rdsh state --init"; return 0; }
  printf '\n事件流水（最近 %s 条；全文 %s）：\n' "$n" "$STATE_JOURNAL"
  grep -v '^#' "$STATE_JOURNAL" | tail -"$n" | sed 's/^/  /' || true
}

cmd_state() {
  local sub="list"
  if [ $# -gt 0 ]; then sub="$1"; shift; fi
  case "$sub" in
    list|ls) state_list ;;
    show) state_show "$@" ;;
    role)
      local arg="${1:-}" role="${2:-}"
      [ -n "$arg" ] && [ -n "$role" ] || die '用法: rdsh state role <目标> <current|baseline|retire-candidate|retired|installed>'
      local key; key="$(state_key_for_arg "$arg")" || die "账本里没有对象匹配“$arg”"
      state_set_role "$key" "$role" '人工指定'
      ;;
    render) state_render_baseline ;;
    sync) state_sync "$@" ;;
    record-migration|migration) state_record_migration "$@" ;;
    journal|log) state_journal_tail "$@" ;;
    init|--init) state_init "$@" ;;
    -h|--help|help)
      cat <<'USAGE'
rdsh state —— 状态账本（唯一权威）

用法:
  rdsh state [list]                        列出对象（角色/安装时间/来源/commit/检出/数据）
  rdsh state show <目标>                   看某对象全部字段 + 它的事件流水
  rdsh state role <目标> <角色>            改角色：installed|current|baseline|retire-candidate|retired
  rdsh state render                        重新生成 $BACKUP_ROOT/回退基线.md（人读视图）
  rdsh state journal [-n N]                看事件流水（只追加）
  rdsh state --init [--dry-run]            首次播种（从检出 + 旧回退基线.md 反向推断，打印依据）
  rdsh state record-migration <源> <目标> [--backup DIR] [--sessions S] [--probe 结论]
                                           migrate.sh 专用：追加一条迁移事件并重生成视图
                                           （不动角色：角色由人或"在跑的实例"决定）

落点（700）: $BASE/.dsh-suite/state/{versions.kv,journal.log}
回声:        各检出里的 .installed（KEY=VALUE；已加进 .git/info/exclude）
USAGE
      ;;
    *) die "用法: rdsh state [list|show <目标>|role <目标> <角色>|render|journal [-n N]|--init [--dry-run]]" ;;
  esac
}

# ---------------- 回收站：带索引、默认同文件系统（永不 rm 的落点） ----------------
# 布局：$TRASH_ROOT/<时间戳>-<标签>/{.rdsh-trash.kv, payload...}
#   —— 每一件被"删除"的东西都进一个**带清单的条目目录**：清单里有原路径、体积、原因、
#      跨设备标记与逐项的还原命令；清单写在条目目录里，**不污染被移动的内容**。
#   —— 同一次操作可以带多个来源（如 `debug rm` 的 home + 清单文件）。
#   —— 追加式流水 $TRASH_ROOT/index.log 供人 grep 与 du 统计。
trash_fs_of()    { stat -c '%d' "$1" 2>/dev/null || echo 0; }
trash_same_fs()  { [ "$(trash_fs_of "$1")" = "$(trash_fs_of "$2")" ]; }

trash_mv() {  # [--label 名] [--reason 说明] [--quiet] <路径>...
  local label="" reason="" quiet=0 a
  local -a srcs=()
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --label)  shift; label="${1:-}" ;;
      --reason) shift; reason="${1:-}" ;;
      --quiet|-q) quiet=1 ;;
      --label=*)  label="${a#--label=}" ;;
      --reason=*) reason="${a#--reason=}" ;;
      --)  shift; while [ $# -gt 0 ]; do srcs+=("$1"); shift; done; break ;;
      *) srcs+=("$a") ;;
    esac
    shift || true
  done
  [ "${#srcs[@]}" -gt 0 ] || return 0
  # 只保留真实存在的来源（不存在的静默跳过）
  local -a have=()
  local s
  for s in "${srcs[@]}"; do [ -e "$s" ] || [ -L "$s" ] && have+=("$s"); done
  [ "${#have[@]}" -gt 0 ] || return 0
  [ -n "$label" ] || label="$(basename "${have[0]}")"
  label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
  local ts at dest i=2 x dev=0 sz
  ts="$(date +%Y%m%d-%H%M%S)"; at="$(date -Is)"
  mkdir -p "$TRASH_ROOT" 2>/dev/null || { warn "无法创建回收站 $TRASH_ROOT"; return 1; }
  dest="$TRASH_ROOT/$ts-$label"
  while [ -e "$dest" ]; do dest="$TRASH_ROOT/$ts-$label-$i"; i=$((i+1)); done
  trash_same_fs "$(dirname "${have[0]}")" "$TRASH_ROOT" || dev=1
  if [ "$dev" = "1" ] && [ "$quiet" != "1" ]; then
    warn "跨文件系统：${have[0]} → $TRASH_ROOT 会退化为「复制+删除」（慢、且瞬时占用双份空间）"
    warn "  想避免：在 $BASE 下设 TRASH_ROOT（或把 BASE 换到同一文件系统）"
  fi
  if ! mkdir -p "$dest" 2>/dev/null; then warn "无法创建回收条目 $dest"; return 1; fi
  local n=0 total="0" moved=0 items=""
  TRASH_LAST_DEST=""; TRASH_LAST_ITEMS=()
  for x in "${have[@]}"; do
    local bn tgt; bn="$(basename "$x")"; tgt="$dest/$bn"; i=2
    while [ -e "$tgt" ]; do tgt="$dest/$bn-$i"; i=$((i+1)); done
    if mv "$x" "$tgt" 2>/dev/null; then
      n=$((n+1)); sz="$(du -sh "$tgt" 2>/dev/null | cut -f1 || true)"
      items="${items}orig.$n=$x
dest.$n=$tgt
size.$n=${sz:-?}
restore.$n=mv $tgt $x
"
      TRASH_LAST_ITEMS+=("$tgt")
      moved=1
    else
      warn "无法移动：$x（权限？）→ 请手动处理"
    fi
  done
  if [ "$moved" = "0" ]; then
    rmdir "$dest" 2>/dev/null || true
    warn '没有任何条目被移动'
    return 1
  fi
  total="$(du -sh "$dest" 2>/dev/null | cut -f1 || echo '?')"
  ( umask 077
    { printf 'version=1\nat=%s\nlabel=%s\nreason=%s\ncount=%s\ntotal=%s\ncross_device=%s\n' \
        "$at" "$label" "${reason:-—}" "$n" "$total" "$dev"
      printf '%s' "$items"
    } > "$dest/.rdsh-trash.kv"
    printf '%s|%s|%s|%s|%s|%s\n' "$at" "$(basename "$dest")" "$label" "$total" "${reason:-—}" "$dev" >> "$TRASH_INDEX"
  )
  TRASH_LAST_DEST="$dest"      # 供 restore --merge 之类复用"刚被挪走的那一份"
  if [ "$quiet" != "1" ]; then
    warn "已移到回收站：$dest"
    warn "  还原：rdsh trash restore $(basename "$dest")    体积：$total"
  fi
  return 0
}
rdsh_trash()       { trash_mv --reason "${2:-清理}" "$1"; }
rdsh_trash_quiet() { trash_mv --quiet --reason "${2:-清理}" "$1"; }

# ---------------- du：rdsh 衍生物账本（默认只列不删） ----------------
# "退役要真释放磁盘"的另一半：只把东西挪进回收站，盘永远不释放。这里给一张账：
#   回收站 / 备份快照 / 调试沙箱 / fetch 临时 / 实例注册表陈旧项 / 启动日志
# 原则：**默认只列**；`--purge` 才是真删，且必须带 `--older-than Nd`（trash 可省，表示全清），
#       小于 TRASH_KEEP_DAYS(默认 7) 的回收项还要 `--force`；没有 `--yes` 只预览。
du_size()   { [ -e "$1" ] || { printf '0'; return 0; }; du -sh "$1" 2>/dev/null | cut -f1 || echo '-'; }
du_count()  {  # <glob 展开后的路径...> → 存在的项数。**不要用 `ls ... | wc -l`**：
               # glob 无匹配时 ls 退 2，管道 + pipefail 会让 set -e 静默退出（本批踩到过）
  local n=0 p
  for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] && n=$((n+1)); done
  printf '%s' "$n"
}
du_size_paths() {  # <路径...> → 合计体积（无匹配输出 0）；别拿父目录的体积充当某一类的体积
  local -a xs=()
  local p
  for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] && xs+=("$p"); done
  [ "${#xs[@]}" -gt 0 ] || { printf '0'; return 0; }
  du -sch "${xs[@]}" 2>/dev/null | tail -1 | cut -f1 || printf '?'
}
du_oldest() { find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | sort | head -1 | xargs -r stat -c '%y' 2>/dev/null | cut -d' ' -f1; }
du_age_days() {  # <YYYY-MM-DD> → 天数（解析不了输出 -1）
  local d="$1"; [ -n "$d" ] || { echo -1; return; }
  local t; t="$(date -d "$d" +%s 2>/dev/null || echo '')"
  [ -n "$t" ] || { echo -1; return; }
  echo $(( ( $(date +%s) - t ) / 86400 ))
}
du_trash_at() { sed -nE 's/^at=(.*)T.*$/\1/p' "$1/.rdsh-trash.kv" 2>/dev/null | tail -1; }

du_report_trash() {
  if [ ! -d "$TRASH_ROOT" ]; then printf '  %-12s %s\n' '回收站' '（空）'; return 0; fi
  local d n=0
  printf '  %-12s %-8s %s\n' '回收站' "$(du_size "$TRASH_ROOT")" "$TRASH_ROOT"
  for d in "$TRASH_ROOT"/*/; do
    [ -d "$d" ] || continue
    n=$((n+1))
    local name at label total reason restored
    name="$(basename "$d")"
    at="$(sed -nE 's/^at=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null | tail -1)"
    label="$(sed -nE 's/^label=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null | tail -1)"
    total="$(sed -nE 's/^total=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null | tail -1)"
    reason="$(sed -nE 's/^reason=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null | tail -1)"
    restored="$(sed -nE 's/^restored_at=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null | tail -1)"
    printf '      %-34s %-7s %-11s %s%s\n' "$name" "${total:--}" "${at%%T*}" "${reason:--}" \
      "$([ -n "$restored" ] && printf '  [已还原 %s]' "${restored%%T*}")"
    local o
    while IFS= read -r o; do
      [ -n "$o" ] && printf '        ← %s\n' "$o"
    done < <(sed -nE 's/^orig\.[0-9]+=(.*)$/\1/p' "$d/.rdsh-trash.kv" 2>/dev/null || true)
  done
  [ "$n" = "0" ] && printf '      %s\n' '（没有回收条目）'
  return 0
}

cmd_du() {
  local purge="" older="" yes=0 force=0 json=0 a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --purge) shift; purge="${1:-}" ;;
      --purge=*) purge="${a#--purge=}" ;;
      --older-than) shift; older="${1:-}" ;;
      --older-than=*) older="${a#--older-than=}" ;;
      --yes|-y) yes=1 ;;
      --force) force=1 ;;
      --json) json=1 ;;
      -*) die "未知选项：$a（rdsh du [--purge <类>] [--older-than Nd] [--yes] [--force]）" ;;
      *) die "多余参数：$a" ;;
    esac
    shift || true
  done
  case "$purge" in
    ""|trash|backup|fetch|stale|logs) ;;
    debug) die '调试沙箱请走 rdsh debug rm（它会先停实例、且只认带清单的环境），不要用 du --purge 绕过它' ;;
    *) die "未知类别：$purge（可选：trash / backup / fetch / stale / logs）" ;;
  esac
  if [ -n "$older" ]; then
    case "${older%d}" in ''|*[!0-9]*) die "--older-than 形如 30d（收到：$older）" ;; esac
  fi
  local n_trash n_backup n_debug n_fetch n_stale n_logs
  n_trash="$(du_count "$TRASH_ROOT"/*/)"
  n_backup="$(du_count "$BACKUP_ROOT"/*/)"
  n_debug="$(du_count "$DEBUG_ROOT"/*/)"
  n_fetch="$(du_count "$MANAGE_ROOT"/.fetch-*)"
  n_stale="$(du_count "$RUN_DIR"/stale/*)"
  n_logs="$(du_count "$LOG_DIR"/web-*.log)"

  if [ "$json" = "1" ]; then
    printf '{"trash":{"count":%s,"size":"%s","root":"%s"},"backup":{"count":%s,"size":"%s"},"debug":{"count":%s,"size":"%s"},"fetch_tmp":{"count":%s,"size":"%s"},"run_stale":{"count":%s,"size":"%s"},"logs":{"count":%s,"size":"%s"}}\n' \
      "$n_trash" "$(du_size "$TRASH_ROOT")" "$TRASH_ROOT" \
      "$n_backup" "$(du_size "$BACKUP_ROOT")" "$n_debug" "$(du_size "$DEBUG_ROOT")" \
      "$n_fetch" "$(du_size_paths "$MANAGE_ROOT"/.fetch-*)" "$n_stale" "$(du_size_paths "$RUN_DIR"/stale/*)" \
      "$n_logs" "$(du_size_paths "$LOG_DIR"/web-*.log)"
    return 0
  fi

  log "rdsh 衍生物账本（默认只列不删；真删要 --purge）+ [--older-than Nd] + --yes"
  echo
  du_report_trash
  printf '  %-12s %-8s %-6s 最老：%s\n' '备份快照' "$(du_size "$BACKUP_ROOT")" "$n_backup 个目录" "$(du_oldest "$BACKUP_ROOT")"
  printf '  %-12s %-8s %-6s （删除请用 rdsh debug rm）\n' '调试沙箱' "$(du_size "$DEBUG_ROOT")" "$n_debug 个环境"
  printf '  %-12s %-8s %-6s 半成品检出\n' 'fetch 临时' "$(du_size_paths "$MANAGE_ROOT"/.fetch-*)" "$n_fetch 个残留"
  printf '  %-12s %-8s %-6s 过期注解\n' '注册表陈旧' "$(du_size_paths "$RUN_DIR"/stale/*)" "$n_stale 个"
  printf '  %-12s %-8s %-6s （清理：rdsh logs --clean）\n' '启动日志' "$(du_size_paths "$LOG_DIR"/web-*.log)" "$n_logs 个"
  echo
  printf '  分区余量：%s\n' "$(df -h "$BASE" 2>/dev/null | tail -1 | awk '{print $4" 可用（"$5" 已用）"}')"

  [ -n "$purge" ] || { echo; log "只读模式。真删示例：rdsh du --purge trash --older-than 30d --yes"; return 0; }

  # ---- purge：先列"将删什么"，再要 --yes ----
  local -a victims=()
  local p age
  case "$purge" in
    trash)
      for p in "$TRASH_ROOT"/*/; do
        [ -d "$p" ] || continue
        if [ -n "$older" ]; then
          age="$(du_age_days "$(du_trash_at "$p")")"
          [ "$age" -ge "${older%d}" ] 2>/dev/null && victims+=("$p")
        else
          victims+=("$p")
        fi
      done ;;
    backup)
      if [ -z "$older" ]; then
        warn 'backup 必须给 --older-than Nd（备份是资产，不点名的删除不许裸跑）—— 本次只列不删'
        for p in "$BACKUP_ROOT"/*/; do [ -d "$p" ] && printf '    %-10s %s\n' "$(du_size "$p")" "$p"; done
        return 1
      fi
      for p in "$BACKUP_ROOT"/*/; do
        [ -d "$p" ] || continue
        age="$(du_age_days "$(stat -c '%y' "$p" 2>/dev/null | cut -d' ' -f1)")"
        [ "$age" -ge "${older%d}" ] 2>/dev/null && victims+=("$p")
      done ;;
    fetch)
      if [ -z "$older" ]; then
        warn 'fetch 必须给 --older-than Nd（避免删掉正在进行的下载）—— 本次只列不删'
        for p in "$MANAGE_ROOT"/.fetch-*; do [ -e "$p" ] && printf '    %-10s %s\n' "$(du_size "$p")" "$p"; done
        return 1
      fi
      for p in "$MANAGE_ROOT"/.fetch-*; do
        [ -e "$p" ] || continue
        age="$(du_age_days "$(stat -c '%y' "$p" 2>/dev/null | cut -d' ' -f1)")"
        [ "$age" -ge "${older%d}" ] 2>/dev/null && victims+=("$p")
      done ;;
    stale)
      for p in "$RUN_DIR"/stale/*; do
        [ -e "$p" ] || continue
        victims+=("$p")
      done ;;
    logs)
      warn '日志请用 rdsh logs --clean（它按设计只清内容、不删文件）'
      return 1 ;;
  esac
  if [ "${#victims[@]}" -eq 0 ]; then
    warn "没有符合条件的项（类别 $purge$([ -n "$older" ] && printf '，年龄 ≥ %s' "$older")）"
    return 0
  fi
  local v
  for v in "${victims[@]}"; do printf '    %-10s %s\n' "$(du_size "$v")" "$v"; done
  echo
  if [ "$yes" != "1" ]; then
    log "预览模式（没有 --yes）：上面就是要真删的 ${#victims[@]} 项。真删：加 --yes"
    return 0
  fi
  local failed=0 keepd="$TRASH_KEEP_DAYS"
  for v in "${victims[@]}"; do
    case "$v" in
      "$TRASH_ROOT"/*|"$BACKUP_ROOT"/*|"$RUN_DIR"/stale/*|"$MANAGE_ROOT"/.fetch-*) ;;
      *) warn "拒绝删除白名单外的路径：$v"; failed=$((failed+1)); continue ;;
    esac
    if [ "$purge" = "trash" ]; then
      local age_d; age_d="$(du_age_days "$(du_trash_at "$v")")"
      if [ "${age_d:--1}" -ge 0 ] && [ "$age_d" -lt "$keepd" ] && [ "$force" != "1" ]; then
        warn "跳过（$age_d 天 < ${keepd} 天，要删加 --force）：$(basename "$v")"; continue
      fi
    fi
    chmod -R u+w "$v" 2>/dev/null || true     # 只读快照删不动 → 先解锁再删
    rm -rf "$v" && log "已删除：$v" || { warn "删除失败：$v"; failed=$((failed+1)); }
  done
  ( umask 077; printf '%s|purge|%s|older=%s force=%s\n' "$(date -Is)" "$purge" "${older:-无}" "$force" >> "$TRASH_INDEX" )
  if [ "$failed" = "0" ]; then
    log 'purge 完成'
    printf '  释放后分区余量：%s\n' "$(df -h "$BASE" 2>/dev/null | tail -1 | awk '{print $4" 可用"}')"
  else
    warn "$failed 项未删除"; return 1
  fi
}

# ---------------- trash：回收站的查看与还原 ----------------
cmd_trash() {
  local sub="ls"
  if [ $# -gt 0 ]; then sub="$1"; shift; fi
  case "$sub" in
    # 注意：不要写 `[ $# -gt 0 ] && shift` —— 无参数时它返回 1，set -e 会直接退出
    ls|list) log "回收站：$TRASH_ROOT（流水：$TRASH_INDEX）"; du_report_trash ;;
    restore)
      local sel="${1:-}" force=0
      [ "${2:-}" = "--force" ] && force=1
      [ -n "$sel" ] || die '用法: rdsh trash restore <条目名|--last> [--force]'
      [ -d "$TRASH_ROOT" ] || die "没有回收站（$TRASH_ROOT）"
      local entry=""
      if [ "$sel" = "--last" ]; then
        entry="$(ls -1dt "$TRASH_ROOT"/*/ 2>/dev/null | sed -n '1p' || true)"
      else
        case "$sel" in "$TRASH_ROOT"/*) entry="$sel" ;; *) entry="$TRASH_ROOT/$sel" ;; esac
      fi
      [ -d "$entry" ] || die "找不到回收条目：$sel（rdsh trash ls 看全部）"
      local mf="$entry/.rdsh-trash.kv"
      [ -f "$mf" ] || die "该条目没有清单（$mf）—— 不是 rdsh 建的条目，请手工处理"
      log "还原条目：$(basename "$entry")"
      local i=1 orig dest moved=0 skipped=0
      while :; do
        orig="$(sed -nE "s/^orig\\.$i=(.*)$/\\1/p" "$mf" | tail -1)"
        dest="$(sed -nE "s/^dest\\.$i=(.*)$/\\1/p" "$mf" | tail -1)"
        [ -n "$orig" ] || break
        if [ -e "$orig" ] && [ "$force" != "1" ]; then
          warn "目标已存在，跳过（不覆盖；要覆盖加 --force）：$orig"; skipped=$((skipped+1)); i=$((i+1)); continue
        fi
        if [ -e "$dest" ]; then
          mkdir -p "$(dirname "$orig")"
          [ "$force" = "1" ] && [ -e "$orig" ] && rdsh_trash_quiet "$orig"
          if mv "$dest" "$orig"; then log "  已还原：$orig"; moved=$((moved+1)); else warn "  还原失败：$orig"; fi
        fi
        i=$((i+1))
      done
      ( umask 077; printf 'restored_at=%s\n' "$(date -Is)" >> "$mf" )
      log "还原完成：$moved 项$([ "$skipped" -gt 0 ] && printf '，跳过 %s 项' "$skipped")"
      log '（条目目录保留作痕迹；rdsh du --purge trash 可清理）'
      ;;
    -h|--help|help)
      cat <<'USAGE'
rdsh trash —— 回收站（"永不 rm" 的落点）

用法:
  rdsh trash ls                            列出条目（时间 / 标签 / 体积 / 原因 / 原路径 / 是否已还原）
  rdsh trash restore <条目名|--last> [--force]
                                           按清单逐项还原；目标已存在则跳过（不覆盖），--force 才腾位

布局: $TRASH_ROOT/<时间戳>-<标签>/{.rdsh-trash.kv, <被移动的东西>}
      清单含 orig.N / dest.N / size.N / restore.N 与跨设备标记；真删走 rdsh du --purge trash
USAGE
      ;;
    *) die '用法: rdsh trash [ls|restore <条目名|--last> [--force]]' ;;
  esac
}

# ---------------- restore：从本地快照 / 本地克隆 / 远端仓库 恢复 ----------------
# 三类来源，语义不同（分开对待，不做"全部下载"）：
#   ① 本地快照 —— $BACKUP_ROOT/snapshots|state-snapshots（数据 home / 状态账本）。
#                 **会话数据只认这一条路**（隐私裁定），远端一律拒绝
#   ② 本地克隆 —— 「我的 dsh」仓库的本地克隆（插件/补丁/稳定根/预设/配置）
#   ③ 远端仓库 —— git URL（clone 到本地再按 ② 处置；不接受 --type data/state）
# 安全：
#   * 覆盖前把既有目标整体挪进回收站（带清单 → 一步还原）
#   * 凭据 .credentials.yaml **默认不恢复**（要显式 --with-creds）
#   * 记忆三库（lessons/facts/backlog）默认**按条目追加**（append-only 语义），不整文件覆盖
#   * 没有 --yes 只预览；收尾自动调 doctor
RESTORE_TYPES="data state plugins patches shared presets config"
MD_LIBS="lessons.md facts.md backlog.md"
DOCTOR_AFTER=1

restore_type_src() {  # <类型> → 该类型在源里的相对路径
  case "$1" in
    data|state) printf '' ;;
    plugins) printf 'plugins' ;;
    patches) printf 'patches' ;;
    shared)  printf 'shared' ;;
    presets) printf 'shared/presets' ;;
    config)  printf 'config/rdsh.config' ;;
  esac
}
restore_type_dst() {  # <类型> <版本> → 本机目标路径
  case "$1" in
    data)    printf '%s/%s' "$DATA_ROOT" "${2:?data 需要版本号}" ;;
    state)   printf '%s' "$STATE_ROOT" ;;
    plugins) printf '%s' "$PLUGIN_ROOT" ;;
    patches) printf '%s' "$PATCHES_ROOT" ;;
    shared)  printf '%s' "$SHARED_ROOT" ;;
    presets) printf '%s/.agent-presets' "$SHARED_ROOT" ;;
    config)  printf '%s' "$RDSH_CONFIG" ;;
  esac
}
restore_type_kind() { case "$1" in config) printf 'file' ;; *) printf 'dir' ;; esac; }

md_headings()  { [ -f "$1" ] && grep '^## ' "$1" 2>/dev/null || true; }
md_new_count() { comm -23 <(md_headings "$1" | sort -u) <(md_headings "$2" | sort -u) 2>/dev/null | grep -c . || true; }
md_merge_append() {  # <源> <目标>：把源里目标没有的 ## 块**追加**到目标
  local src="$1" dst="$2" n extra
  [ -f "$src" ] || return 1
  if [ ! -f "$dst" ]; then cp -p "$src" "$dst"; return 0; fi
  n="$(md_new_count "$src" "$dst")"
  if [ "${n:-0}" = "0" ]; then log "  = $(basename "$dst")：没有新条目"; return 0; fi
  extra="$(awk -v dstfile="$dst" '
    BEGIN { while ((getline line < dstfile) > 0) have[line]=1 }
    /^## / { if (!($0 in have)) { keep=1; nb++; buf[nb]=$0 } else { keep=0 } ; next }
    { if (keep) buf[nb] = buf[nb] "\n" $0 }
    END { for (i=1;i<=nb;i++) print buf[i] }
  ' "$src")"
  { printf '\n'; printf '%s\n' "$extra"; } >> "$dst"
  log "  + $(basename "$dst")：追加了 $n 条"
}

restore_resolve_ver() {  # <版本片段> → 账本/快照里的确切版本键
  local want="$1" e k hit="" n=0
  [ -n "$want" ] || return 0
  if [ "${#ENTRIES[@]}" -gt 0 ]; then
    e="$(resolve_target "$want" 2>/dev/null || true)"
    case "$e" in UNMANAGED:*|"") ;; *) entry_key "$e"; return 0 ;; esac
  fi
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in *"$want"*) hit="$k"; n=$((n+1)) ;; esac
  done < <(state_keys)
  [ "$n" = "1" ] && { printf '%s' "$hit"; return 0; }
  printf '%s' "$want"
}

usage_restore() {
  cat <<'USAGE'
rdsh restore —— 从本地快照 / 本地克隆 / 远端仓库 恢复

用法:
  rdsh restore --list
  rdsh restore --type <类> [--from <源>] [--file <相对路径>] [选项]

资产类型:
  data      某版本的数据 home（含会话/存储）——**只从本地快照恢复**，远端一律拒绝
  state     状态账本（只本地快照；账本不进任何仓库）
  plugins / patches / shared / presets / config

来源 --from:
  <本地目录>   rdsh 快照目录（含 MANIFEST.kv）或「我的 dsh」本地克隆
  git:<URL>    远端仓库（clone 到本地再恢复；不接受 data/state）
  省略         data/state 取本地最新快照；其余取 $RDSH_MYDSH_REPO

选项:
  --diff           只显示差异（rsync --dry-run / 记忆三库条目差）
  --merge          记忆三库按条目**追加**，不整文件覆盖（shared/data 可用）
  --with-creds     data 恢复时连 .credentials.yaml 一起（默认跳过）
  --dry-run        只预览
  --yes, -y        真正写入（既有目标先整体挪进回收站，可一步还原）
  --no-doctor      收尾不调 doctor
USAGE
}

cmd_restore_list() {
  log '可用来源'
  echo
  printf '  本地快照（数据 home）：%s\n' "$SNAP_ROOT"
  local d
  for d in "$SNAP_ROOT"/*/; do
    [ -d "$d" ] || continue
    printf '    %-16s %s 份  最新 %s\n' "$(basename "$d")" "$(du_count "$d"*/)" \
      "$(basename "$(ls -1dt "$d"*/ 2>/dev/null | sed -n '1p' || true)")"
  done
  [ -d "$SNAP_ROOT" ] || printf '    （还没有快照 → rdsh backup --all --state --snapshot）\n'
  printf '  状态账本快照：%s（%s 份）\n' "$STATE_SNAP_ROOT" "$(du_count "$STATE_SNAP_ROOT"/*/)"
  printf '  回收站：%s（%s 个条目；rdsh trash restore 可整份还原）\n' "$TRASH_ROOT" "$(du_count "$TRASH_ROOT"/*/)"
  if [ -n "$MYDSH_REPO" ]; then
    printf '  「我的 dsh」本地克隆（MYDSH_REPO）：%s%s\n' "$MYDSH_REPO" "$([ -d "$MYDSH_REPO" ] || printf '  ⚠️ 不存在')"
  else
    printf '  「我的 dsh」本地克隆：未配置（设 MYDSH_REPO 或 --from <目录>）\n'
  fi
  printf '  远端：--from git:<URL>（plugins/patches/shared/presets/config；data/state 不接受）\n'
}

cmd_restore() {
  local from="" type="" file="" ver="" diff_only=0 merge=0 creds=0 dry=0 yes=0 a
  local -a rest=()
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --list) cmd_restore_list; return 0 ;;
      --from) shift; from="${1:-}" ;;
      --from=*) from="${a#--from=}" ;;
      --type) shift; type="${1:-}" ;;
      --type=*) type="${a#--type=}" ;;
      --file) shift; file="${1:-}" ;;
      --file=*) file="${a#--file=}" ;;
      --diff) diff_only=1 ;;
      --merge) merge=1 ;;
      --with-creds) creds=1 ;;
      --dry-run|-n) dry=1 ;;
      --yes|-y) yes=1 ;;
      --no-doctor) DOCTOR_AFTER=0 ;;
      -h|--help|help) usage_restore; return 0 ;;
      -*) die "未知选项：$a（rdsh restore --list / --help 看用法）" ;;
      *) rest+=("$a") ;;
    esac
    shift || true
  done
  # 位置参数归属：没给 --type 时第一个位置参数是类型，给了则是版本
  if [ -z "$type" ]; then type="${rest[0]:-}"; [ -n "$ver" ] || ver="${rest[1]:-}"
  else [ -n "$ver" ] || ver="${rest[0]:-}"; fi
  [ -n "$type" ] || { usage_restore; return 1; }
  case " $RESTORE_TYPES " in *" $type "*) ;; *) die "未知资产类型：$type（可选：$RESTORE_TYPES）" ;; esac

  local src_kind=""
  if [ -n "$from" ]; then
    case "$from" in
      git:*|http://*|https://*|git@*|ssh://*) src_kind="git" ;;
      *) src_kind="local" ;;
    esac
  else
    case "$type" in
      data|state) src_kind="local" ;;
      *) if [ -n "$MYDSH_REPO" ]; then src_kind="local"; from="$MYDSH_REPO"
         else die '没给 --from，也没配置 MYDSH_REPO（「我的 dsh」本地克隆路径）'; fi ;;
    esac
  fi
  if [ "$src_kind" = "git" ]; then
    case "$type" in
      data|state) die "拒绝：$type 是会话/本机状态数据，**只从本地源恢复**（隐私裁定）。远端只用于 plugins/patches/shared/presets/config" ;;
    esac
    local url="${from#git:}" dest="$BACKUP_ROOT/restore-src-$(backup_stamp)"
    if [ "$dry" = "1" ]; then
      printf '  [dry-run] git clone --depth 1 %s %s\n' "$url" "$dest"; return 0
    fi
    log "克隆远端仓库 → $dest"
    git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 || die "clone 失败：$url"
    from="$dest"
    log '已克隆到本地（保留备查）：'"$from"
  fi
  if [ -z "$from" ]; then
    case "$type" in
      state) from="$(ls -1dt "$STATE_SNAP_ROOT"/*/ 2>/dev/null | sed -n '1p' || true)" ;;
      data)
        local vkey; vkey="$(restore_resolve_ver "$ver")"
        [ -n "$vkey" ] || die 'data 恢复要指明版本：rdsh restore --type data <版本片段>'
        from="$(ls -1dt "$(snap_dir_of "$vkey")"/*/ 2>/dev/null | sed -n '1p' || true)"
        [ -n "$from" ] && ver="$vkey" ;;
    esac
    [ -n "$from" ] || die "本地快照里找不到可用的 $type 源（先 rdsh backup）"
    log "未指定 --from，用最新本地快照：$from"
  fi
  [ -d "$from" ] || die "源目录不存在：$from"
  local src_is_snap=0
  if [ -f "$from/MANIFEST.kv" ]; then
    src_is_snap=1
    local mver; mver="$(snap_manifest "$from" version)"
    if [ "$mver" = "state" ]; then
      [ "$type" = "state" ] || die "该快照是状态账本快照（version=state）→ 用 --type state"
    else
      case "$type" in
        data|state) [ -n "$ver" ] || ver="$mver" ;;
        *) die "该快照是数据 home 快照（版本 $mver）→ 用 --type data" ;;
      esac
    fi
  else
    case "$type" in
      data|state) die "该目录不是 rdsh 快照（没有 MANIFEST.kv）：$from" ;;
      *) [ -d "$from/plugins" ] || [ -d "$from/shared" ] || warn "源里既没有 plugins/ 也没有 shared/，可能不是「我的 dsh」克隆：$from" ;;
    esac
  fi

  local rel src dst
  rel="$(restore_type_src "$type")"
  if [ "$type" = "state" ]; then dst="$(restore_type_dst state '')"; else dst="$(restore_type_dst "$type" "$ver")"; fi
  case "$type" in data|state) src="$from" ;; *) src="$from/${rel}" ;; esac
  if [ -n "$file" ]; then
    src="$src/$file"
    [ "$(restore_type_kind "$type")" = "dir" ] && dst="$dst/$file"
  fi
  [ -e "$src" ] || die "源里没有这一项：$src"

  log "恢复：$type（源=$([ "$src_kind" = git ] && printf '远端克隆' || printf '本地')）"
  printf '  源  ：%s\n  目标：%s%s\n' "$src" "$dst" "$([ -e "$dst" ] && printf '（已存在 → 先整体挪进回收站）' || printf '（新建）')"
  if [ "$type" = "data" ]; then
    printf '  说明：含会话/存储；凭据 .credentials.yaml %s；恢复后请重启该版本实例\n' \
      "$([ "$creds" = "1" ] && printf '一并恢复（--with-creds）' || printf '默认跳过（要它加 --with-creds）')"
  fi

  local kind; kind="$(restore_type_kind "$type")"
  if [ "$diff_only" = "1" ]; then
    log '--diff：只看差异'
    if [ "$kind" = "file" ]; then
      diff -u "$dst" "$src" 2>/dev/null | head -40 || printf '  （目标不存在或无法比较）\n'
    else
      local nd=""
      command -v rsync >/dev/null && nd="$(rsync -ain --delete "$src/" "$dst/" 2>/dev/null | grep -c '^[<>]' || true)"
      printf '  与目标比：%s 处差异\n' "${nd:-（无 rsync，跳过目录比较）}"
      local lib
      for lib in $MD_LIBS; do
        [ -f "$src/$lib" ] && printf '    %-14s 源里有 %s 条目标没有\n' "$lib" "$(md_new_count "$src/$lib" "$dst/$lib")"
      done
    fi
    return 0
  fi
  if [ "$dry" = "1" ] || [ "$yes" != "1" ]; then
    log "$([ "$dry" = "1" ] && printf -- '--dry-run' || printf '预览模式（没有 --yes）')：没有写入任何东西"
    [ "$merge" = "1" ] && log "（--merge：$MD_LIBS 按条目追加，不整文件覆盖）"
    return 0
  fi

  if [ "$merge" = "1" ] && { [ "$type" = "shared" ] || [ "$type" = "data" ]; }; then
    trash_mv --label "restore-$type" --reason "restore --merge 前的既有内容" "$dst" || warn '挪走既有内容失败'
    local oldroot="${TRASH_LAST_ITEMS[0]:-}"
    mkdir -p "$dst"
    if [ "$type" = "shared" ]; then rsync -a "$src/" "$dst/"; else cp -a "$src/." "$dst/"; fi
    local lib
    for lib in $MD_LIBS; do
      [ -f "$src/$lib" ] || continue
      if [ -n "$oldroot" ] && [ -f "$oldroot/$lib" ]; then
        cp -p "$oldroot/$lib" "$dst/$lib.old-copy"
        md_merge_append "$src/$lib" "$dst/$lib.old-copy" >/dev/null 2>&1 || true
        cp -p "$dst/$lib.old-copy" "$dst/$lib"
      fi
      md_merge_append "$src/$lib" "$dst/$lib"
    done
    log "合并完成；旧内容在回收站：${oldroot:-（未挪）}（rdsh trash restore 可整份还原）"
  else
    if [ -e "$dst" ]; then
      trash_mv --label "restore-$type" --reason "restore $type 覆盖前的既有内容" "$dst" || warn '挪走既有内容失败'
    fi
    if [ "$kind" = "file" ]; then
      mkdir -p "$(dirname "$dst")"; cp -p "$src" "$dst"
    elif [ "$type" = "data" ]; then
      mkdir -p "$dst"
      # MANIFEST.kv 是快照的元数据，不属于数据 home，不能复制进去
      local -a ex=(--exclude=MANIFEST.kv)
      [ "$creds" = "1" ] || ex+=(--exclude=.credentials.yaml)
      # 快照是**只读**的（防就地改动连带改坏更早的快照）；恢复出来的东西必须可写，
      # 否则 dsh 连自己的数据 home 都写不了 —— 用 --chmod 给目录/文件补 u+w
      [ "$src_is_snap" = "1" ] && ex+=(--chmod=Du+w,Fu+w)
      rsync -a "${ex[@]}" "$src/" "$dst/" || die 'rsync 失败'
      chmod 700 "$dst" 2>/dev/null || true
    else
      mkdir -p "$dst"
      local -a ex2=()
      if [ "$src_is_snap" = "1" ]; then ex2+=(--exclude=MANIFEST.kv --chmod=Du+w,Fu+w); fi
      rsync -a "${ex2[@]}" "$src/" "$dst/" || die 'rsync 失败'
    fi
    log "已恢复 $type → $dst"
  fi

  if [ "${DOCTOR_AFTER:-1}" = "1" ] && [ -f "$MANAGE_ROOT/doctor.sh" ]; then
    echo
    log '收尾验证（doctor --quiet）：'
    bash "$MANAGE_ROOT/doctor.sh" --quiet 2>&1 | tail -6 || warn 'doctor 未通过或无输出 → 手工跑 rdsh doctor'
  else
    log '收尾：跑一次 rdsh doctor（断链/账本/插件一致性）'
  fi
  [ "$type" = "data" ] && warn '数据 home 已恢复 → 重启该版本实例后生效'
  return 0
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
    base|fetch|help|-h|--help|doctor|scan|secrets ) : ;;
    state|du|trash|trashcan ) ALLOW_NO_ENTRIES=1; load_map; collect_entries; sort_entries ;;
    restore ) ALLOW_NO_ENTRIES=1; load_map; collect_entries; sort_entries ;;
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
    state ) shift; cmd_state "$@" ;;
    du ) shift; cmd_du "$@" ;;
    trash|trashcan ) shift; cmd_trash "$@" ;;
    restore ) shift; cmd_restore "$@" ;;
    patch ) shift; exec "$MANAGE_ROOT/patch-manager.sh" "$@" ;;   # 转发到补丁管理器
    doctor ) shift; exec "$MANAGE_ROOT/doctor.sh" "$@" ;;         # 转发到只读体检
    scan|secrets ) shift; exec "$MANAGE_ROOT/scan-secrets.sh" "$@" ;;  # 转发到隐私守卫
    fetch|download|dl ) shift; cmd_fetch "$@" ;;
    help|-h|--help ) cmd_help ;;
    --dry-run|-n ) cmd_start "$@" ;;
    * ) cmd_start "$@" ;;   # 其余参数一律当作 start 的目标
  esac
}
main "$@"
