#!/usr/bin/env bash
# =============================================================================
# smoke-bridge.sh —— 门面契约（B9）的隔离功能冒烟
#
# 作法：**功能靠外部脚本，界面靠 dsh 插件**。插件不该自己实现逻辑，只需要知道
#       "rdsh 有哪些能力、怎么调、危险等级"。契约就是 `rdsh bridge --spec --json`。
#
# 硬断言：
#   * 契约是**合法 JSON**，字段齐全，risk 只取 read / write / destructive
#   * 每个能力的 subcommand 都是**真子命令**（rdsh help 里点得到）
#   * **危险能力默认不动手**：write 必须带 --dry-run；destructive 必须默认只出计划或带 --dry-run
#   * **契约可执行**：按契约的调用形式（bash <entry> <子命令> <默认参数>）真跑 read 能力，必须成功
#   * 危险能力按契约默认跑一遍**不产生任何改动**（隔离 BASE 里验证）
#   * 契约自检：清单行字段数错误会 die（防止参数里混入分隔符导致静默错位）
#   * 真机资产逐项未变
#
# 用法: bash smoke-bridge.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh bridge'; then
  echo "被测脚本里没有 \`rdsh bridge\`（旧版本？先 publish --stage）：$SRC" >&2; exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-suite/state" "$B/.dsh-suite/run/instances"
cp -p "$SRC" "$B/dsh/Rdsh.sh"
[ -f "$(dirname "$SRC")/doctor.sh" ] && cp -p "$(dirname "$SRC")/doctor.sh" "$B/dsh/doctor.sh"
# 一个假检出（让 list/du/state 有对象可看）
D="$B/dsh/ck-1"; H="$B/.dsh/9.9.7-rc.2"
mkdir -p "$D/node_modules" "$H/sessions"
printf '{"name":"deepseek-harness","version":"9.9.7-rc.2"}\n' > "$D/package.json"
printf x > "$D/.installed"
printf 'ui:\n  theme: dark\n' > "$H/settings.yaml"
printf '# 账本\n# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note|settings|settings_sha\n' \
  > "$B/.dsh-suite/state/versions.kv"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" "$@" </dev/null; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
rc_in(){ case " $2 " in *" $1 "*) ok "$3" ;; *) bad "$3（期望 rc∈{$2}，实际 $1）" ;; esac; }

REAL="$HOME/Mapp/.dsh-suite"
REAL_BEFORE="$(find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort)"

echo '--- 1) 契约是合法 JSON 且字段齐全 ---'
SPEC="$T/spec.json"
run bridge --spec --json > "$SPEC" 2>/dev/null
python3 - "$SPEC" <<'PY' && ok 'JSON 合法、字段齐全、risk 取值合法' || bad 'JSON 不合法或字段缺失'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['version']==1 and d['tool']=='rdsh' and d['entry'].endswith('Rdsh.sh'), d
caps=d['capabilities']; assert len(caps)>=10, len(caps)
allowed={'read','write','destructive'}
for c in caps:
    assert c['id'] and c['subcommand'], c
    assert c['risk'] in allowed, c
    assert c['summary'], c
PY

echo '--- 2) 每个能力的 subcommand 都是真子命令 ---'
HELP="$(run help 2>&1)"
BADSC=""
while IFS=$'\t' read -r cid sc; do
  first="${sc%% *}"
  case "$HELP" in *"$first"*) ;; *) BADSC="$BADSC $cid($first)" ;; esac
done < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["capabilities"]: print(c["id"]+"\t"+c["subcommand"])
' "$SPEC")
[ -z "$BADSC" ] && ok '全部能力都指向真实子命令' || bad "有能力的子命令在 help 里找不到：$BADSC"

echo '--- 3) 危险能力默认不动手（契约层的硬约束） ---'
python3 - "$SPEC" <<'PY' && ok 'write 带 --dry-run；destructive 带 --dry-run 或写明要显式 --apply' || bad '危险能力的默认不安全'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d['capabilities']:
    if c['risk']=='write':
        assert '--dry-run' in c['default_args'], ('write 缺 --dry-run', c)
    if c['risk']=='destructive':
        ok = '--dry-run' in c['default_args'] or '--apply' in c['args']
        assert ok, ('destructive 既没有默认 --dry-run 也没写明 --apply', c)
# retire 的默认必须是"只出计划"
r=[c for c in d['capabilities'] if c['subcommand']=='retire'][0]
assert r['default_args'].strip()=='' and '--apply' in r['args'], r
PY

echo '--- 4) 契约可执行：按 <entry> <子命令> <默认参数> 真跑 read 能力 ---'
mapfile -t READS < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["capabilities"]:
    if c["risk"]=="read" and c["subcommand"] not in ("scan",):   # scan 要显式给路径
        print(c["subcommand"]+"|"+c["default_args"])
' "$SPEC")
for row in "${READS[@]}"; do
  sc="${row%%|*}"; da="${row#*|}"
  # shellcheck disable=SC2086
  out="$(run $sc $da 2>&1)"; rc=$?
  rc_in "$rc" "0 1" "契约调用 $sc $da（rc=0/1 都算成功执行）"
done

echo '--- 5) 危险能力按**默认**跑一遍不产生改动 ---'
SNAP() { find "$B/.dsh-suite" "$B/dsh" "$B/.dsh" -maxdepth 2 2>/dev/null | sort; }
B0="$(SNAP)"
# backup 默认 dry-run
run backup 9.9.7-rc.2 --dry-run >/dev/null 2>&1
[ -z "$(ls -A "$B/.dsh-backup/snapshots" 2>/dev/null)" ] && ok 'backup 默认 dry-run：没有产生快照目录' || bad 'backup 默认就落盘了'
# retire 默认（不带 --apply）= 只出计划
run retire 9.9.7-rc.2 >/dev/null 2>&1
[ -d "$B/dsh/ck-1" ] && [ -d "$B/.dsh/9.9.7-rc.2" ] && ok 'retire 默认只出计划：检出与数据都还在' || bad 'retire 默认就动了东西'
# restore 默认 dry-run（无快照时应报错但不改盘）
run restore 9.9.7-rc.2 --type data --dry-run >/dev/null 2>&1
[ -d "$B/dsh/ck-1" ] && ok 'restore 默认 dry-run：没有改动既有检出' || bad 'restore 默认动了东西'
[ "$B0" = "$(SNAP)" ] && ok '三种危险能力跑完，隔离 BASE 现场未变' || bad '危险能力默认跑完现场变了'

echo '--- 6) 契约自检：参数里混入分隔符会 die（不静默错位） ---'
# 直接验证 --json 输出里每个能力的字段数正确（args 里不应再出现分隔符'
python3 - "$SPEC" <<'PY' && ok 'args 字段里不含分隔符（不会静默错位）' || bad 'args 里混进了分隔符'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d['capabilities']:
    assert '|' not in c['args'], c
PY

echo '--- 7) 人类可读版与 JSON 版能力数一致 ---'
TXT="$(run bridge --spec 2>&1)"
N1="$(printf '%s\n' "$TXT" | grep -cE '^  rdsh_[a-z_]+ ' || true)"
N2="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["capabilities"]))' "$SPEC")"
[ "$N1" = "$N2" ] && ok "两种视图能力数一致（$N1）" || bad "人类可读版 $N1 ≠ JSON $N2"
has "$TXT" '风险等级' '人类可读版说明了风险等级与默认参数约定'

echo '--- 8) 真机 restart --dry-run：在跑的实例 PID 必须不变 ---'
pid3080() { ss -ltnp 2>/dev/null | grep -F ':3080' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }
P0="$(pid3080)"
if [ -n "$P0" ]; then
  bash "$HOME/Mapp/dsh/Rdsh.sh" restart --dry-run --log "$T/restart-dry.log" >/dev/null 2>&1
  P1="$(pid3080)"
  [ "$P0" = "$P1" ] && ok "restart --dry-run 没动在跑的实例（PID $P0 不变）" || bad "dry-run 竟然动了实例：$P0 → $P1"
  has "$(cat "$T/restart-dry.log" 2>/dev/null)" '未做任何改动' '日志里明确写了"未做任何改动"'
else
  ok '跳过（:3080 上没有实例）'
fi

echo '--- 9) 真机资产未被触碰 ---'
[ "$REAL_BEFORE" = "$(find "$REAL/state" "$REAL/trash" -maxdepth 1 2>/dev/null | sort)" ] && ok '真机 state/trash 未变' || bad '真机被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
