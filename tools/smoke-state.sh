#!/usr/bin/env bash
# =============================================================================
# smoke-state.sh —— state 账本（B1）的隔离功能冒烟
#
# 为什么必须隔离：上一轮"隔离测试"只换了 HOME，结果动了真机的 .installed 与 回退基线.md。
# 原因是两个隐藏的"外部真相"没堵住：
#   1) RDSH_CONFIG 在环境里被注入 → 就算换了 HOME，配置里的 BACKUP_ROOT 等地对路径仍指向真机
#      ⇒ 做法：RDSH_CONFIG=<临时 BASE 下的不存在文件>
#   2) MANAGE_ROOT 的"脚本自定位回退" → $BASE/dsh 里没有 Rdsh.sh 时会退回脚本自身目录（=真机）
#      ⇒ 做法：把 Rdsh.sh 复制进临时 BASE 的 dsh/ 下，并从那里运行
#   另外ss+/proc 是真宿主状态：角色推断要按"检出目录属于本账本"过滤，否则宿主在跑的实例会漏进来。
#
# 用法: bash smoke-state.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help)
    sed -n '2,/^# =\{20,\}$/p' "$0"
    exit 0
    ;;
esac

SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }

T="$(mktemp -d)"; B="$T/base"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$B/dsh" "$B/.dsh-backup"
cp -p "$SRC" "$B/dsh/Rdsh.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
          -u DSH_LOG_DIR -u DSH_WEB_PORT \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@"; }

# 假检出：版本号刻意避开真机在跑的版本，防止 ss/proc 的宿主状态混进来
mkck() { # <目录名> <版本> [git]
  local d="$B/dsh/$1"; mkdir -p "$d"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"; touch -d '2026-09-10 10:00:00' "$d/.installed"
  if [ "${3:-}" = git ]; then
    mkdir -p "$d/.git/info"; printf 'objects\n' > "$d/.git/info/exclude"
  fi
}
mkck ck-a 9.9.7-rc.2  git
mkck ck-b 9.9.6-beta.1 git
mkck ck-c 9.9.5-alpha.1

cat > "$B/.dsh-backup/回退基线.md" <<'EOF'
# 回退基线（旧手写文件，用于验证 --init 的反向推断与留档）
## 20260925-194617 ｜ 9.9.6-beta.1 → 9.9.7-rc.2
- 源 home：/tmp/x/data/9.9.6-beta.1
- 回退动作：停掉目标版本实例 → `rdsh start 9.9.6-beta.1`
EOF

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }

# 真机 state 资产快照：测试全程必须逐字节不变（上次事故就是这里被改的 —— 比"某文件不该存在"更严格）
REAL="$HOME/Mapp/.dsh-suite"
snap() { local f; for f in "$REAL/backup/回退基线.md" "$REAL/state/versions.kv" "$REAL/state/journal.log"; do
           [ -f "$f" ] && md5sum "$f"; done; }
SNAP_BEFORE="$(snap)"

SK="$B/.dsh-suite/state"

echo '--- 1) 空账本：只读，不建目录 ---'
out="$(run state list 2>&1)"; rc=$?
has "$out" '账本还不存在' 'state list 在空账本上给出提示'
[ "$rc" = 0 ] && ok 'state list 退出码 0' || bad "state list 退出码 $rc"
[ -d "$SK" ] && bad 'state list 建了 state 目录（应只读）' || ok 'state list 未落盘'

echo '--- 2) --init --dry-run：不落任何盘 ---'
out="$(run state --init --dry-run 2>&1)"; rc=$?
has "$out" '依据：.installed 的 mtime' 'dry-run 打印推断依据'
has "$out" 'dry-run] 将把' 'dry-run 预告留档动作'
[ "$rc" = 0 ] && ok 'dry-run 退出码 0' || bad "dry-run 退出码 $rc"
[ -d "$SK" ] && bad 'dry-run 建了 state 目录（应不落盘）' || ok 'dry-run 未落盘'
hasnt "$out" '错误的替换' '无 bash 替换语法错误'
hasnt "$out" 'bad substitution' '无 bad substitution'

echo '--- 3) --init 真跑：账本 + 流水 + 留档 + 生成视图 ---'
out="$(run state --init 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok 'state --init 退出码 0' || { bad "state --init 退出码 $rc"; printf '%s\n' "$out" | sed 's/^/      /'; }
[ -f "$SK/versions.kv" ] && ok '账本 versions.kv 已建' || bad '账本缺失'
[ -f "$SK/journal.log" ] && ok '流水 journal.log 已建' || bad '流水缺失'
[ -f "$SK/回退基线-历史.md" ] && ok '旧手写基线已留档' || bad '旧手写基线未留档'
[ -f "$B/.dsh-backup/回退基线.md" ] && ok '人读视图已生成' || bad '人读视图缺失'
has "$(head -1 "$B/.dsh-backup/回退基线.md" 2>/dev/null)" 'rdsh-generated' '视图带生成标记'
has "$(cat "$SK/回退基线-历史.md" 2>/dev/null)" '旧手写文件' '留档保留了原文'
[ "$(grep -c '^9\.9\.' "$SK/versions.kv")" = 3 ] && ok '账本登记 3 个对象' || bad "账本对象数=$(grep -c '^9\.9\.' "$SK/versions.kv")"
has "$(cat "$SK/versions.kv")" 'baseline' '从旧基线推断出 baseline 角色'
hasnt "$(cat "$SK/versions.kv")" '|current|' '无在跑实例可对应时不乱写 current'
has "$(cat "$SK/versions.kv")" "$B/dsh/ck-a" '账本记下检出路径'

echo '--- 4) .installed 回声 + .git/info/exclude ---'
has "$(cat "$B/dsh/ck-a/.installed")" 'key=9.9.7-rc.2' '.installed 升级为 KEY=VALUE'
has "$(cat "$B/dsh/ck-a/.installed")" 'role=installed' '.installed 带角色'
has "$(cat "$B/dsh/ck-a/.installed")" 'state_journal_lines=' '.installed 带流水游标'
case "$(cat "$B/dsh/ck-a/.git/info/exclude")" in
  *'.installed'*) ok '.installed 已进 .git/info/exclude' ;;
  *) bad '.git/info/exclude 未加 .installed' ;;
esac

echo '--- 5) list / state list / show 互通 ---'
has "$(run list 2>&1)" 'installed' 'rdsh list 显示角色列'
has "$(run state list 2>&1)" '9.9.7-rc.2' 'state list 列出对象'
has "$(run state list 2>&1)" "$B/dsh/ck-b" 'state list 列出检出'
out="$(run state show 9.9.6 2>&1)"
has "$out" 'role' 'state show 按版本片段解析到对象'
has "$out" 'baseline' 'state show 显示推断出的角色'

echo '--- 6) role：改角色 + 拒绝幽灵对象 ---'
out="$(run state role 9.9.7-rc.2 current 2>&1)"
has "$out" '角色已改' 'state role 改角色'
has "$(cat "$SK/versions.kv")" '|current|' '账本写入角色'
has "$(run state journal 2>&1)" 'role' '流水记下角色变更'
out="$(run state role 9.9.9-nope current 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '改不存在的对象会失败' || bad '改不存在的对象竟然成功'
hasnt "$(cat "$SK/versions.kv")" '9.9.9-nope' '不存在的对象没有被写成幽灵行'
out="$(run state role 9.9.7-rc.2 乱写的角色 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '非法角色被拒绝' || bad '非法角色竟然通过'

echo '--- 7) render 幂等 ---'
run state render >/dev/null 2>&1
has "$(head -1 "$B/.dsh-backup/回退基线.md")" 'rdsh-generated' '二次 render 仍带标记（未自我覆盖失败）'
has "$(cat "$B/.dsh-backup/回退基线.md")" '迁移期历史' '视图带上留档了的历史'

echo '--- 8) record-migration（migrate.sh 的窄接口） ---'
out="$(run state record-migration 9.9.6-beta.1 9.9.7-rc.2 --backup /x/bak --sessions all --probe '## 结论：✅ 未发现' 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok 'record-migration 退出码 0' || bad "record-migration 退出码 $rc"
has "$out" '已记录迁移' '打印迁移记录'
has "$(run state show 9.9.7-rc.2 2>&1)" '9.9.6-beta.1' '目标记下 migrated_from'
has "$(run state show 9.9.6-beta.1 2>&1)" '9.9.7-rc.2' '源记下 baseline_for（它就是回退目标）'
has "$(run state journal 2>&1)" 'migrate' '流水里有 migrate 事件'
r1="$(grep -c '|migrate|' "$SK/journal.log")"
run state record-migration 9.9.6-beta.1 9.9.7-rc.2 >/dev/null 2>&1
r2="$(grep -c '|migrate|' "$SK/journal.log")"
[ "$r2" -gt "$r1" ] && ok '重复记录则追加（历史只增不改）' || bad '重复记录没有追加流水'
out="$(run state record-migration 9.9.9-nope 9.9.7-rc.2 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '源不存在时 record-migration 失败' || bad '源不存在竟然成功'
hasnt "$(cat "$SK/versions.kv")" '9.9.9-nope' '未把不存在的源写成幽灵行'
has "$(cat "$B/.dsh-backup/回退基线.md")" 'migrate' '视图里能看到迁移事件'

echo '--- 9) 真实资产未被触碰（逐字节） ---'
SNAP_AFTER="$(snap)"
if [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then
  ok '真机 state/回退基线 逐字节未变'
else
  bad '真机 state/回退基线 被本测试改动'
  printf '%s\n' "$SNAP_BEFORE" | sed 's/^/      前: /'
  printf '%s\n' "$SNAP_AFTER"  | sed 's/^/      后: /'
fi

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
