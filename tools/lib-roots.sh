#!/usr/bin/env bash
# =============================================================================
# lib-roots.sh —— 附属脚本共享的「根解析」库（2026-11-05 P1）
#
# 为什么：BASE/各派生根以前在 6 个脚本里各抄一份（~20 行 × 6），布局一改就要改 6 处
# （2026-10-11 收敛时就是这么被咬的）。现在真源仍是 Rdsh.sh 的解析规则，本库是它的
# **共享实现**：附属脚本 source 后调 `rdsh_resolve_roots` 即可，不再各写一套。
#
# 用法（在附属脚本的根解析处）:
#   _self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
#   . "$_self_dir/tools/lib-roots.sh"        # 部署目录里与本脚本同级；自举副本同结构
#   rdsh_resolve_roots
#
# 约定:
#   * 本文件**只定义函数**，source 时无副作用；
#   * 优先级：RDSH_BASE > BASE_OVERRIDE > 配置文件 > 默认 $HOME/Mapp；
#     其余根：专用环境变量 > 配置文件 > 由 BASE 派生的默认值；
#   * MANAGE_ROOT 兼容：$BASE/rdsh → 经典 $BASE/dsh → 调用脚本自身目录（可移植回退）。
# =============================================================================

# 配置文件里的 KEY=VALUE（去引号、展开 ~）；没有则空
rdsh_cfg_get() {  # <KEY> [配置文件]
  local f="${2:-${RDSH_CONFIG:-$HOME/.config/rdsh/config}}" v
  [ -f "$f" ] || return 0
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$f" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}

rdsh_expand() {  # 展开开头的 ~
  case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac
}

# 解析并设置全部根变量（副作用：设置全局变量；不 export —— 由调用方决定）
rdsh_resolve_roots() {
  RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"

  BASE="$(rdsh_expand "${BASE_OVERRIDE:-${RDSH_BASE:-$(rdsh_cfg_get BASE)}}")"
  [ -n "$BASE" ] || BASE="$HOME/Mapp"

  local _manage _data _backup _shared _logs _run _state _trash _plugin _patches _debug
  _manage="$(rdsh_expand "${RDSH_MANAGE_ROOT:-$(rdsh_cfg_get MANAGE_ROOT)}")"
  _data="$(rdsh_expand "${RDSH_DATA_ROOT:-$(rdsh_cfg_get DATA_ROOT)}")"
  _backup="$(rdsh_expand "${RDSH_BACKUP_ROOT:-$(rdsh_cfg_get BACKUP_ROOT)}")"
  _shared="$(rdsh_expand "${RDSH_SHARED_HOME:-$(rdsh_cfg_get SHARED_ROOT)}")"
  _logs="$(rdsh_expand "${DSH_RESTART_LOGDIR:-${DSH_LOG_DIR:-$(rdsh_cfg_get LOG_DIR)}}")"
  _run="$(rdsh_expand "${RDSH_RUN_DIR:-$(rdsh_cfg_get RUN_DIR)}")"
  _state="$(rdsh_expand "${RDSH_STATE_ROOT:-$(rdsh_cfg_get STATE_ROOT)}")"
  _trash="$(rdsh_expand "${RDSH_TRASH:-$(rdsh_cfg_get TRASH_ROOT)}")"
  _plugin="$(rdsh_expand "${RDSH_PLUGIN_ROOT:-$(rdsh_cfg_get PLUGIN_ROOT)}")"
  _patches="$(rdsh_expand "${RDSH_PATCHES:-$(rdsh_cfg_get PATCHES)}")"
  _debug="$(rdsh_expand "${RDSH_DEBUG_ROOT:-$(rdsh_cfg_get DEBUG_ROOT)}")"

  MANAGE_ROOT="${_manage:-$BASE/rdsh}"
  # 经典布局回退：未显式配置时，$BASE/rdsh 没有 Rdsh.sh 而 $BASE/dsh 有
  if [ -z "$_manage" ] && [ ! -f "$MANAGE_ROOT/Rdsh.sh" ] && [ -f "$BASE/dsh/Rdsh.sh" ]; then
    MANAGE_ROOT="$BASE/dsh"
  fi
  # 可移植回退：仍找不到 → 调用脚本自身目录（须含 Rdsh.sh；bootstrap 自举副本/任意 clone 都适用）
  if [ -z "$_manage" ] && [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    local _self_dir; _self_dir="$(dirname "$(readlink -f "$0")")"
    [ -f "$_self_dir/Rdsh.sh" ] && MANAGE_ROOT="$_self_dir"
  fi

  DATA_ROOT="${_data:-$BASE/.dsh-suite/data}"
  BACKUP_ROOT="${_backup:-$BASE/.dsh-suite/backup}"
  SHARED_ROOT="${_shared:-$BASE/.dsh-suite/shared}"
  LOG_DIR="${_logs:-$BASE/.dsh-suite/logs}"
  RUN_DIR="${_run:-$BASE/.dsh-suite/run}"
  STATE_ROOT="${_state:-$BASE/.dsh-suite/state}"
  TRASH_ROOT="${_trash:-$BASE/.dsh-suite/trash}"
  PLUGIN_ROOT="${_plugin:-$BASE/.dsh-suite/plugins}"
  PATCHES_ROOT="${_patches:-$BASE/.dsh-suite/patches}"
  DEBUG_ROOT="${_debug:-$BASE/.dsh-suite/debug}"

  MAP_FILE="$MANAGE_ROOT/.map"
}

# 把解析结果导出给子进程（主脚本转发附属脚本/外部能力前调用）
rdsh_export_roots() {
  export RDSH_CONFIG RDSH_BASE BASE MANAGE_ROOT DATA_ROOT BACKUP_ROOT SHARED_ROOT \
         LOG_DIR RUN_DIR STATE_ROOT TRASH_ROOT PLUGIN_ROOT PATCHES_ROOT DEBUG_ROOT
}

# 直接执行时只打印说明（被 source ��不做任何事）——CI 的「每个脚本 --help 必须非空」会跑它
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  sed -n '2,/^# =\{20,\}$/p' "$0"
  exit 0
fi
