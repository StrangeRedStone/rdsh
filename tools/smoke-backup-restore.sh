#!/usr/bin/env bash
# =============================================================================
# smoke-backup-restore.sh —— `rdsh backup`（增量快照）与 `rdsh restore` 的隔离功能冒烟
#
# 硬断言：
#   * 第二份快照对未变化的文件是**硬链接**（比 inode，不是比"看着一样"）
#   * `--verify` 逐文件核查，改坏一个文件能被查出来
#   * `--keep N` 超出的快照进**回收站**（不 rm）
#   * restore 覆盖前把既有内容整体挪进回收站；`--diff`/无 `--yes` 不落盘
#   * **凭据默认不恢复**；远端源 + --type data 一律拒绝（隐私）
#   * `--merge` 对记忆三库是**按条目追加**（目标独有的条目必须活着）
#   * 真机 snapshots / state-snapshots / trash 逐项未变
#
# 用法: bash smoke-backup-restore.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh restore'; then
  echo "被测脚本里没有 \`rdsh restore\`/\`rdsh backup --snapshot\`（旧版本？先 publish --stage）：$SRC" >&2
  exit 2
fi
command -v rsync >/dev/null || { echo '本测试需要 rsync' >&2; exit 2; }

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-suite/state"
printf '# 账本\n' > "$B/.dsh-suite/state/versions.kv"; printf '# 流水\n' > "$B/.dsh-suite/state/journal.log"
cp -p "$SRC" "$B/dsh/Rdsh.sh"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

# 假检出 + 数据 home（含会话/凭据，测隐私规则）
mkdir -p "$B/dsh/ck-a/node_modules" "$B/dsh/ck-a/.git/info"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$B/dsh/ck-a/package.json"
printf x > "$B/dsh/ck-a/.installed"
D="$B/.dsh/9.9.7-rc.2"
mkdir -p "$D/sessions" "$D/storages" "$D/profiles"
printf 'session-1\n' > "$D/sessions/s1.json"
printf 'big-payload\n' > "$D/storages/blob.bin"
printf 'settings: 1\n' > "$D/settings.yaml"
printf 'secret: TOPSECRET\n' > "$D/.credentials.yaml"
printf 'workspace\n' > "$D/workspace.json"
mkdir -p "$B/.dsh-shared"

# 假「我的 dsh」本地克隆（用于 --type shared/plugins/config + --merge）
M="$T/mydsh"
mkdir -p "$M/plugins/alpha" "$M/shared" "$M/config" "$M/patches/pset1"
printf '{"name":"alpha"}\n' > "$M/plugins/alpha/package.json"
printf '{"name":"alpha"}\n' > "$M/plugins/alpha/index.js"
printf '# 补丁\n' > "$M/patches/pset1/0001-x.patch"
printf 'BASE=%s\n' "$B" > "$M/config/rdsh.config"
# 记忆三库：源里有 A/B 两条；目标里已有 A 且另有"目标独有"的 C
printf '# lessons\n\n## A 共享条目\n- 内容A\n\n## B 源独有条目\n- 内容B\n' > "$M/shared/lessons.md"
printf '# facts\n\n## F1\n- f\n' > "$M/shared/facts.md"
printf '# backlog\n\n## K1\n- k\n' > "$M/shared/backlog.md"
printf 'my-dsh AGENTS\n' > "$M/shared/AGENTS.md"
printf '# lessons\n\n## A 共享条目\n- 内容A(本机版)\n\n## C 目标独有条目\n- 内容C\n' > "$B/.dsh-shared/lessons.md"
printf 'local AGENTS\n' > "$B/.dsh-shared/AGENTS.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

REAL="$HOME/Mapp/.dsh-suite"
snap_real() { find "$REAL/backup/snapshots" "$REAL/backup/state-snapshots" "$REAL/trash" -maxdepth 1 2>/dev/null | sort; }
REAL_BEFORE="$(snap_real)"

echo '--- 1) 首份增量快照 + --verify ---'
out="$(run backup 9.9.7-rc.2 --snapshot --verify 2>&1)"; rc=$?
rc_is "$rc" 0 'backup --snapshot --verify 退出码 0'
has "$out" '快照完成' '打印快照完成'
has "$out" '[ok]' '逐文件核查通过'
SNAP1="$(ls -1dt "$B/.dsh-backup/snapshots/9.9.7-rc.2"/*/ 2>/dev/null | sed -n '1p')"
[ -f "$SNAP1/MANIFEST.kv" ] && ok '快照带 MANIFEST.kv' || bad '缺 MANIFEST.kv'
has "$(cat "$SNAP1/MANIFEST.kv")" 'mode=snapshot' 'MANIFEST 记模式'
has "$(cat "$SNAP1/MANIFEST.kv")" 'version=9.9.7-rc.2' 'MANIFEST 记版本'
[ -f "$SNAP1/sessions/s1.json" ] && ok '会话文件进了快照（本地快照含会话）' || bad '会话文件没进快照'

echo '--- 2) 改一个文件后第二份快照：未变文件应为硬链接 ---'
printf 'changed\n' > "$D/storages/blob.bin"
printf 'new-file\n' > "$D/sessions/s2.json"
sleep 1
run backup 9.9.7-rc.2 --snapshot >/dev/null 2>&1
SNAP2="$(ls -1dt "$B/.dsh-backup/snapshots/9.9.7-rc.2"/*/ 2>/dev/null | sed -n '1p')"
[ "$SNAP1" != "$SNAP2" ] && ok '生成了第二份快照' || bad '第二份快照没生成'
has "$(cat "$SNAP2/MANIFEST.kv")" "link_dest=$SNAP1" 'MANIFEST 记下硬链接基准'
i1="$(stat -c %i "$SNAP1/settings.yaml" 2>/dev/null)"; i2="$(stat -c %i "$SNAP2/settings.yaml" 2>/dev/null)"
[ -n "$i1" ] && [ "$i1" = "$i2" ] && ok "未变化的文件是硬链接（inode $i1）" || bad "未变化文件不是硬链接（$i1 vs $i2）"
[ "$(stat -c %i "$SNAP1/storages/blob.bin")" != "$(stat -c %i "$SNAP2/storages/blob.bin")" ] && ok '改过的文件是独立副本' || bad '改过的文件仍是硬链接'
# 注意：du 对硬链接在**同一次遍历**里只算一次，所以单看 SNAP2 的 du 会等于其"表观大小"。
# 真正的共享证据：两份快照合计的实际占用 < 各自表观大小之和。
b1="$(du -sk "$SNAP1" | cut -f1)"; b2="$(du -sk "$SNAP2" | cut -f1)"
tot="$(du -sk "$B/.dsh-backup/snapshots/9.9.7-rc.2" | cut -f1)"
[ "$tot" -lt "$((b1 + b2))" ] && ok "两份合计占用 $tot KB < 各自之和 $((b1 + b2)) KB（硬链接省了空间）" \
  || bad "没有省空间（合计 $tot KB，两份表观和 $((b1 + b2)) KB）"

echo '--- 3) --verify 能查出被改坏的文件 ---'
# 篡改方式很重要：硬链接快照共享 inode（SNAP2 的未变文件是 SNAP1 的硬链接），
# "就地写"会连带改坏更早的快照 → 这里用**替换**（新文件 + mv）打破链接，只影响 SNAP2
printf 'tampered\n' > "$T/tampered.json"
mv -f "$T/tampered.json" "$SNAP2/workspace.json"
out="$(run backup --verify "$SNAP2" 2>&1)"; rc=$?
has "$out" '定稿后被改动过' '点名"快照定稿后被改动"'
[ "$rc" != 0 ] && ok '被就地改动时退出码非 0' || bad '被改坏却报通过'
out="$(run backup --verify "$SNAP1" 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "VERIFY1-DBG SNAP1=$SNAP1"; printf '%s\n' "$out" | sed 's/^/      /'; ls -la "$SNAP1" | head -6; find "$SNAP1" -type f ! -name MANIFEST.kv -newer "$SNAP1/MANIFEST.kv" | sed 's/^/      NEW: /'; }
rc_is "$rc" 0 '未被改动的快照核查通过' 

echo '--- 4) --keep 1：超出的快照进回收站（不 rm） ---'
run backup 9.9.7-rc.2 --snapshot --keep 1 >/dev/null 2>&1
LEFT="$(ls -1d "$B/.dsh-backup/snapshots/9.9.7-rc.2"/*/ 2>/dev/null | wc -l)"
[ "$LEFT" = "1" ] && ok '只剩 1 份快照' || bad "还剩 $LEFT 份"
TMOVED="$(ls -1d "$B/.dsh-suite/trash"/*/ 2>/dev/null | wc -l)"
[ "$TMOVED" -ge 1 ] && ok "被裁掉的快照进了回收站（$TMOVED 个条目）" || bad '裁掉的快照没进回收站'
TRASH_DUMP="$(cat "$B/.dsh-suite/trash"/*/.rdsh-trash.kv 2>/dev/null)"
has "$TRASH_DUMP" 'orig.1=' '回收条目带原路径'

echo '--- 5) state 快照 ---'
run backup --state >/dev/null 2>&1
[ -d "$B/.dsh-backup/state-snapshots" ] && [ "$(ls -1d "$B/.dsh-backup/state-snapshots"/*/ 2>/dev/null | wc -l)" -ge 1 ] \
  && ok '状态账本快照已生成' || bad '状态账本快照没生成'

echo '--- 6) restore --diff 与无 --yes 都不落盘 ---'
SNAPL="$(ls -1dt "$B/.dsh-backup/snapshots/9.9.7-rc.2"/*/ | sed -n '1p')"
printf 'user-wrote-this\n' > "$D/workspace.json"
before="$(cat "$D/workspace.json")"
out="$(run restore --type data 9.9.7-rc.2 --diff 2>&1)"; rc=$?
rc_is "$rc" 0 '--diff 退出码 0'
has "$out" '差异' 'diff 报出差异'
out="$(run restore --type data 9.9.7-rc.2 2>&1)"
has "$out" '预览模式' '无 --yes 时只预览'
[ "$(cat "$D/workspace.json")" = "$before" ] && ok '预览没有改动目标' || bad '预览就动了目标'

echo '--- 7) restore --type data --yes（凭据默认跳过） ---'
rm -f "$D/.credentials.yaml"
out="$(run restore --type data 9.9.7-rc.2 --yes --no-doctor 2>&1)"; rc=$?
rc_is "$rc" 0 'restore 退出码 0'
has "$out" '已恢复' '打印已恢复'
[ "$(cat "$D/workspace.json")" = 'workspace' ] && ok '目标已回到快照内容' || bad "目标内容不对：$(cat "$D/workspace.json")"
[ ! -e "$D/.credentials.yaml" ] && ok '凭据默认**没有**恢复（隐私）' || bad '凭据被恢复了'
out="$(run restore --type data 9.9.7-rc.2 --yes --with-creds --no-doctor 2>&1)"
[ -e "$D/.credentials.yaml" ] && ok '--with-creds 时凭据一并恢复' || bad '--with-creds 没恢复凭据'
has "$(cat "$B/.dsh-suite/trash"/*/.rdsh-trash.kv 2>/dev/null)" 'restore-data' '覆盖前的既有数据进了回收站'

echo '--- 8) 远端源 + data/state：一律拒绝 ---'
out="$(run restore --type data 9.9.7-rc.2 --from git:https://example.invalid/x.git 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '远端 + data 被拒绝' || bad '远端 + data 竟然通过'
has "$out" '只从本地源恢复' '给出隐私理由'
out="$(run restore --type state --from https://example.invalid/x.git 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '远端 + state 被拒绝' || bad '远端 + state 竟然通过'

echo '--- 9) --merge：记忆三库按条目追加（目标独有条目必须活着） ---'
out="$(run restore --type shared --from "$M" --merge --yes --no-doctor 2>&1)"; rc=$?
rc_is "$rc" 0 'shared --merge 退出码 0'
L="$B/.dsh-shared/lessons.md"
has "$(cat "$L")" '## B 源独有条目' '源里的新条已被追加'
has "$(cat "$L")" '## C 目标独有条目' '目标独有的条**没有**被抹掉（append-only）'
has "$(cat "$L")" '## A 共享条目' '共有条目还在'
hasnt "$(cat "$L")" '## B 源独有条目\n\n## B 源独有条目' '没有重复追加同一条'
[ "$(cat "$B/.dsh-shared/AGENTS.md")" = 'my-dsh AGENTS' ] && ok '非记忆文件按覆盖语义恢复' || bad 'AGENTS.md 未按源恢复'
[ -f "$B/.dsh-shared/lessons.md.old-copy" ] && ok '覆盖前的旧文件留了副本（可对照）' || bad '没留旧副本'

echo '--- 10) 插件/配置类型 ---'
run restore --type plugins --from "$M" --yes --no-doctor >/dev/null 2>&1
[ -f "$B/dsh-plugins/alpha/index.js" ] && ok '插件权威副本已恢复' || bad '插件没恢复'
run restore --type config --from "$M" --yes --no-doctor >/dev/null 2>&1
[ -f "$B/rdsh-config" ] && ok '配置文件已恢复（文件类目标）' || bad '配置文件没恢复'

echo '--- 11) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(snap_real)" ] && ok '真机 snapshots/state-snapshots/trash 未变' || bad '真机资产被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
