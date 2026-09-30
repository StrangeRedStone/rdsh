#!/usr/bin/env bash
# =============================================================================
# smoke-entry.sh —— 入口链自检（B11：rdsh 不总是健全）的隔离功能冒烟
#
# 覆盖真机 2026-09-30 那类"命令与图标一起消失"的场景：
#   * 入口软链断掉 → 必须 **error** 并给出修复命令
#   * 桌面图标的 Exec 指向不存在的路径 → 必须 **error**
#   * 入口目录不在 PATH → **warn**
#   * `--only entry` 不许 0 对象（维度耦合回归）
#   * 健康夹具 → 不报 error
#   * **真机入口（~/.local/bin/rdsh、<检出>/rdsh、dsh.desktop）测试前后完全一致**
#     —— 这条是 2026-09-30 事故换来的硬约束：绝不为测试动真机入口
#
# 用法: bash smoke-entry.sh [doctor.sh 路径]（默认 ../doctor.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
DOC="${1:-$(dirname "$(readlink -f "$0")")/../doctor.sh}"
[ -f "$DOC" ] || { echo "找不到 doctor.sh: $DOC" >&2; exit 2; }
if ! grep -q '入口链' "$DOC"; then echo "被测 doctor 里没有入口链维度（旧版本？先 publish --stage）" >&2; exit 2; fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-suite/state"
cp -p "$DOC" "$B/dsh/doctor.sh"
[ -f "$(dirname "$DOC")/Rdsh.sh" ] && cp -p "$(dirname "$DOC")/Rdsh.sh" "$B/dsh/Rdsh.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）" ; }

# 真机入口指纹（测试前后必须一致）
REAL_LINK="$HOME/.local/bin/rdsh"; REAL_LINK2="$HOME/Mapp/dsh/rdsh"
REAL_DESK="$HOME/.local/share/applications/dsh.desktop"
real_state() {
  printf 'l1=%s|' "$([ -L "$REAL_LINK" ] && readlink "$REAL_LINK" || { [ -e "$REAL_LINK" ] && echo FILE || echo none; })"
  printf 'l2=%s|' "$([ -L "$REAL_LINK2" ] && readlink "$REAL_LINK2" || { [ -e "$REAL_LINK2" ] && echo FILE || echo none; })"
  printf 'd=%s' "$([ -f "$REAL_DESK" ] && md5sum "$REAL_DESK" | cut -c1-8 || echo none)"
}
REAL_BEFORE="$(real_state)"

# 隔离的入口根
ER="$T/entryroot"; mkdir -p "$ER/.local/bin" "$ER/.local/share/applications"
run_entry() { env -u RDSH_CONFIG RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" \
                RDSH_ENTRY_ROOT="$ER" RDSH_ENTRY_BIN_DIR="$ER/.local/bin" \
                RDSH_ENTRY_DESKTOP="$ER/.local/share/applications/dsh.desktop" \
                bash "$B/dsh/doctor.sh" "$@" </dev/null 2>&1; }

echo '--- 1) 健康入口：不报 error ---'
ln -sfn "$B/dsh/Rdsh.sh" "$ER/.local/bin/rdsh"
printf '[Desktop Entry]\nName=Deepseek Harness\nExec=%s\nType=Application\n' "$ER/.local/bin/rdsh" > "$ER/.local/share/applications/dsh.desktop"
out="$(run_entry --only entry)"; rc=$?
has "$out" '入口：' '检查了规范入口路径'
has "$out" '桌面图标 Exec 可用' '检查了桌面图标 Exec'
has "$out" '降级启动' '打印了降级启动命令（不依赖 rdsh）'
has "$out" '应急启动.md' '指向应急卡'
[ "$rc" != 2 ] && ok "健康入口不报 error（rc=$rc）" || bad '健康入口却报 error'
hasnt "$out" '检查对象总数为 0' '没有触发零对象守卫（--only entry 真的查到了）'

echo '--- 2) 入口软链断掉 → error + 修复命令 ---'
ln -sfn "$T/does-not-exist/Rdsh.sh" "$ER/.local/bin/rdsh"
out="$(run_entry --only entry)"; rc=$?
rc_is "$rc" 2 '断入口 rc=2'
has "$out" '入口不可用' '点名"入口不可用"（断链的 -e/-x 都为假）'
has "$out" 'bootstrap.sh' '给出重装入口的命令'

echo '--- 2.5) 完全没有 rdsh → warn + 重装命令 ---'
rm -f "$ER/.local/bin/rdsh"
out="$(run_entry --only entry)"; rc=$?
has "$out" '入口不存在' '点名"入口不存在"'
has "$out" 'bootstrap.sh' '给出重装入口的命令'
[ "$rc" != 0 ] && ok "缺命令至少是 warn（rc=$rc）" || bad '缺命令却报"没问题"'

echo '--- 3) 桌面图标 Exec 失效 → error ---'
ln -sfn "$B/dsh/Rdsh.sh" "$ER/.local/bin/rdsh"
printf '[Desktop Entry]\nExec=%s\nType=Application\n' "$ER/.local/bin/nonexistent-dsh" > "$ER/.local/share/applications/dsh.desktop"
out="$(run_entry --only entry)"; rc=$?
rc_is "$rc" 2 '坏 Exec rc=2'
has "$out" '桌面图标 Exec 失效' '点名 Exec 失效'
has "$out" 'update-desktop-database' '给出刷图标缓存的命令'

echo '--- 4) <检出>/rdsh 是断链 → warn（不升级为 error） ---'
ln -sfn "$T/nope/Rdsh.sh" "$B/dsh/rdsh"
printf '[Desktop Entry]\nExec=%s\n' "$ER/.local/bin/rdsh" > "$ER/.local/share/applications/dsh.desktop"
out="$(run_entry --only entry)"; rc=$?
has "$out" '是断链' '报出 <检出>/rdsh 断链'
has "$out" "ln -sfn $B/dsh/Rdsh.sh $B/dsh/rdsh" '给出重建该软链的命令'
[ "$rc" != 0 ] && ok "至少是 warn（rc=$rc）" || bad '断链却报"没问题"'
rm -f "$B/dsh/rdsh"

echo '--- 5) 只跑入口维也不会撞零对象守卫 ---'
out="$(run_entry --only entry)"
hasnt "$out" '检查对象总数为 0' '零对象守卫没有误报'
has "$out" '共 ' '汇总里有对象数'

echo '--- 6) 真机入口一字未动 ---'
[ "$REAL_BEFORE" = "$(real_state)" ] && ok "真机入口状态未变（$REAL_BEFORE）" || bad "真机入口被改了：$REAL_BEFORE → $(real_state)"

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
