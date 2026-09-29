#!/usr/bin/env bash
# =============================================================================
# smoke-retire.sh —— `rdsh retire`（退役）的隔离功能冒烟
#
# 覆盖五类足迹：
#   ① 检出  ② 数据 home  ③ home 内插件链（随 home 走）  ④ **外部软链**（必须一起收走）
#   ⑤ 日志 / 注册表 / .map 行 / 账本角色
# 硬断言：
#   * 默认只出计划（什么都不动）；`--apply` 才动
#   * ①②④ 进**同一个**回收条目（清单里逐项还原命令）
#   * `.map` 里指向它的行被删；账本角色 → retired + 流水留墓碑；过期注册表条目退休
#   * 退役后**不留断链**（外部软链被一起收走，而不是留在原地变成断链）
#   * `trash restore` 能把①②④**整份还原**
#   * 守卫：回退基线 / 最后一版可用版本，没 --force 就拒绝；--force 才放行
#   * 真机 trash/state 逐项未变
#
# 用法: bash smoke-retire.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh retire'; then
  echo "被测脚本里没有 \`rdsh retire\`（旧版本？先 publish --stage）：$SRC" >&2
  exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-shared" "$B/.dsh-suite/state" "$B/.dsh-suite/run/instances"
cp -p "$SRC" "$B/dsh/Rdsh.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

# 两个假检出 + 数据 home + home 内插件链
mkck() { # <目录名> <版本>
  local d="$B/dsh/$1" h="$B/.dsh/$2" ext="$3"
  mkdir -p "$d/node_modules" "$d/.git/info" "$d/packages/core" "$h/profiles/node_modules/@deepseek-ai" "$h/sessions"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"; printf 'objects\n.installed\n' > "$d/.git/info/exclude"
  printf 's\n' > "$h/sessions/s1.json"
  # ③ home 内插件链 → 指向检出（随 home 走）
  ln -sfn "$d/packages/core" "$h/profiles/node_modules/@deepseek-ai/dsh-core"
  # ④ 外部软链 → 放在稳定根里，指向检出
  [ "$ext" = "ext" ] && ln -sfn "$d/packages/core" "$B/.dsh-shared/external-link-$(basename "$d")"
}
mkck ck-a 9.9.7-rc.2 ext      # 待退役（有外部链）
mkck ck-b 9.9.6-beta.1 ext    # 回退基线 / 另一个可用版本

# .map：给 ck-a 加一行指向它的 dir 行
printf 'dir|ck-a|%s\n' "$B/.dsh/9.9.7-rc.2" > "$B/dsh/.map"
# 实例注册表：一条指向 ck-a 的陈旧注解
printf 'port=9999\npid=\nver=9.9.7-rc.2\ndir=%s\ndata=%s\nkind=real\nid=\nunit=\nlog=\nstarted=2026-01-01T00:00:00+08:00\n' \
  "$B/dsh/ck-a" "$B/.dsh/9.9.7-rc.2" > "$B/.dsh-suite/run/instances/9999.kv"
# 账本：ck-a=installed、ck-b=baseline
{
  printf '# rdsh state —— 测试账本\n'
  printf '# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note\n'
  printf '9.9.7-rc.2|9.9.7-rc.2|installed||2026-09-01T00:00:00+08:00|local:x||2026-09-01T00:00:00+08:00|||%s|%s|\n' "$B/dsh/ck-a" "$B/.dsh/9.9.7-rc.2"
  printf '9.9.6-beta.1|9.9.6-beta.1|baseline||2026-09-02T00:00:00+08:00|local:y||2026-09-02T00:00:00+08:00|||%s|%s|\n' "$B/dsh/ck-b" "$B/.dsh/9.9.6-beta.1"
} > "$B/.dsh-suite/state/versions.kv"
printf '# journal\n2026-09-29T00:00:00+08:00|init|9.9.7-rc.2|test\n' > "$B/.dsh-suite/state/journal.log"
printf '<!-- rdsh-generated —— 测试 -->\n# 回退基线\n' > "$B/.dsh-backup/回退基线.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

TR="$B/.dsh-suite/trash"
SNAP() { find "$B/.dsh-suite/trash" "$B/dsh" "$B/.dsh" -maxdepth 2 2>/dev/null | sort | while IFS= read -r x; do
           printf '%s %s\n' "$x" "$(stat -c '%s %Y' "$x" 2>/dev/null)"; done; }
REAL="$HOME/Mapp/.dsh-suite"
snap_real() { find "$REAL/trash" "$REAL/state" -maxdepth 1 2>/dev/null | sort; }
REAL_BEFORE="$(snap_real)"

echo '--- 1) 默认只出计划：什么都不许动 ---'
BEFORE="$(SNAP)"
out="$(run retire 9.9.7-rc.2 2>&1)"; rc=$?
rc_is "$rc" 0 '--plan（默认）rc=0'
has "$out" '① 检出' '清单含①检出'
has "$out" '② 数据' '清单含②数据'
has "$out" '④ 外部软链 1 条' '清单正确识别**外部**链（home 内的链不算）'
has "$out" '计划（未执行）' '明说未执行'
AFTER="$(SNAP)"
[ "$BEFORE" = "$AFTER" ] && ok '计划阶段没有任何改动' || bad '计划阶段就动东西了！'
[ -d "$B/dsh/ck-a" ] && [ -d "$B/.dsh/9.9.7-rc.2" ] && ok '检出与数据都还在' || bad '计划阶段被挪走了'

echo '--- 2) 守卫：最后一版可用（这里 2 个可用，先删掉另一个再试） ---'
# 把 ck-b 标成 retired（只剩 ck-a 可用）→ 应拒绝
run state role 9.9.6-beta.1 retired >/dev/null 2>&1
out="$(run retire 9.9.7-rc.2 --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '最后一版可用 → 拒绝' || bad '竟然允许退役最后一版'
has "$out" '没有别的可用版本' '说明理由'
[ -d "$B/dsh/ck-a" ] && ok '被拒绝时没有动它' || bad '被拒绝却动了'
run state role 9.9.6-beta.1 baseline >/dev/null 2>&1

echo '--- 3) 守卫：回退基线要 --force 并写明后果 ---'
out="$(run retire 9.9.6-beta.1 --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '基线 → 拒绝' || bad '竟然允许退役基线'
has "$out" '回退只能靠' '写明后果'
[ -d "$B/dsh/ck-b" ] && ok '被拒绝时没有动它' || bad '被拒绝却动了'

echo '--- 4) 退役 9.9.7-rc.2：五类足迹一起收走 ---'
out="$(run retire 9.9.7-rc.2 --apply 2>&1)"; rc=$?
rc_is "$rc" 0 '--apply rc=0'
[ ! -d "$B/dsh/ck-a" ] && ok '① 检出已挪走' || bad '① 检出还在'
[ ! -d "$B/.dsh/9.9.7-rc.2" ] && ok '② 数据 home 已挪走' || bad '② 数据还在'
[ ! -L "$B/.dsh-shared/external-link-ck-a" ] && ok '④ 外部软链已一起收走（不留断链）' || bad '④ 外部链留在原地会成断链'
E="$(ls -1dt "$TR"/*/ 2>/dev/null | sed -n '1p')"
[ -n "$E" ] && ok "生成了一个回收条目：$(basename "$E")" || bad '没有回收条目'
[ -f "$E/.rdsh-trash.kv" ] && ok '条目带清单' || bad '条目缺清单'
N="$(grep -c '^orig\.' "$E/.rdsh-trash.kv" 2>/dev/null || true)"
[ "${N:-0}" -ge 3 ] && ok "清单记了 $N 项（检出+数据+外部链 在同一入口）" || bad "清单只记了 ${N:-0} 项"
has "$(cat "$E/.rdsh-trash.kv")" 'restore.1=mv ' '清单带逐项还原命令'
hasnt "$(cat "$B/dsh/.map" 2>/dev/null)" 'ck-a' '.map 里指向它的行已删'
has "$(cat "$B/.dsh-suite/state/versions.kv")" '|retired|' '账本角色已置 retired'
has "$(cat "$B/.dsh-suite/state/journal.log")" '|retire|' '流水留了墓碑'
# 注：读侧（instances_live）本来就会把"端口上已不在跑"的注解退休到 run/stale/，
# 所以这里只需断言"过期注解不再污染 instances/"（退役过程也再做了一遍，是防御性的）
[ ! -f "$B/.dsh-suite/run/instances/9999.kv" ] && ok '过期注册表注解已不再占用 instances/' || bad '过期注解还在 instances/' 
has "$out" 'rdsh trash restore' '输出了整份还原命令'

echo '--- 5) 退役后不留断链 ---'
out="$(run doctor --only links 2>&1)"; rc=$?
hasnt "$out" '断链' 'doctor 报无断链'
hasnt "$out" 'external-link-ck-a' '外部链没有变成断链'

echo '--- 6) trash restore 能整份还原 ---'
out="$(run trash restore --last --force 2>&1)"; rc=$?
rc_is "$rc" 0 'restore rc=0'
[ -d "$B/dsh/ck-a" ] && ok '① 检出已还原' || bad '① 未还原'
[ -d "$B/.dsh/9.9.7-rc.2" ] && ok '② 数据已还原' || bad '② 未还原'
[ -L "$B/.dsh-shared/external-link-ck-a" ] && ok '④ 外部链已还原' || bad '④ 未还原'
if [ -L "$B/.dsh-shared/external-link-ck-a" ]; then
  [ -e "$B/.dsh-shared/external-link-ck-a" ] && ok '还原后的链指向存在的目标' || bad '还原后是断链'
fi

echo '--- 7) 无目标 = 列候选 ---'
run state role 9.9.6-beta.1 retire-candidate >/dev/null 2>&1
out="$(run retire 2>&1)"
has "$out" '退役候选' '有候选标题'
has "$out" '9.9.6-beta.1' '列出 retire-candidate 对象'

echo '--- 8) --force 放行基线 ---'
run state role 9.9.6-beta.1 baseline >/dev/null 2>&1     # 第 7 节标成了候选，这里设回基线
out="$(run retire 9.9.6-beta.1 --apply --force 2>&1)"; rc=$?
rc_is "$rc" 0 '--force 放行基线'
[ ! -d "$B/dsh/ck-b" ] && ok '基线检出已退役' || bad '基线没退役'
has "$(cat "$B/.dsh-suite/state/journal.log")" '退役回退基线' '流水写明是 --force 放行的基线'

echo '--- 9) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(snap_real)" ] && ok '真机 trash/state 未变' || bad '真机被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
