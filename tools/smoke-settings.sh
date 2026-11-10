#!/usr/bin/env bash
# =============================================================================
# smoke-settings.sh —— settings.yaml 携带与登记（B8）的隔离功能冒烟
#
# 规则：**每版本一份真文件**（顶层键随 schema 变，不做稳定根软链）+ 迁移时 **schema 感知携带**
#       + 在账本里登记（路径 + sha 指纹）。
# 硬断言：
#   * carry 的合并语义：同名键取**源**值 / 目标独有键保留（新 schema）/ 源独有键附带并**告警**
#   * `--dry-run` 一个字节都不写
#   * 旧文件进**回收站**（可还原），不是被覆盖丢掉
#   * 账本登记 settings 路径与 sha；文件被改后 `settings show` 报"与账本不符"
#   * 目标还没有 settings.yaml 时整份携带并明确告警"无法做 schema 对照"
#   * 真机 settings.yaml 逐字节未变
#
# 用法: bash smoke-settings.sh [Rdsh.sh 路径]（默认 ../Rdsh.sh）
# =============================================================================
set -u

case "${1:-}" in
  -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
esac
SRC="${1:-$(dirname "$(readlink -f "$0")")/../Rdsh.sh}"
[ -f "$SRC" ] || { echo "找不到 Rdsh.sh: $SRC" >&2; exit 2; }
if ! bash "$SRC" help 2>/dev/null | grep -q 'rdsh settings'; then
  echo "被测脚本里没有 \`rdsh settings\`（旧版本？先 publish --stage）：$SRC" >&2; exit 2
fi

T="$(mktemp -d)"; B="$T/base"
trap 'rm -rf "$T"' EXIT
mkdir -p "$B/dsh" "$B/.dsh" "$B/.dsh-backup" "$B/.dsh-suite/state"
cp -p "$SRC" "$B/dsh/Rdsh.sh"
# 夹具布局**从工具推导**（2026-10-12，同 smoke-state/doctor）：本工具即唯一真源，布局约定变了自己跟上
[ -f "$B/dsh/Rdsh.sh" ] || cp -p "$(dirname "$(readlink -f "$SRC")")/Rdsh.sh" "$B/dsh/Rdsh.sh" 2>/dev/null || true
eval "$(env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
        -u RDSH_SHARED_HOME -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT -u RDSH_STATE_ROOT \
        -u DSH_LOG_DIR -u DSH_WEB_PORT -u RDSH_PLUGIN_ROOT \
        RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$B/dsh/Rdsh.sh" base --print-paths 2>/dev/null)"
mkdir -p "$MANAGE_ROOT" "$DATA_ROOT" "$SHARED_ROOT" "$BACKUP_ROOT" "$LOG_DIR" 2>/dev/null || true
printf '# 账本\n# 字段: key|version|role|role_set_at|installed_at|source|commit|built_at|migrated_from|baseline_for|dir|data|note|settings|settings_sha\n' \
  > "$STATE_ROOT/versions.kv"
printf '# journal\n' > "$STATE_ROOT/journal.log"

run() { env -u RDSH_BASE -u RDSH_MANAGE_ROOT -u RDSH_DATA_ROOT -u RDSH_BACKUP_ROOT \
          -u RDSH_SHARED_HOME -u RDSH_STATE_ROOT -u RDSH_RUN_DIR -u RDSH_DEBUG_ROOT \
          -u RDSH_PLUGIN_ROOT -u DSH_LOG_DIR -u RDSH_TRASH -u RDSH_MYDSH_REPO -u RDSH_PATCHES \
          RDSH_CONFIG="$B/rdsh-config" RDSH_BASE="$B" bash "$MANAGE_ROOT/Rdsh.sh" "$@" </dev/null; }

mkck() { # <目录名> <版本>
  local d="$MANAGE_ROOT/$1" h="$DATA_ROOT/$2"
  mkdir -p "$d/node_modules" "$DATA_ROOT/$2"
  printf '{"name":"deepseek-harness","version":"%s"}\n' "$2" > "$d/package.json"
  printf x > "$d/.installed"
}
mkck ck-old 9.9.7-rc.2
mkck ck-new 9.9.6-beta.1

OLD="$DATA_ROOT/9.9.7-rc.2/settings.yaml"
NEW="$DATA_ROOT/9.9.6-beta.1/settings.yaml"
cat > "$OLD" <<'EOF'
# 老版本的 settings
ui:
  theme: dark
llm:
  model: old-model
only-in-old: 1
EOF
cat > "$NEW" <<'EOF'
# 新版本的 settings
ui:
  theme: light
llm:
  model: new-model
new-only:
  x: 1
EOF
OLD_SHA="$(sha256sum "$OLD" | cut -c1-8)"; NEW_SHA="$(sha256sum "$NEW" | cut -c1-8)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3（不该有：$2）" ;; *) ok "$3" ;; esac; }
rc_is(){ [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 rc=$2，实际 $1）" ; }

# 真机根从**真实配置**推导（不调被测工具，避免自定位回退到 cwd）；读不到配置时按约定回退
_rc="$HOME/.config/rdsh/config"   # 只认**用户**配置：selfupdate 嵌套跑冒烟会注入临时 RDSH_CONFIG（$BASE/rdsh.config），拿它当真机根就会去隔离 base 里找实例 → 嵌套冒烟必挂（2026-10-12 实测）
_rb="$(sed -nE 's/^[[:space:]]*BASE[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$_rc" 2>/dev/null | tail -1)"
REAL_ROOT="${_rb:-$HOME/dsh}"            # 空 → 本机约定根（2026-10-11 起 BASE=~/dsh）
REAL="$REAL_ROOT/.dsh-suite/data"
REAL_BEFORE="$(sha256sum "$REAL"/*/settings.yaml 2>/dev/null || true)"

echo '--- 1) 播种时登记 settings（路径 + sha） ---'
out="$(run state --init 2>&1)"; rc=$?
rc_is "$rc" 0 'state --init rc=0'
KV="$(cat "$STATE_ROOT/versions.kv")"
has "$KV" "$OLD" '账本记下旧版本的 settings 路径'
has "$KV" "$OLD_SHA" '账本记下旧版本 settings 的 sha'
has "$KV" "$NEW_SHA" '账本记下新版本 settings 的 sha'

echo '--- 2) --dry-run 一个字节都不写 ---'
BEFORE_ALL="$(sha256sum "$OLD" "$NEW" | sort)"
out="$(run settings carry 9.9.7-rc.2 9.9.6-beta.1 --dry-run 2>&1)"; rc=$?
rc_is "$rc" 0 'dry-run rc=0'
has "$out" '共有键 2 个' '报出共有键数'
has "$out" '目标独有 1 个' '报出目标独有键数（新 schema 的键）'
has "$out" '~ ui' '逐键列出将发生的变化'
has "$out" '内容不同' '多行块说清"内容不同"（不会假装显示了具体值）'
[ "$BEFORE_ALL" = "$(sha256sum "$OLD" "$NEW" | sort)" ] && ok 'dry-run 没有改动任何文件' || bad 'dry-run 改动了文件'

echo '--- 3) 真携带：schema 感知合并 ---'
out="$(run settings carry 9.9.7-rc.2 9.9.6-beta.1 2>&1)"; rc=$?
rc_is "$rc" 0 'carry rc=0'
has "$(cat "$NEW")" 'theme: dark' '同名键取**源**值（用户的选择被携带）'
has "$(cat "$NEW")" 'model: old-model' '另一个同名键也取源值'
has "$(cat "$NEW")" 'new-only:' '目标独有键**保留**（新 schema 自己的）'
has "$(cat "$NEW")" 'x: 1' '目标独有键的内容完整保留'
has "$(cat "$NEW")" 'only-in-old: 1' '源独有键被附带'
has "$(cat "$NEW")" '目标版本的 settings.yaml 里没有声明' '附带的键有标记说明，不会让人误以为生效'

echo '--- 4) 旧文件进了回收站（可还原），不是被丢掉 ---'
E="$(ls -1dt "$B/.dsh-suite/trash"/*/ 2>/dev/null | sed -n '1p')"
[ -n "$E" ] && ok "生成了回收条目：$(basename "$E")" || bad '旧文件没有进回收站'
PAY="$(find "$E" -type f -name settings.yaml 2>/dev/null | sed -n '1p')"
if [ -n "$PAY" ]; then
  [ "$(sha256sum "$PAY" | cut -c1-8)" = "$NEW_SHA" ] && ok '回收站里就是被替换掉的那份旧文件' || bad '回收站里的内容不是旧文件'
else
  bad '回收条目里没有 settings.yaml'
fi

echo '--- 5) 账本指纹更新；文件被改后报"与账本不符" ---'
NEW_SHA2="$(sha256sum "$NEW" | cut -c1-8)"
has "$(cat "$STATE_ROOT/versions.kv")" "$NEW_SHA2" '账本指纹已刷新为携带后的值'
out="$(run settings show 9.9.6-beta.1 2>&1)"
has "$out" '与账本一致' '改前：与账本一致'
printf '\n手改了一行\n' >> "$NEW"
out="$(run settings show 9.9.6-beta.1 2>&1)"
has "$out" '与账本不符' '改后：报与账本不符（漂移可见）'
has "$out" "$NEW_SHA2" '报出账本记的旧指纹'

echo '--- 6) 反向携带：源独有键要告警 ---'
out="$(run settings carry 9.9.6-beta.1 9.9.7-rc.2 --dry-run 2>&1)"
has "$out" '源独有' '报出源独有键'
has "$out" '可能不认识' '明确提示新版本可能忽略'

echo '--- 7) 目标还没有 settings.yaml → 整份携带 + 告警 ---'
rm -f "$OLD"
out="$(run settings carry 9.9.6-beta.1 9.9.7-rc.2 2>&1)"; rc=$?
rc_is "$rc" 0 '整份携带 rc=0'
has "$out" '无法做 schema 对照' '明确说无法做 schema 对照'
[ -f "$OLD" ] && has "$(cat "$OLD")" 'new-only:' '整份内容都带过去了' || bad '整份携带没落地'

echo '--- 8) 0.2.x profile-scoped：无 settings.yaml 时明确指向 profile 配置 ---'
PH="$DATA_ROOT/9.9.8-rc.1"; mkdir -p "$PH/profiles/web"; printf 'ui-theme:\n  mode: dark\n' > "$PH/profiles/web/cordis.patch.yml"
out="$(run settings keys "$PH" 2>&1)"
has "$out" 'profile-scoped' 'keys 指向 profile-scoped 配置'
out="$(run settings carry "$PH" 9.9.7-rc.2 --dry-run 2>&1)"
has "$out" 'profile-scoped' 'carry 对 0.2.x 源明确跳过'

echo '--- 9) 真机 settings 逐字节未变 ---'
[ "$REAL_BEFORE" = "$(sha256sum "$REAL"/*/settings.yaml 2>/dev/null || true)" ] && ok '真机 settings.yaml 未变' || bad '真机 settings.yaml 被改动'

echo
printf '结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
