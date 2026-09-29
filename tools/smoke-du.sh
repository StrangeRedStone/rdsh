#!/usr/bin/env bash
# =============================================================================
# smoke-du.sh —— `rdsh du`（衍生物账本）与 `rdsh trash`（回收站）的隔离功能冒烟
#
# 覆盖：
#   * 回收站默认落在 **BASE 下**（同一文件系统，不是 /tmp）—— 跨设备 mv 会退化成复制+删除
#   * `debug rm` 走多来源回收条目（home + 清单文件），条目带清单与原路径
#   * `trash restore` 按清单还原；目标已存在则**跳过不覆盖**
#   * `du` 只列不删；`--purge` 无 `--yes` 只预览；**年龄守卫**（<7 天要 --force）
#   * `--purge backup` 不给 `--older-than` 必须拒绝（备份是资产）
#   * `--purge debug` 必须拒绝并指向 `rdsh debug rm`
#   * `du --json` 可被 json.load 解析
#   * 真机回收站/备份目录逐字节不变
#
# 隔离要点同 smoke-state.sh：脚本副本进临时 BASE + RDSH_CONFIG 指走 + 真机资产快照。
# 用法: bash smoke-du.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }

# 前置校验（同 smoke-state.sh）：没有 du/trash 子命令就快速失败，别被带进 start 路径挂死
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh du' || ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh trash'; then
  echo "被测脚本里没有 \`rdsh du\`/\`rdsh trash\`（旧版本？先 publish --stage）：$SRC" >&2
  exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh-backup" "$B/.dsh-suite/debug"
cp -p "$SRC" "$B/dsh/Rdsh.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

# 假检出（版本号避开真机在跑版本）
mkdir -p "$B/dsh/ck-a/node_modules" "$B/.dsh/9.9.7-rc.2"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$B/dsh/ck-a/package.json"
printf x > "$B/dsh/ck-a/.installed"

# 一个调试环境（清单 + home），用来触发 debug rm 的多来源回收
mkdir -p "$B/.dsh-suite/debug/d1"
printf 'x\n' > "$B/.dsh-suite/debug/d1/settings.yaml"
{
  printf 'id=d1\nver=9.9.7-rc.2\ndir=%s\ndir2=\n' "$B/dsh/ck-a"
  printf 'home=%s\ncreated=2026-09-29T00:00:00+08:00\nassets=0\ncreds=none\n' "$B/.dsh-suite/debug/d1"
} > "$B/.dsh-suite/debug/d1.env"

# 假 fetch 临时残留 + 备份快照目录
mkdir -p "$B/dsh/.fetch-9.9.9-20260101-000000"; printf 'x\n' > "$B/dsh/.fetch-9.9.9-20260101-000000/a"
touch -d '60 days ago' "$B/dsh/.fetch-9.9.9-20260101-000000"
mkdir -p "$B/.dsh-backup/migrate-old-20260101"; printf 'x\n' > "$B/.dsh-backup/migrate-old-20260101/a"
touch -d '90 days ago' "$B/.dsh-backup/migrate-old-20260101"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

TR="$B/.dsh-suite/trash"
REAL_TRASH="$HOME/Mapp/.dsh-suite/trash"; REAL_BACKUP="$HOME/Mapp/.dsh-suite/backup"
snap_real() { find "$REAL_TRASH" "$REAL_BACKUP" -maxdepth 1 2>/dev/null | sort | while IFS= read -r f; do
                printf '%s %s\n' "$f" "$(stat -c '%s %Y' "$f" 2>/dev/null)"; done; }
REAL_BEFORE="$(snap_real)"

echo '--- 1) debug rm 走带清单的回收条目（默认落 BASE 下） ---'
out="$(run debug rm d1 2>&1)"; rc=$?
rc_is "$rc" 0 'debug rm 退出码 0'
[ -d "$TR" ] && ok "回收站建在 BASE 下（$TR）" || bad '回收站没有建在 BASE 下'
[ ! -d "$B/.dsh-suite/debug/d1" ] && ok '调试 home 已挪走' || bad '调试 home 还在原地'
ENTRY="$(ls -1d "$TR"/*/ 2>/dev/null | sed -n '1p')"
[ -n "$ENTRY" ] && ok "生成了回收条目：$(basename "$ENTRY")" || bad '没有回收条目'
[ -f "$ENTRY/.rdsh-trash.kv" ] && ok '条目带清单 .rdsh-trash.kv' || bad '条目缺清单'
has "$(cat "$ENTRY/.rdsh-trash.kv")" "orig.1=" '清单记下原路径'
has "$(cat "$ENTRY/.rdsh-trash.kv")" "restore.1=mv " '清单带还原命令'
has "$out" 'rdsh trash restore' '输出里给了还原命令'

echo '--- 2) trash ls ---'
out="$(run trash ls 2>&1)"
has "$out" '回收站' 'ls 有回收站标题'
has "$out" "$(basename "$ENTRY")" 'ls 列出条目名'
has "$out" 'd1' 'ls 显示原路径'

echo '--- 3) --purge trash 无 --yes 只预览（不删） ---'
out="$(run du --purge trash 2>&1)"; rc=$?
rc_is "$rc" 0 '预览退出码 0'
has "$out" '预览模式' '明确说只预览'
[ -d "$ENTRY" ] && ok '预览没有删任何东西' || bad '预览阶段就删了！'

echo '--- 4) 年龄守卫：新条目要 --force ---'
out="$(run du --purge trash --yes 2>&1)"
has "$out" '要删加 --force' '新条目被年龄守卫拦下'
[ -d "$ENTRY" ] && ok '条目仍在（未被删）' || bad '年龄守卫失效，条目被删'

echo '--- 5) trash restore 还原 ---'
out="$(run trash restore --last 2>&1)"; rc=$?
rc_is "$rc" 0 'restore 退出码 0'
[ -d "$B/.dsh-suite/debug/d1" ] && ok '调试 home 已还原到原位' || bad 'home 未还原'
[ -f "$B/.dsh-suite/debug/d1.env" ] && ok '清单文件已还原到原位' || bad '清单文件未还原'
has "$(cat "$ENTRY/.rdsh-trash.kv")" 'restored_at=' '条目留在原地并记下还原时间（痕迹）'

echo '--- 6) restore 遇到已存在的目标：跳过不覆盖 ---'
printf 'x\n' > "$B/.dsh-suite/debug/d1/marker-resident"
run debug rm d1 >/dev/null 2>&1
# 目标位置放一个"用户的新东西"，restore 不该覆盖它
mkdir -p "$B/.dsh-suite/debug/d1"; printf 'resident\n' > "$B/.dsh-suite/debug/d1/keep"
out="$(run trash restore --last 2>&1)"
has "$out" '跳过' '已存在的目标被跳过'
has "$(cat "$B/.dsh-suite/debug/d1/keep" 2>/dev/null)" 'resident' '已存在的内容没有被覆盖'

echo '--- 7) --purge backup 不给 --older-than 必须拒绝 ---'
out="$(run du --purge backup --yes 2>&1)"; rc=$?
rc_is "$rc" 1 '拒绝时退出码 1'
has "$out" '必须给 --older-than' '明确拒绝裸删备份'
[ -d "$B/.dsh-backup/migrate-old-20260101" ] && ok '备份目录未被删' || bad '备份被删了！'

echo '--- 8) --purge debug 必须指向 debug rm ---'
out="$(run du --purge debug 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '拒绝 du --purge debug' || bad 'du --purge debug 竟然通过'
has "$out" 'rdsh debug rm' '指向正确的命令'

echo '--- 9) --purge fetch --older-than 0d --yes 真删 ---'
[ -d "$B/dsh/.fetch-9.9.9-20260101-000000" ] && ok 'fetch 残留存在（先决条件）' || bad 'fetch 残留不存在'
out="$(run du --purge fetch --older-than 0d --yes 2>&1)"
has "$out" '已删除' '真删了 fetch 残留'
[ ! -d "$B/dsh/.fetch-9.9.9-20260101-000000" ] && ok 'fetch 残留已消失' || bad 'fetch 残留还在'

echo '--- 10) --purge trash --force --yes 真删（含新条目） ---'
run du --purge trash --force --yes >/dev/null 2>&1
LEFT="$(ls -1d "$TR"/*/ 2>/dev/null | wc -l)"
[ "$LEFT" = "0" ] && ok '回收条目已清空' || bad "还剩 $LEFT 个条目"

echo '--- 11) --json 可解析 ---'
run du --json > "$T/du.json" 2>/dev/null
if python3 -c "import json;d=json.load(open('$T/du.json'));assert 'trash' in d and 'backup' in d and 'fetch_tmp' in d" 2>/dev/null; then
  ok '--json 可被 json.load 解析且含各类别'
else
  bad '--json 不可解析'
fi

echo '--- 12) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(snap_real)" ] && ok '真机回收站/备份目录未变' || bad '真机回收站/备份目录被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
