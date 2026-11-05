#!/usr/bin/env bash
# =============================================================================
# smoke-base-guard.sh —— `rdsh base` 的「旧根有实例在跑 → 硬拒绝」守卫（2026-11-05）
#
# 背景：`rdsh base <新根>` 会搬整棵树。若旧根里的东西正被实例使用，搬 = 写入者运行时
#       动它的数据（家规 6）。守卫要求先停再搬。此前只做了代码、未隔离实测（队列挂账）。
#
# 作法：真子进程夹具（tools/fixtures/fake-dsh-web.c，argv="bin.ts web"、cwd 是假检出、
#       监听两个端口）+ 假旧根 + 真 `ss`/`/proc` 真相层，跑完整 `rdsh base` 链路：
#   * 旧根有"实例" → 必须硬拒绝，且**一个文件都不动**
#   * 停掉实例后 → 同一命令可通过（dry-run 出计划）
#   * 旧根无实例、但**真机别的实例**在跑 → 不得误伤
#   * 可选：EVIDENCE_DIR 给出时，另存一份"隔离根搬前 doctor 原始输出"（队列②的凭据）
#
# 用法: bash smoke-base-guard.sh [Rdsh.sh 路径]
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
[ -f "$FIXTURE" ] || { echo "缺夹具 $FIXTURE → 跳过" >&2; exit 0; }
[ -n "$CC" ] || { echo "没有 C 编译器 → 跳过" >&2; exit 0; }

T="$(mktemp -d)"; FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

OLD="$T/base-old"; NEW="$T/base-new"; HOME="$T/home"; mkdir -p "$HOME"
CK="$OLD/rdsh/deepseek-harness-dsh-9.9.7-rc.2"
DH="$OLD/.dsh-suite/data/9.9.7-rc.2"
mkdir -p "$CK" "$DH" "$OLD/.dsh-suite/state" "$OLD/.dsh-suite/backup"
cp -p "$SRC" "$OLD/rdsh/Rdsh.sh"
[ -f "$DIR/doctor.sh" ] && cp -p "$DIR/doctor.sh" "$OLD/rdsh/doctor.sh"
mkdir -p "$OLD/rdsh/tools"; cp -p "$DIR/tools/lib-roots.sh" "$OLD/rdsh/tools/"
[ -f "$DIR/scan-secrets.sh" ] && cp -p "$DIR/scan-secrets.sh" "$OLD/rdsh/scan-secrets.sh"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$CK/package.json"
printf x > "$CK/.installed"
printf 'BASE=%s\n' "$OLD" > "$T/rdsh-config"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
rc_nonzero() { [ "$1" != "0" ] && ok "$2" || bad "$2（期望非 0，实际 0）"; }

run_base() {  # <dry-run 与否> → 输出；rc 由调用方取
  env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
      -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
      -u DSH_LOG_DIR -u DSH_WEB_PORT -u RDSH_PLUGIN_ROOT -u RDSH_TRASH \
      RDSH_CONFIG="$T/rdsh-config" HOME="$HOME" \
      bash "$OLD/rdsh/Rdsh.sh" base "$NEW" "$@" </dev/null 2>&1
}

snap_tree() { find "$OLD" "$NEW" -mindepth 1 2>/dev/null | sort; }

echo '--- 0) 隔离根基线 ---'
"$CC" -O0 -o "$T/fake-dsh-web" "$FIXTURE" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; exit 2; }
ok '夹具编译通过'
[ -f "$OLD/rdsh/Rdsh.sh" ] && ok '假旧根就位（rdsh + 检出 + 数据 home）' || bad '假旧根不完整'

# ② 队列挂账：隔离根搬前 doctor 原始输出（给出 EVIDENCE_DIR 时才另存）
if [ -n "${EVIDENCE_DIR:-}" ] && [ -f "$OLD/rdsh/doctor.sh" ]; then
  mkdir -p "$EVIDENCE_DIR"
  env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
      -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
      -u DSH_LOG_DIR -u RDSH_PLUGIN_ROOT -u RDSH_TRASH \
      RDSH_CONFIG="$T/rdsh-config" HOME="$HOME" \
      bash "$OLD/rdsh/doctor.sh" --json > "$EVIDENCE_DIR/doctor-before.json" 2> "$EVIDENCE_DIR/doctor-before.err" || true
  ok "已单留隔离根搬前 doctor 原始输出：$EVIDENCE_DIR/doctor-before.json"
fi

echo '--- 1) 旧根无实例 → dry-run 出计划（基线） ---'
BEFORE="$(snap_tree)"
out="$(run_base --dry-run)"; rc=$?
[ "$rc" = 0 ] && ok "无实例时 dry-run rc=0" || bad "无实例时 rc=$rc（应 0）"
has "$out" '搬迁' 'dry-run 打印了搬迁计划'

echo '--- 2) 旧根有"实例"在跑 → 必须硬拒绝 ---'
MP=$((21000 + ($$ % 15000))); SP=$((MP + 1))
( cd "$CK" && DSH_HOME="$DH" exec "$T/fake-dsh-web" "$MP" "$SP" 300 ) &
FAKE_PID=$!
sleep 1
[ -d "/proc/$FAKE_PID" ] || { echo "夹具进程没起来" >&2; exit 2; }
ok "假实例在跑（pid=$FAKE_PID, 端口 $MP/$SP，检出在旧根内）"

BEFORE="$(snap_tree)"
out="$(run_base --dry-run)"; rc=$?
rc_nonzero "$rc" '有实例时 dry-run 也被硬拒绝（rc≠0）'
has "$out" '正被实例使用' '点明"正被实例使用"'
has "$out" '先停再搬' '给出"先停再搬"的处置'
has "$out" '本次什么都没动' '明说未动任何东西'
AFTER="$(snap_tree)"
[ "$BEFORE" = "$AFTER" ] && ok '现场一个文件都没动（拒绝前后树一致）' || bad '拒绝时仍改动了文件'

echo '--- 3) 停掉实例 → 同一命令可通过 ---'
kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""
sleep 0.5
out="$(run_base --dry-run)"; rc=$?
[ "$rc" = 0 ] && ok '停实例后 dry-run rc=0' || bad "停实例后 rc=$rc（应 0）"
has "$out" '搬迁' 'dry-run 正常给出计划'

echo '--- 4) 不误伤：旧根无实例、真机别的实例在跑 ---'
# 真机实例的 cwd 在真实 BASE 下，不在本假旧根下 → 守卫不该触发
out="$(run_base --dry-run)"; rc=$?
[ "$rc" = 0 ] && ok '真机实例不在旧根下 → 不误伤' || bad "被真机实例误伤：rc=$rc"

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
