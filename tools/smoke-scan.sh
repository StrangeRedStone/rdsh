#!/usr/bin/env bash
# =============================================================================
# smoke-scan.sh —— 隐私守卫（scan-secrets.sh）的隔离功能冒烟
#
# 硬断言：
#   * 每条规则的**正样本**都能命中（私钥/令牌/凭据文件/会话数据 → error；赋值密钥/绝对家目录/邮箱/大文件 → warn）
#   * **报告不回显敏感值**（守卫自己把密钥写进日志，是二次泄漏）
#   * 占位/掩码（`token=***`）**不报噪声**
#   * 零扫描报 error；`--staged` 空索引是正常状态（rc=0）
#   * `--strict` 把 warn 提级为 error；`--json` 可解析
#   * **全程只读**：跑测前后被扫目录逐字节一致
#
# 用法: bash smoke-scan.sh [scan-secrets.sh 路径]（默认 ../scan-secrets.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../scan-secrets.sh}"
[ -f "$SRC" ] || { echo "找不到 scan-secrets.sh: $SRC" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
F="$T/fixtures"; mkdir -p "$F/sessions" "$F/plain" "$F/.git" "$F/bin"

# 正样本。**关键**：夹具在源码里不能构成完整密钥形态 —— 否则本文件自己会被守卫判为泄漏
# （自指陷阱）。所以下面一律用片段拼装，运行期才写出完整样本。
FAKE_TOKEN="sk-"'FAKE'"$(printf 'abcdefghij%.0s' 1 2)1234"
PRIV_HEAD="-----BEGIN "'RSA'" PRIVATE KEY-----"
printf -- '%s\nFAKEFAKEFAKE\n-----END %s PRIVATE KEY-----\n' "$PRIV_HEAD" 'RSA' > "$F/privkey.txt"
printf 'DEEPSEEK_API_KEY=%s\n' "$FAKE_TOKEN" > "$F/token.env"
printf 'pass%s: %s\n' 'word' 'SuperSecretValue12345' > "$F/envsec.conf"
printf 'k: v\n' > "$F/.credentials.yaml"
printf 'x\n' > "$F/sessions/s1.json"
printf 'cwd=/%s/%s/Mapp/dsh\n' 'home' 'someone' > "$F/homepath.txt"
printf '联系 %s\n' "foo.bar$(printf '@')gmail.com" > "$F/mail.txt"
printf '# 干净文档\n- 无敏感内容\n' > "$F/plain/ok.md"
printf 'token=***\napi_key=<YOUR_KEY>\nsee example.com docs\n' > "$F/plain/placeholders.md"
printf 'objects\n' > "$F/.git/config"
printf '\x89PNG\r\n\x1a\n' > "$F/bin/pic.png"
printf 'cwd=/%s/%s/notes\n' 'home' 'someone' > "$F/plain/note.log"   # 非跳过扩展名 → 会被扫（含 W2 命中以便断言）

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）"; }

snap_tree() { find "$F" -type f -o -type l | sort | while IFS= read -r f; do
                printf '%s %s\n' "$f" "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"; done; }
BEFORE="$(snap_tree)"

echo '--- 1) 干净文件 ---'
out="$(bash "$SRC" --files "$F/plain/ok.md" 2>&1)"; rc=$?
rc_is "$rc" 0 '干净文件 rc=0'
has "$out" '扫 1 个文件' '报出扫描数量'

echo '--- 2) 占位/掩码不报噪声 ---'
out="$(bash "$SRC" --files "$F/plain/placeholders.md" 2>&1)"; rc=$?
rc_is "$rc" 0 '占位/掩码文件判为干净'
hasnt "$out" 'W1' 'token=*** 不触发赋值型密钥'

echo '--- 3) error 级规则逐条命中 ---'
out="$(bash "$SRC" --files "$F/privkey.txt" 2>&1)"; rc=$?
rc_is "$rc" 2 '私钥 rc=2'; has "$out" 'E1-私钥' '报出 E1-私钥'
out="$(bash "$SRC" --files "$F/token.env" 2>&1)"; rc=$?
rc_is "$rc" 2 '令牌 rc=2'; has "$out" 'E2-令牌' '报出 E2-令牌'
out="$(bash "$SRC" --files "$F/.credentials.yaml" 2>&1)"; rc=$?
rc_is "$rc" 2 '凭据文件 rc=2'; has "$out" 'E3-凭据文件' '报出 E3-凭据文件'
out="$(bash "$SRC" --files "$F/sessions/s1.json" 2>&1)"; rc=$?
rc_is "$rc" 2 '会话数据 rc=2'; has "$out" 'E4-会话数据' '报出 E4-会话数据'

echo '--- 4) 报告不回显敏感值（守卫自己别把密钥写进日志） ---'
out="$(bash "$SRC" --files "$F/token.env" "$F/privkey.txt" 2>&1)"
hasnt "$out" "$FAKE_TOKEN" '输出里没有令牌原文'
hasnt "$out" 'FAKEFAKEFAKE' '输出里没有私钥原文'
has "$out" 'E2-令牌' '只报规则与位置'

echo '--- 5) warn 级规则 ---'
out="$(bash "$SRC" --files "$F/envsec.conf" 2>&1)"; rc=$?
rc_is "$rc" 1 '赋值型密钥 rc=1'; has "$out" 'W1' '报出 W1'
out="$(bash "$SRC" --files "$F/homepath.txt" 2>&1)"; rc=$?
rc_is "$rc" 1 '绝对家目录 rc=1'; has "$out" 'W2' '报出 W2'
out="$(bash "$SRC" --files "$F/mail.txt" 2>&1)"; rc=$?
rc_is "$rc" 1 '邮箱 rc=1'; has "$out" 'W3' '报出 W3'
out="$(bash "$SRC" --files "$F/plain/ok.md" --max-file-mb 0 2>&1)"; rc=$?
rc_is "$rc" 1 '--max-file-mb 0 时任意文件都算大文件'; has "$out" 'W4' '报出 W4'

echo '--- 6) --strict 把 warn 提级 ---'
out="$(bash "$SRC" --files "$F/mail.txt" --strict 2>&1)"; rc=$?
rc_is "$rc" 2 '--strict 下 warn → rc=2'

echo '--- 7) 目录模式：跳过 .git 与二进制扩展名 ---'
out="$(bash "$SRC" --path "$F" 2>&1)"; rc=$?
rc_is "$rc" 2 '整目录扫描 rc=2（有 error 样本）'
has "$out" '跳过' '报出跳过的二进制数'
hasnt "$out" '.git/config' '不扫 .git/'
hasnt "$out" 'bin/pic.png' '不扫二进制扩展名'
has "$out" 'plain/note.log' '非跳过扩展名照扫（.log/.kv 之类都要扫）'

echo '--- 8) 零扫描与空索引 ---'
mkdir -p "$T/empty"
out="$(bash "$SRC" --path "$T/empty" 2>&1)"; rc=$?
rc_is "$rc" 2 '空目录 rc=2'; has "$out" 'E0-零扫描' '报出零扫描'
G="$T/gitrepo"; mkdir -p "$G"; git -C "$G" init -q 2>/dev/null
out="$(bash "$SRC" --staged --repo "$G" 2>&1)"; rc=$?
rc_is "$rc" 0 '--staged 空索引 rc=0'; has "$out" '空索引' '空索引是正常状态'

echo '--- 9) --staged 扫的是索引里的内容 ---'
printf '# 干净\n' > "$G/a.md"; git -C "$G" add a.md
out="$(bash "$SRC" --staged --repo "$G" 2>&1)"; rc=$?
rc_is "$rc" 0 '干净索引 rc=0'
printf 'API_KEY=%s\n' "$FAKE_TOKEN" > "$G/hidden.env"; git -C "$G" add hidden.env
out="$(bash "$SRC" --staged --repo "$G" 2>&1)"; rc=$?
rc_is "$rc" 2 '索引里有令牌 → rc=2'
hasnt "$out" "$FAKE_TOKEN" '--staged 报告同样不回显原文'
# 已提交但未暂存的内容不该被误报：把它从索引里撤掉
git -C "$G" rm -q --cached hidden.env
out="$(bash "$SRC" --staged --repo "$G" 2>&1)"; rc=$?
rc_is "$rc" 0 '撤出索引后不再报（扫的是索引）'

echo '--- 10) --json ---'
bash "$SRC" --files "$F/token.env" --json > "$T/out.json" 2>/dev/null
if python3 -c "import json;d=json.load(open('$T/out.json'));assert d['error']>=1 and d['scanned']==1 and d['findings']" 2>/dev/null; then
  ok '--json 可解析且字段齐全'
else
  bad '--json 不可解析'
fi

echo '--- 11) 全程只读 ---'
AFTER="$(snap_tree)"
[ "$BEFORE" = "$AFTER" ] && ok '被扫目录逐字节未变' || bad '扫描改动了被扫目录'

echo '--- 12) 公开仓（rdsh 仓库）不得有 error ---'
REPO="${RDSH_REPO_DIR:-$(dirname "$(dirname "$(readlink -f "$SRC")")")}"
if [ -d "$REPO/.git" ]; then
  out="$(bash "$SRC" --path "$REPO" --quiet 2>&1)"; rc=$?
  if [ "$rc" = 2 ]; then bad "公开仓扫描有 error：$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; else ok "公开仓扫描无 error（rc=$rc）"; fi
else
  ok "跳过（$REPO 不是 git 仓库）"
fi

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
