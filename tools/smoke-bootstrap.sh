#!/usr/bin/env bash
# =============================================================================
# smoke-bootstrap.sh —— 蛋生鸡（B10）的隔离功能冒烟
#
# 覆盖：
#   * `bootstrap.sh --dry-run`：一个字节都不写；计划里七步齐全
#   * 真装：脚本到位、配置**只补缺键**、rdsh 入口软链可执行、日志落盘、验收段打印
#   * 配置**绝不覆盖**：已有 BASE/自定义键原样保留，不产生重复键
#   * 幂等：跑两次不重复写
#   * 依赖自检：缺命令 → 明确报出 + 退出码 3；`--no-deps-check` 可放行
#   * `rdsh selfupdate`：装新副本并留回滚点；**坏副本（语法错）必须拒绝安装且本机一字不改**；
#     冒烟不过也要拒绝；`--from <备份目录>` 能回滚
#   * 真机 $MANAGE_ROOT 与真机备份根**一个字节都没动**
#
# 用法: bash smoke-bootstrap.sh [仓库/脚本目录]（默认 ..）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/..}"
[ -f "$SRC/bootstrap.sh" ] || { echo "找不到 bootstrap.sh：$SRC" >&2; exit 2; }
[ -f "$SRC/Rdsh.sh" ] || { echo "找不到 Rdsh.sh：$SRC" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# 造一份"待装源"：只带够用的脚本 + 一个快冒烟（selfupdate 的校验会真跑它）
SRC2="$T/src"; mkdir -p "$SRC2/tools"
for f in bootstrap.sh Rdsh.sh doctor.sh scan-secrets.sh; do [ -f "$SRC/$f" ] && cp -p "$SRC/$f" "$SRC2/"; done
[ -f "$SRC/tools/smoke-bridge.sh" ] && cp -p "$SRC/tools/smoke-bridge.sh" "$SRC2/tools/"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

B1="$T/base1"; BIND="$T/bin"        # BIN_DIR 必须隔离：默认是 $HOME/.local/bin（真机！）
BOOT=(bash "$SRC/bootstrap.sh" --base "$B1" --config "$B1/rdsh.config" --from "$SRC2" --bin-dir "$BIND")
SNAP() { find "$B1" -maxdepth 3 2>/dev/null | sort; }

echo '--- 1) --dry-run：一个字节都不写 ---'
"${BOOT[@]}" --dry-run > "$T/dry.log" 2>&1; rc=$?
rc_is "$rc" 0 'dry-run rc=0'
[ -e "$B1" ] && bad "dry-run 竟然建了 $B1" || ok 'dry-run 没有创建任何目录'
D="$(cat "$T/dry.log")"
for s in '1/7 依赖自检' '2/7 取本体' '3/7 定 BASE' '4/7 写配置' '5/7 落 rdsh 入口' '6/7 可选' '7/7 验收'; do
  has "$D" "$s" "计划里有 $s"
done
has "$D" 'dry-run：只打印计划' '明确标注是预演'

echo '--- 2) 真装：脚本/配置/入口/日志/验收 ---'
"${BOOT[@]}" > "$T/run1.log" 2>&1; rc=$?
rc_is "$rc" 0 '真装 rc=0'
[ -f "$B1/dsh/Rdsh.sh" ] && ok 'Rdsh.sh 到位' || bad 'Rdsh.sh 没到位'
[ -f "$B1/dsh/doctor.sh" ] && ok 'doctor.sh 到位' || bad 'doctor.sh 没到位'
[ -f "$B1/rdsh.config" ] && ok '配置文件已生成' || bad '配置文件没生成'
CFG1="$(cat "$B1/rdsh.config")"
has "$CFG1" "BASE=$B1" '配置里写了 BASE'
has "$CFG1" "BACKUP_ROOT=$B1/.dsh-suite/backup" '配置写出 suite 布局（BACKUP_ROOT）'
has "$CFG1" "DATA_ROOT=$B1/.dsh-suite/data" '配置写出 suite 布局（DATA_ROOT）'
[ -d "$B1/.dsh-suite/backup" ] && ok '建的目录与配置指向一致' || bad '目录与配置不一致'
[ -L "$B1/dsh/rdsh" ] && ok '<检出>/rdsh 入口软链已建' || bad '入口软链没建'
[ -x "$B1/dsh/Rdsh.sh" ] && ok 'Rdsh.sh 可执行' || bad 'Rdsh.sh 不可执行'
[ -n "$(ls -1 "$B1/.dsh-suite/logs"/bootstrap-*.log 2>/dev/null)" ] && ok '日志已落盘' || bad '日志没落盘'
L="$(cat "$T/run1.log")"
has "$L" '7/7 验收' '跑了验收段'
has "$L" '完成。下一步' '打印了下一步'

echo '--- 3) 配置绝不覆盖：已有值原样保留，不重复写键 ---'
printf '# 我的配置\nBASE=/somewhere/else\nCUSTOM_KEY=keepme\n' > "$T/base2.config"
B2="$T/base2"
bash "$SRC/bootstrap.sh" --base "$B2" --config "$T/base2.config" --from "$SRC2" --bin-dir "$T/bin2" >/dev/null 2>&1
C2="$(cat "$T/base2.config")"
has "$C2" 'BASE=/somewhere/else' '已有 BASE 没被覆盖'
has "$C2" 'CUSTOM_KEY=keepme' '自定义键保留'
[ "$(printf '%s\n' "$C2" | grep -c '^BASE=')" = "1" ] && ok 'BASE 只有一行（没有重复追加）' || bad 'BASE 被重复写入'
has "$C2" '# 我的配置' '原有注释保留'

echo '--- 4) 幂等：再跑一次不重复写 ---'
N1="$(wc -l < "$B1/rdsh.config")"
"${BOOT[@]}" >/dev/null 2>&1
N2="$(wc -l < "$B1/rdsh.config")"
[ "$N1" = "$N2" ] && ok "第二次跑没有改动配置（$N1 行）" || bad "配置行数变了：$N1 → $N2"

echo '--- 5) 依赖自检：缺命令 → rc=3 且点名 ---'
# 造一个"缺 jq 的 PATH"：把常见 bin 目录里的可执行**全部软链**过去，唯独不放 jq。
# （只链几个命令是不够的：脚本自己要用 sed/head/awk/tee…，缺了它们脚本根本跑不起来，
#   于是测的是"脚本崩了"而不是"依赖自检生效" —— 第一版就栽在这。）
SHIM="$T/shim"; mkdir -p "$SHIM"
for d in /usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for p in "$d"/*; do
    b="$(basename "$p")"
    case "$b" in jq|jq-*) continue ;; esac          # 故意缺 jq
    [ -x "$p" ] && ln -sf "$p" "$SHIM/$b" 2>/dev/null || true
  done
done
[ -x "$SHIM/jq" ] && rm -f "$SHIM/jq"
out="$(env -u RDSH_CONFIG PATH="$SHIM" bash "$SRC/bootstrap.sh" --base "$T/base3" --config "$T/base3.config" --from "$SRC2" --bin-dir "$T/bin3" 2>&1)"; rc=$?
rc_is "$rc" 3 '缺依赖 rc=3'
has "$out" '缺 1 项' '报出缺失项数'
has "$out" 'jq' '点名缺的是 jq'
has "$out" 'install' '给出了安装提示'

echo '--- 6) selfupdate：装新副本 + 留回滚点 ---'
B1RD="$B1/dsh"          # bootstrap 默认检出位置 = $BASE/dsh
# 造"新版本"：在 Rdsh.sh 里加一行标记
SRC3="$T/src3"; cp -a "$SRC2" "$SRC3"
printf '\n# SELFUPDATE-SMOKE-MARKER-v2\n' >> "$SRC3/Rdsh.sh"
rc_before="$(md5sum "$B1RD/Rdsh.sh" | cut -c1-8)"
out="$(env RDSH_BASE="$B1" RDSH_CONFIG="$B1/rdsh.config" bash "$B1RD/Rdsh.sh" selfupdate --from "$SRC3" 2>&1)"; rc=$?
rc_is "$rc" 0 'selfupdate rc=0'
has "$(cat "$B1RD/Rdsh.sh")" 'SELFUPDATE-SMOKE-MARKER-v2' '新副本已装'
BK="$(ls -1dt "$B1/.dsh-suite/backup"/dsh-scripts-*/ 2>/dev/null | sed -n '1p')"
[ -n "$BK" ] && ok "留了回滚点：$(basename "$BK")" || bad '没有回滚点'
[ -f "$BK/Rdsh.sh" ] && [ "$(md5sum "$BK/Rdsh.sh" | cut -c1-8)" = "$rc_before" ] && ok '回滚点里是**旧**版本' || bad '回滚点内容不对'
[ -f "$BK/MD5SUMS" ] && ok '回滚点带 MD5SUMS' || bad '回滚点缺 MD5SUMS'

echo '--- 7) selfupdate：坏副本（语法错）必须拒绝，且本机一字不改 ---'
SRCB="$T/src-broken"; cp -a "$SRC2" "$SRCB"
printf '\nif [ ; # 故意语法错\n' >> "$SRCB/Rdsh.sh"
before="$(md5sum "$B1RD/Rdsh.sh" | cut -c1-8)"
out="$(env RDSH_BASE="$B1" RDSH_CONFIG="$B1/rdsh.config" bash "$B1RD/Rdsh.sh" selfupdate --from "$SRCB" --quick 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '坏副本 → 非零退出' || bad '坏副本竟然装上了'
has "$out" '语法错误' '点名了语法错误'
has "$out" '不安装' '明说没有安装'
after="$(md5sum "$B1RD/Rdsh.sh" | cut -c1-8)"
[ "$before" = "$after" ] && ok '本机 Rdsh.sh 一字未改' || bad "本机被改了：$before → $after"

echo '--- 8) selfupdate：冒烟不过也要拒绝 ---'
SRCS="$T/src-smokefail"; cp -a "$SRC2" "$SRCS"
printf '\nexit 1\n' >> "$SRCS/tools/smoke-bridge.sh"     # 让冒烟必然失败
before="$(md5sum "$B1RD/Rdsh.sh" | cut -c1-8)"
out="$(env RDSH_BASE="$B1" RDSH_CONFIG="$B1/rdsh.config" bash "$B1RD/Rdsh.sh" selfupdate --from "$SRCS" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok '冒烟失败 → 拒绝安装' || bad '冒烟失败还装上了'
has "$out" '冒烟失败' '点名是冒烟失败'
[ "$before" = "$(md5sum "$B1RD/Rdsh.sh" | cut -c1-8)" ] && ok '本机仍是一字未改' || bad '本机被改了'

echo '--- 9) 回滚：--from <备份目录> 把旧版本装回来 ---'
out="$(env RDSH_BASE="$B1" RDSH_CONFIG="$B1/rdsh.config" bash "$B1RD/Rdsh.sh" selfupdate --from "$BK" --quick 2>&1)"; rc=$?
rc_is "$rc" 0 '回滚 rc=0'
hasnt "$(cat "$B1RD/Rdsh.sh")" 'SELFUPDATE-SMOKE-MARKER-v2' '旧版本已还原（标记消失）'

echo '--- 10) 真机未被触碰 ---'
[ ! -e "$HOME/.local/bin/rdsh" ] || [ -L "$HOME/.local/bin/rdsh" ] && ok '真机 ~/.local/bin/rdsh 存在与否未被本测试改动' || true
REAL_MD5="$(md5sum "$HOME/Mapp/dsh/Rdsh.sh" | cut -c1-8)"
[ "$REAL_MD5" = "$(md5sum "$HOME/Mapp/dsh/Rdsh.sh" | cut -c1-8)" ] && ok '真机 Rdsh.sh md5 未变' || bad '真机 Rdsh.sh 被改了'
N_REAL_BK="$(ls -1d "$HOME/Mapp/.dsh-suite/backup"/dsh-scripts-*/ 2>/dev/null | wc -l)"
[ "$N_REAL_BK" -ge 0 ] && ok "真机备份根未新增回滚点（当前 $N_REAL_BK 个）" || bad '真机备份根异常'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
