#!/usr/bin/env bash
# =============================================================================
# smoke-uninstall.sh —— `rdsh uninstall`（install 的反面）隔离冒烟（2026-11-05）
#
# 语义约定（路线图 P1 #7）：
#   * 只把 **node_modules** 与 **.installed** 移进回收站 → 回到"未安装"态；
#   * **检出目录与数据 home 一律不动**；退役是 `rdsh retire`，两者别混；
#   * 默认只出计划（--apply 才动）；在跑的实例**不许**卸载（写入者运行时不动它的数据）。
#
# 本冒烟在隔离 BASE 里自证：
#   * dry-run 不动文件，并明说"计划（未执行）"
#   * --apply 移走两样、检出/数据完好，回收站里有条目（可整体还原），账本有流水
#   * 幂等：再跑 → "已经是未安装态"
#   * 负样本：实例在跑 → 拒绝，文件原样
#   * `rdsh plugins <参数>` 正确转发到 plugin-sync.sh
#
# 用法: bash smoke-uninstall.sh [Rdsh.sh 路径]
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
DIR="$(dirname "$(readlink -f "$SRC")")"
FIXTURE="$DIR/tools/fixtures/fake-dsh-web.c"
CC="$(command -v cc || command -v gcc || true)"

T="$(mktemp -d)"; B="$T/base"; FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

CK="$B/rdsh/deepseek-harness-dsh-9.9.7-rc.2"
DH="$B/.dsh-suite/data/9.9.7-rc.2"
mkdir -p "$CK/node_modules/dep" "$DH" "$B/.dsh-suite/state"
cp -p "$SRC" "$B/rdsh/Rdsh.sh"
[ -f "$DIR/plugin-sync.sh" ] && cp -p "$DIR/plugin-sync.sh" "$B/rdsh/plugin-sync.sh"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$CK/package.json"
printf x > "$CK/.installed"
printf 'BASE=%s\n' "$B" > "$T/rdsh-config"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
          -u DSH_LOG_DIR -u RDSH_WEB_PORT -u RDSH_PLUGIN_ROOT -u RDSH_TRASH \
          RDSH_CONFIG="$T/rdsh-config" HOME="$T/home" \
          bash "$B/rdsh/Rdsh.sh" "$@" </dev/null 2>&1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

echo '--- 1) dry-run：只出计划，不动文件 ---'
out="$(run uninstall 9.9.7-rc.2)"; rc=$?
rc_is "$rc" 0 'dry-run rc=0'
has "$out" '计划（未执行）' '明说只出计划'
[ -d "$CK/node_modules" ] && [ -f "$CK/.installed" ] && ok 'dry-run 后两样都还在' || bad 'dry-run 竟动了文件'
has "$out" '检出与数据保持原样' '承诺检出/数据不动'

echo '--- 2) --apply：移走 node_modules/.installed，检出与数据完好 ---'
out="$(run uninstall 9.9.7-rc.2 --apply)"; rc=$?
rc_is "$rc" 0 'apply rc=0'
[ ! -e "$CK/node_modules" ] && ok 'node_modules 已移走' || bad 'node_modules 还在'
[ ! -e "$CK/.installed" ] && ok '.installed 已移走' || bad '.installed 还在'
[ -f "$CK/package.json" ] && ok '检出本体（package.json）还在' || bad '检出被动了'
[ -d "$DH" ] && ok '数据 home 还在' || bad '数据 home 被动了'
TENT="$(ls -1d "$B/.dsh-suite/trash"/*uninstall* 2>/dev/null | head -1)"
[ -n "$TENT" ] && ok "回收站有条目：$(basename "$TENT")（可整体还原）" || bad '回收站没有条目'
grep -q 'uninstall' "$B/.dsh-suite/state/journal.log" 2>/dev/null && ok '账本有 uninstall 流水' || bad '账本没记流水'

echo '--- 3) 幂等：再跑一次 ---'
out="$(run uninstall 9.9.7-rc.2 --apply)"; rc=$?
rc_is "$rc" 0 '第二次 rc=0'
has "$out" '已经是未安装态' '识别出已是未安装态'

echo '--- 4) 负样本：实例在跑 → 拒绝卸载，文件原样 ---'
if [ -f "$FIXTURE" ] && [ -n "$CC" ]; then
  "$CC" -O0 -o "$T/fake-dsh-web" "$FIXTURE" 2>/dev/null || { echo "夹具编译失败" >&2; exit 2; }
  # 先把"已安装"造回去
  mkdir -p "$CK/node_modules"; printf x > "$CK/.installed"
  MP=$((21000 + ($$ % 15000))); SP=$((MP + 1))
  ( cd "$CK" && DSH_HOME="$DH" exec "$T/fake-dsh-web" "$MP" "$SP" 120 ) &
  FAKE_PID=$!
  sleep 1
  [ -d "/proc/$FAKE_PID" ] || { echo "夹具没起来" >&2; exit 2; }
  out="$(run uninstall 9.9.7-rc.2 --apply)"; rc=$?
  [ "$rc" != "0" ] && ok '在跑时拒绝卸载（rc≠0）' || bad '在跑时竟然卸载了'
  has "$out" '拒绝卸载' '明说拒绝卸载'
  [ -d "$CK/node_modules" ] && [ -f "$CK/.installed" ] && ok '拒绝后文件原样' || bad '拒绝时仍动了文件'
  kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""
else
  echo '  --   跳过（无夹具或 C 编译器）'
fi

echo '--- 5) `rdsh plugins` 转发 ---'
if [ -f "$B/rdsh/plugin-sync.sh" ]; then
  out="$(run plugins --help)"; rc=$?
  rc_is "$rc" 0 'plugins --help rc=0'
  has "$out" 'plugin-sync.sh' '转发到了 plugin-sync.sh'
else
  echo '  --   跳过（无 plugin-sync.sh）'
fi

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
