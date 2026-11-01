#!/usr/bin/env bash
# =============================================================================
# smoke-migrate.sh —— `rdsh migrate` 前门 + 通用 migrate.sh 的隔离功能冒烟
#
# 覆盖：
#   * 前门发现提供者（generic / 特化文件头）、--list
#   * 显式参数：缺 items / 未知 items 必须 rc=2
#   * plan 闸门：generic --dry-run rc=0 且**零写入**
#   * 多提供者未指定 --provider 必须 rc=2；指定后可跑
#   * fake 提供者 plan 失败 → rc=2；加 -f → 继续并写日志/归档
#   * 目标 home 有实例在跑 → rc=3 硬停（-f 不越过）
#   * 真机 state/trash 一字未动
#
# 用法: bash smoke-migrate.sh [Rdsh.sh 路径] [前门路径]
#   前门默认取 $RDSH_MIGRATE_FRONTDOOR 或 ~/dsh/rdsh/plugins.d/rdsh-migrate.sh；
#   主仓库白名单不含 plugins.d/，本机跑时从前门所在部署目录取，干净 clone 需显式给。
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
HERE="$(dirname "$(readlink -f "$0")")"
[ -f "$HERE/../migrate.sh" ] || { echo "找不到 migrate.sh: $HERE/../migrate.sh" >&2; exit 2; }
FRONT="${2:-${RDSH_MIGRATE_FRONTDOOR:-$HOME/dsh/rdsh/plugins.d/rdsh-migrate.sh}}"
[ -f "$FRONT" ] || { echo "找不到前门: $FRONT（用第二个参数或 RDSH_MIGRATE_FRONTDOOR 指定）" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh migrate'; then
  echo "被测脚本里没有 \`rdsh migrate\`（旧版本？先 publish --stage）：$SRC" >&2
  exit 2
fi

T="$(mktemp -d)"; B="$T/base"
cleanup() { [ -n "${RUNPID:-}" ] && kill "$RUNPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$B/rdsh/plugins.d" "$B/.dsh-suite/state" "$B/.dsh-suite/data" \
         "$B/.dsh-suite/shared/skills" "$B/.dsh-suite/shared/.agent-presets"
cp -p "$SRC" "$B/rdsh/Rdsh.sh"
cp -p "$HERE/../migrate.sh" "$B/rdsh/migrate.sh"
cp -p "$FRONT" "$B/rdsh/plugins.d/rdsh-migrate.sh"
: > "$B/.dsh-suite/shared/lessons.md"; : > "$B/.dsh-suite/shared/AGENTS.md"
: > "$B/.dsh-suite/shared/facts.md"; : > "$B/.dsh-suite/shared/backlog.md"

mkck() { # <目录名> <版本>
  local d="$B/rdsh/$1"
  mkdir -p "$d/node_modules"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"
  mkdir -p "$B/.dsh-suite/data/$2/sessions"
}
mkck deepseek-harness-dsh-9.9.6 9.9.6
mkck deepseek-harness-dsh-9.9.7 9.9.7

run() {
  env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
      -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
      -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u DSH_WEB_PORT \
      RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" \
      bash "$B/rdsh/Rdsh.sh" "$@" </dev/null
}
mkfake() { # <文件名> <id> <plan-rc>
  cat > "$B/rdsh/$1" <<EOF
#!/usr/bin/env bash
# rdsh-migrate: from=9.9.6 to=9.9.7 id=$2 items=assets summary=冒烟假提供者
case " \$* " in
  *" --dry-run "*) echo "[fake] plan $2"; exit $3 ;;
esac
echo "[fake] apply $2"
EOF
  chmod 755 "$B/rdsh/$1"
}

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
rc_is() { [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

# 真机 state/trash 指纹
_rc="$HOME/.config/rdsh/config"
_rb="$(sed -nE 's/^[[:space:]]*BASE[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$_rc" 2>/dev/null | tail -1)"
REAL_ROOT="${_rb:-$HOME/dsh}"
REAL="$REAL_ROOT/.dsh-suite"
real_state() { find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort; }
REAL_BEFORE="$(real_state)"

echo '--- 1) 前门发现提供者 ---'
out="$(run migrate --list 2>&1)"
has "$out" 'generic' '--list 有 generic'
has "$out" "$B/rdsh/migrate.sh" '--list 路径来自隔离 MANAGE_ROOT'

echo '--- 2) 显式参数 ---'
run migrate --from 9.9.6 --to 9.9.7 --dry-run >/dev/null 2>&1; rc_is "$?" 2 '缺 items 必须 rc=2'
run migrate --from 9.9.6 --to 9.9.7 --items nope --dry-run >/dev/null 2>&1; rc_is "$?" 2 '未知 items 必须 rc=2'

echo '--- 3) 通用 plan：rc=0 且零写入 ---'
before="$(find "$B" -type f | sort)"
out="$(run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --dry-run --provider generic 2>&1)"; rc=$?
rc_is "$rc" 0 'generic dry-run rc=0'
has "$out" '模式       : dry-run' 'plan 标了 dry-run'
has "$out" '没有写入任何东西' '打印零写入'
after="$(find "$B" -type f | sort)"
[ "$before" = "$after" ] && ok 'dry-run 后文件集合未变' || bad 'dry-run 写了文件'

echo '--- 4) 多提供者必须显式 --provider ---'
mkfake migrate-9.9.6-to-9.9.7-fake.sh fake 0
run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --dry-run >/dev/null 2>&1
rc_is "$?" 2 '多提供者未指定必须 rc=2'
out="$(run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --dry-run --provider fake 2>&1)"; rc=$?
rc_is "$rc" 0 '指定 fake 后 plan rc=0'
has "$out" '[fake] plan fake' '实际调用了 fake'

echo '--- 5) plan 失败与 -f ---'
mkfake migrate-9.9.6-to-9.9.7-bad.sh bad 1
run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --provider bad >/dev/null 2>&1
rc_is "$?" 2 'plan 失败无 -f 必须 rc=2'
out="$(run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --provider bad -f 2>&1)"; rc=$?
rc_is "$rc" 0 '-f 后继续 rc=0'
has "$out" '[fake] apply bad' '告诉用户已继续'

echo '--- 6) 目标在跑硬停 ---'
env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT \
    DSH_HOME="$B/.dsh-suite/data/9.9.7" sleep 60 >/dev/null 2>&1 &
RUNPID=$!
sleep 0.3
run migrate --from 9.9.6 --to 9.9.7 --items assets --sessions none --dry-run --provider generic >/dev/null 2>&1
rc_is "$?" 3 '目标 home 在跑必须 rc=3'
kill "$RUNPID" 2>/dev/null; RUNPID=""

echo '--- 7) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(real_state)" ] && ok '真机 state/trash 未变' || bad '真机 state/trash 被改'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
