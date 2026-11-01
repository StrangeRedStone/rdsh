#!/usr/bin/env bash
# =============================================================================
# smoke-port-owner.sh —— 端口归属判定的隔离冒烟（2026-11-01 修「9230 两种口径」）
#
# 背景：dsh 0.2.1 起，一个 web 进程会**同时**监听实例端口（如 3080）与 inspector/CDP
#       侧信道端口（默认 9230，被占则顺延）。旧版 rdsh 的 start 占用检查把 proc_cwd 当
#       "检出"报出去，于是把侧信道说成"运行中的另一版本"，而 stop 查实例表又说"没有实例"
#       —— 同一端口两套口径。
#
# 本冒烟用**真子进程**（tools/fixtures/fake-dsh-web.c：argv 改写成 "bin.ts web"、cwd 是
# 假检出、同时监听两个端口）跑完整链路，钉住：
#   * 侧信道端口 → 报"实例 X 的 inspector/CDP 侧信道"，不再说"运行中检出：另一版本"
#   * 实例端口   → 报"已运行的实例"
#   * 非 dsh 进程 → 报"非 dsh 进程（pid/cmd）"，不伪造检出
#   * 契约：带 --port 的 start --dry-run 遇占用 → rc=1 且**一个进程都不起**
#
# 用法: bash smoke-port-owner.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
grep -q 'port_instance_identity' "$SRC" 2>/dev/null || {
  echo "被测脚本没有 port_instance_identity（旧版本？先 publish --stage）：$SRC" >&2; exit 2; }

FIXTURE="$(dirname "$(readlink -f "$0")")/fixtures/fake-dsh-web.c"
CC="$(command -v cc || command -v gcc || true)"
if [ ! -f "$FIXTURE" ]; then echo "缺少夹具 $FIXTURE → 跳过" >&2; exit 0; fi
if [ -z "$CC" ]; then echo "没有 C 编译器（cc/gcc）→ 跳过端口归属冒烟（CI 上通常有）" >&2; exit 0; fi

T="$(mktemp -d)"; B="$T/base"
FAKE_PID=""; OTHER_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null || true
  [ -n "$OTHER_PID" ] && kill "$OTHER_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# 夹具布局从工具推导（同其它冒烟）：本工具即唯一真源
mkdir -p "$B/rdsh"
cp -p "$SRC" "$B/rdsh/Rdsh.sh"
eval "$(env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
        -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
        -u DSH_LOG_DIR -u DSH_WEB_PORT -u RDSH_PLUGIN_ROOT \
        RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/rdsh/Rdsh.sh" base --print-paths 2>/dev/null)"
mkdir -p "$MANAGE_ROOT" "$DATA_ROOT" "$RUN_DIR/instances" "$BACKUP_ROOT" "$LOG_DIR" 2>/dev/null || true

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$MANAGE_ROOT/Rdsh.sh" "$@" </dev/null; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }

echo '--- 0) 真机资产指纹（本测试绝不碰真机） ---'
_rc="$HOME/.config/rdsh/config"
_rb="$(sed -nE 's/^[[:space:]]*BASE[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$_rc" 2>/dev/null | tail -1)"
REAL_ROOT="${_rb:-$HOME/dsh}"
REAL="$REAL_ROOT/.dsh-suite"
snap_real() { find "$REAL/state" "$REAL/trash" "$REAL/backup" -maxdepth 1 2>/dev/null | sort; }
REAL_BEFORE="$(snap_real)"

echo '--- 1) 编译夹具 + 造一个"像 dsh web"的长命进程 ---'
"$CC" -O0 -o "$T/fake-dsh-web" "$FIXTURE" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; echo "夹具编译失败" >&2; exit 2; }
ok '夹具编译通过'

CK="$MANAGE_ROOT/deepseek-harness-dsh-9.9.7-rc.2"
mkdir -p "$CK"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$CK/package.json"
printf x > "$CK/.installed"
DH="$DATA_ROOT/9.9.7-rc.2"; mkdir -p "$DH"

MAIN_PORT=$((20000 + ($$ % 20000)))
SIDE_PORT=$((MAIN_PORT + 1))
OTHER_PORT=$((MAIN_PORT + 2))
( cd "$CK" && exec "$T/fake-dsh-web" "$MAIN_PORT" "$SIDE_PORT" 300 ) &
FAKE_PID=$!
sleep 1
[ -d "/proc/$FAKE_PID" ] || { echo "夹具进程没起来" >&2; exit 2; }
echo "  实例端口=$MAIN_PORT 侧信道=$SIDE_PORT pid=$FAKE_PID"
case "$(tr '\0' ' ' < "/proc/$FAKE_PID/cmdline")" in
  *'bin.ts web'*) ok '夹具 argv 已伪装成 bin.ts web' ;;
  *) bad '夹具 argv 改写失败' ;;
esac

# 只把"这一个真进程"登记成实例（注册表是注解层，真相层仍是 ss + /proc）
printf 'port=%s\npid=%s\nver=9.9.7-rc.2\ndir=%s\nkind=real\n' "$MAIN_PORT" "$FAKE_PID" "$CK" > "$RUN_DIR/instances/$MAIN_PORT.kv"

echo '--- 2) 侧信道端口（用户报的 9230 场景）：不再说成"另一版本" ---'
out="$(run 9.9.7-rc.2 --port "$SIDE_PORT" --dry-run 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
has "$out" '侧信道' '侧信道被识别'
has "$out" "$MAIN_PORT" '点出了真正的实例端口'
has "$out" '不是独立实例' '明说不是独立实例'
hasnt "$out" "运行中检出：$CK" '不再把侧信道说成"运行中检出：另一版本"'
[ "$rc" = 1 ] && ok "dry-run 遇冲突 rc=1（实际 $rc）" || bad "rc 应为 1，实际 $rc"
[ ! -e "$LOG_DIR/web-9.9.7-rc.2-$SIDE_PORT.log" ] && ok '没有生成启动日志（没真起）' || bad '竟然落了启动日志'

echo '--- 3) 实例端口本身：说"已运行的实例" ---'
out3="$(run 9.9.7-rc.2 --port "$MAIN_PORT" --dry-run 2>&1)"
has "$out3" '已运行的实例' '实例端口如实说"已运行的实例"'

echo '--- 4) 非 dsh 进程：如实说是别的进程，不伪造检出 ---'
# 必须真监听端口（sleep 不监听，port_busy 看不到它）；python3 是可移植的最小选择
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
time.sleep(300)
' "$OTHER_PORT" >/dev/null 2>&1 &
OTHER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ss -ltnH "sport = :$OTHER_PORT" 2>/dev/null | grep -q . && break
  sleep 0.2
done
printf 'port=%s\npid=%s\nver=\ndir=/x\nkind=real\n' "$OTHER_PORT" "$OTHER_PID" > "$RUN_DIR/instances/$OTHER_PORT.kv"
out2="$(run 9.9.7-rc.2 --port "$OTHER_PORT" --dry-run 2>&1)"
printf '%s\n' "$out2" | sed 's/^/    /'
has "$out2" '非 dsh 进程' '非 dsh 进程如实归类'
has "$out2" "pid $OTHER_PID" '点出了真实 pid'
hasnt "$out2" '检出：' '非 dsh 进程不给"检出："（那是 dsh 才有的信息，会误导）'

echo '--- 5) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(snap_real)" ] && ok '真机 state/trash/backup 未变' || bad '真机资产被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
