#!/usr/bin/env bash
# =============================================================================
# smoke-rename.sh —— 检出改名 / 身份重绑 / 目录名规范化（B12）的隔离功能冒烟
#
# 覆盖真机 2026-09-30 那起事故的**每一步**：
#   1. 目录改名 → `state --init` 必须**识别为改名并重绑**，不许铸幻影编号、不许换数据 home
#   2. `rdsh state rebind <旧|键> <新> [--dry-run]`：幂等、dry-run 不动盘、apply 后账本+注册表跟上
#   3. `rdsh state rename <目标> [<新名>] [--apply]`：mv + 账本 dir + `.map` base + 实例注册表 一次改齐；
#      目标已存在（同级不能同名）时**拒绝**
#   4. `doctor`：**`--only <维度>` 不许 0 对象**（维度耦合回归）；断链**按 home 分组**报数并给修复命令
#   5. `doctor --fix-links`：分类 → dry-run 列计划 → `--apply` 重指 + **写备份清单**
#   6. 真机资产逐字节未变
#
# 用法: bash smoke-rename.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'state rebind'; then
  echo "被测脚本里没有 \`state rebind\`（旧版本？先 publish --stage）：$SRC" >&2; exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-suite/state" "$B/.dsh-suite/run/instances"
cp -p "$SRC" "$B/dsh/Rdsh.sh"
[ -f "$(dirname "$SRC")/doctor.sh" ] && cp -p "$(dirname "$SRC")/doctor.sh" "$B/dsh/doctor.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

mkck() { # <目录名> <版本>
  local d="$B/dsh/$1" h="$B/.dsh/$2"
  mkdir -p "$d/node_modules/.pnpm/node_modules/pkg-a" "$h/profiles/node_modules"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf '{"name":"pkg-a","version":"1.0.0"}\n' > "$d/node_modules/.pnpm/node_modules/pkg-a/package.json"
}
mkck ck-1 9.9.7-rc.2
# .map：显式登记数据目录（rename 时要同步 base 名，数据 home 不变）
printf 'dir|ck-1|%s\n' "$B/.dsh/9.9.7-rc.2" > "$B/dsh/.map"
# 实例注册表：指向 ck-1（rename/rebind 后要同步改指）
printf 'port=9999\npid=\nver=9.9.7-rc.2\ndir=%s\ndata=%s\nkind=real\nid=\nunit=\nlog=\nstarted=x\n' \
  "$B/dsh/ck-1" "$B/.dsh/9.9.7-rc.2" > "$B/.dsh-suite/run/instances/9999.kv"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）" ; }
KVD()  { grep -v '^#' "$B/.dsh-suite/state/versions.kv" 2>/dev/null; }

REALB="$HOME/Mapp/.dsh-suite/state/versions.kv"
REAL_BEFORE="$(md5sum "$REALB" 2>/dev/null | cut -c1-32)"

echo '--- 0) 播种账本 ---'
out="$(run state --init 2>&1)"; rc=$?
rc_is "$rc" 0 'state --init rc=0'
has "$(KVD)" '9.9.7-rc.2|9.9.7-rc.2|' '对象键 = 版本号'
has "$(KVD)" "$B/dsh/ck-1" '账本记下检出路径'

echo '--- 1) 目录改名 → state --init 必须识别并重绑（不铸幻影编号） ---'
mv "$B/dsh/ck-1" "$B/dsh/ck-1-renamed"
out="$(run state --init 2>&1)"; rc=$?
rc_is "$rc" 0 '改名后 state --init rc=0'
has "$out" '目录改名' '明确报出"识别为目录改名"'
KV="$(KVD)"
has "$KV" "$B/dsh/ck-1-renamed" '账本的 dir 已重绑到新路径'
hasnt "$KV" '9.9.7-rc.2-2' '**没有**铸出幻影编号 -2'
NROWS="$(printf '%s\n' "$KV" | grep -c . || true)"
[ "$NROWS" = "1" ] && ok "账本仍只有 1 行（没有多出幻影对象）" || bad "账本行数=$NROWS（应为 1）"
has "$KV" "$B/.dsh/9.9.7-rc.2" '数据 home 未变（还是原来那个）'

echo '--- 2) state rebind：dry-run 不动盘，apply 幂等 ---'
BEFORE_MD5="$(md5sum "$B/.dsh-suite/state/versions.kv" | cut -c1-8)"
out="$(run state rebind 9.9.7-rc.2 "$B/dsh/ck-1-renamed" --dry-run 2>&1)"; rc=$?
rc_is "$rc" 0 'rebind dry-run rc=0'
has "$out" 'dry-run' '明说是 dry-run'
[ "$BEFORE_MD5" = "$(md5sum "$B/.dsh-suite/state/versions.kv" | cut -c1-8)" ] && ok 'dry-run 没改账本' || bad 'dry-run 改了账本'
out="$(run state rebind 9.9.7-rc.2 "$B/dsh/ck-1-renamed" 2>&1)"; rc=$?
rc_is "$rc" 0 'rebind apply rc=0'
has "$(KVD)" "$B/dsh/ck-1-renamed" '重绑后账本 dir 正确'

echo '--- 3) state rename：规范化名字（mv + 账本 + .map + 注册表 一次改齐） ---'
out="$(run state rename 9.9.7-rc.2 2>&1)"; rc=$?
rc_is "$rc" 0 'rename dry-run rc=0'
has "$out" 'deepseek-harness-dsh-9.9.7-rc.2' '默认名 = 规范名'
has "$out" '[dry-run]' '默认只出计划'
[ -d "$B/dsh/ck-1-renamed" ] && ok 'dry-run 没有真的 mv' || bad 'dry-run 就改了目录'
# 目标已存在 → 必须拒绝
mkdir -p "$B/dsh/deepseek-harness-dsh-9.9.7-rc.2"
out="$(run state rename 9.9.7-rc.2 --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '目标已存在 → 拒绝（同级不能同名）' || bad '竟然覆盖了同名目录'
has "$out" '同级不能同名' '说明拒绝原因'
rmdir "$B/dsh/deepseek-harness-dsh-9.9.7-rc.2"
out="$(run state rename 9.9.7-rc.2 --apply 2>&1)"; rc=$?
rc_is "$rc" 0 'rename --apply rc=0'
[ -d "$B/dsh/deepseek-harness-dsh-9.9.7-rc.2" ] && ok '目录已改名' || bad '目录没改名'
has "$(KVD)" "$B/dsh/deepseek-harness-dsh-9.9.7-rc.2" '账本 dir 跟着改'
has "$(cat "$B/dsh/.map")" 'dir|deepseek-harness-dsh-9.9.7-rc.2|' '.map 的 base 名同步'
# 注：读侧（instances_live）本来就会把"端口上不在跑"的过期注解退休到 run/stale/（既有行为），
# 所以这里断言的是"注册表里不再残留指向旧路径的注解"（要么已改指、要么已退休）
if [ -f "$B/.dsh-suite/run/instances/9999.kv" ]; then
  hasnt "$(cat "$B/.dsh-suite/run/instances/9999.kv")" "$B/dsh/ck-1-renamed" '实例注册表不再指向旧路径（已改指）'
else
  ok '过期注解已按既有行为退休到 run/stale/（不残留旧路径）'
fi
[ -d "$B/.dsh/9.9.7-rc.2" ] && ok '数据 home 仍未被搬动' || bad '数据 home 被搬了'

echo '--- 4) doctor：--only 不许 0 对象（维度耦合回归） ---'
# 造一条断链（指向不存在的检出），并让"自己检出"下存在同名相对路径 → 可自动修
ln -sfn "$B/dsh/gone-checkout/node_modules/.pnpm/node_modules/pkg-a" \
        "$B/.dsh/9.9.7-rc.2/profiles/node_modules/pkg-a"
out="$(run doctor --only links 2>&1)"; rc=$?
has "$out" '扫了' '--only links 真的扫了对象（不是 0）'
hasnt "$out" '检查对象总数为 0' '没有触发"什么都没查到"'
has "$out" '按 home：' '断链按 home 分组报数'
has "$out" '--fix-links' '给出修复命令'
out="$(run doctor --only entries,links 2>&1)"
has "$out" '9.9.7-rc.2' '只跑两个维度也能列出对象'

echo '--- 5) doctor --fix-links：先 dry-run 再 apply（带备份清单） ---'
out="$(run doctor --fix-links 2>&1)"; rc=$?
rc_is "$rc" 0 'fix-links dry-run rc=0'
has "$out" 'dry-run' '默认 dry-run'
has "$out" '计划重指 1 条' '报出计划重指数'
[ -L "$B/.dsh/9.9.7-rc.2/profiles/node_modules/pkg-a" ] && [ ! -e "$B/.dsh/9.9.7-rc.2/profiles/node_modules/pkg-a" ] \
  && ok 'dry-run 没有真改（链仍断）' || bad 'dry-run 就改了'
out="$(run doctor --fix-links --apply 2>&1)"; rc=$?
rc_is "$rc" 0 'fix-links --apply rc=0'
has "$out" '重指 1 条' '报出实际重指数'
[ -e "$B/.dsh/9.9.7-rc.2/profiles/node_modules/pkg-a" ] && ok '断链已修好（可解析）' || bad '断链没修好'
BK="$(ls -1dt "$B/.dsh-backup"/links-fix-*/ "$B/.dsh-suite/backup"/links-fix-*/ 2>/dev/null | sed -n '1p')"
[ -n "$BK" ] && ok "写了备份清单：$(basename "$BK")" || bad '没有备份清单'
[ -f "$BK/links.kv" ] && ok '清单文件在（可逐条还原）' || bad '清单文件缺失'
out="$(run doctor --only links 2>&1)"
has "$out" '0 条断链' '修复后复扫为 0'

echo '--- 6) 真机未被动过 ---'
[ "$REAL_BEFORE" = "$(md5sum "$REALB" 2>/dev/null | cut -c1-32)" ] && ok '真机账本未变' || bad '真机账本被改了'
out="$(run list 2>&1)"
[ -n "$out" ] && ok '真机隔离 BASE 下 list 正常' || bad 'list 无输出'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
