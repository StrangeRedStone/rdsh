#!/usr/bin/env bash
# =============================================================================
# scan-secrets.sh —— 隐私守卫：提交/推送之前扫敏感内容（B5）
#
# 定位：把"担心泄漏"从**记性**变成**机制**。三处调用：
#   * tools/publish.sh  --stage 前扫白名单文件（不过就中止搬运）
#   * my-dsh scripts/backup.sh --commit 前扫将要提交的内容（找不到本脚本则拒绝提交）
#   * CI：扫整个仓库（error 级阻塞、warn 级咨询）
#
# 铁律（P1）：
#   1) **全程只读**：不写任何文件（连临时文件都不建 —— 把待提交内容复制到 /tmp 本身就是泄漏面）
#   2) **必须报出"扫了几个文件"**，总数为 0 时报 error（不许"零扫描却报干净"）
#   3) **报告里不回显敏感值**：只给 规则 + 文件:行 + 命中长度，避免守卫自己把密钥写进日志
#   4) 退出码 = 最高严重度：0 干净 / 1 有 warn / 2 有 error
#
# 用法:
#   scan-secrets.sh --path <目录>            扫目录下所有文本文件（跳过 .git/ 与二进制扩展名）
#   scan-secrets.sh --staged [--repo <dir>]  扫 git **索引里**的内容（= 将要提交的东西）
#   scan-secrets.sh --files <文件>...        扫指定文件
# 选项:
#   --json            机器可读输出
#   --quiet           只输出结论
#   --strict          把 warn 当 error（退出码 2）
#   --all             连二进制扩展名也扫（可能出乱码噪声）
#   --max-file-mb N   单文件超过 N MB 报 warn（默认 5）
# =============================================================================
set -uo pipefail

MODE=""; TARGET=""; REPO="."; JSON=0; QUIET=0; STRICT=0; ALL=0; MAX_MB=5
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --path) shift; MODE=path; TARGET="${1:-}" ;;
    --path=*) MODE=path; TARGET="${1#--path=}" ;;
    --staged) MODE=staged ;;
    --repo) shift; REPO="${1:-}" ;;
    --repo=*) REPO="${1#--repo=}" ;;
    --files) MODE=files ;;
    --json) JSON=1 ;;
    --quiet|-q) QUIET=1 ;;
    --strict) STRICT=1 ;;
    --all) ALL=1 ;;
    --max-file-mb) shift; MAX_MB="${1:-5}" ;;
    --max-file-mb=*) MAX_MB="${1#--max-file-mb=}" ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0"; exit 0 ;;
    -*) echo "[scan!] 未知选项：$1（--help 看用法）" >&2; exit 1 ;;
    *) FILES+=("$1"); MODE="${MODE:-files}" ;;
  esac
  shift || true
done
[ -n "$MODE" ] || { echo '[scan!] 用法: scan-secrets.sh --path <目录> | --staged [--repo <dir>] | --files <文件>...' >&2; exit 1; }
case "$MAX_MB" in ''|*[!0-9]*) echo "[scan!] --max-file-mb 需要整数（收到：$MAX_MB）" >&2; exit 1 ;; esac

# ---- 发现收集 ----
LEVELS=(); RULES=(); LOCS=(); NOTES=()
N_ERROR=0; N_WARN=0; N_FILES=0; N_SKIP=0; N_BIG=0

find_s() {  # <级别> <规则> <位置> <说明（不含敏感值）>
  local lv="$1" rule="$2" loc="$3" note="$4"
  LEVELS+=("$lv"); RULES+=("$rule"); LOCS+=("$loc"); NOTES+=("$note")
  case "$lv" in error) N_ERROR=$((N_ERROR+1)) ;; warn) N_WARN=$((N_WARN+1)) ;; esac
}

# ---- 规则 ----
# 二进制扩展名：默认跳过（--all 强制扫）
BIN_EXT_RE='\.(png|jpe?g|gif|webp|ico|bmp|woff2?|ttf|otf|eot|so|dylib|dll|exe|node|wasm|gz|bz2|xz|zip|7z|rar|tar|tgz|pdf|mp[34]|webm|mov|avi|db|sqlite|sqlite3|bin|dat|pyc|class|jar|o|a)$'
is_binary_ext() { printf '%s' "$1" | grep -qiE "$BIN_EXT_RE"; }

# 已知令牌形态（宁可窄一点，少误报）
TOKEN_RE='(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.)'
KEY_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----'
ENVSEC_RE='(API_?KEY|SECRET|TOKEN|PASSWORD|PASSWD|ACCESS_KEY|PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_.:-]{16,}'
HOMEPATH_RE='(/home/[a-z0-9_.-]+/|/Users/[A-Za-z0-9_.-]+/|C:\\Users\\)'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# 占位/掩码/示例不算命中（否则文档里的 token=*** 会天天报噪声）
PLACEHOLDER_RE='\*\*\*|…|<|\$\(|\$[A-Za-z_]|\{\{|example|placeholder|EXAMPLE|PLACEHOLDER|redacted|REDACTED|xxxxxx'
# 邮箱规则单独一套排除：普通占位过滤会连 "admin@example.org" 一起滤掉
EMAIL_EXCLUDE_RE='example\.(com|org|net)|noreply|no-reply|@localhost|@example'

real_path() {  # <路径（模式内的相对路径）> → 可用于 cat/du 的真实路径
  case "$MODE" in
    path) printf '%s/%s' "${TARGET%/}" "$1" ;;   # find 给的是相对扫描根的路径，必须补根
    *)    printf '%s' "$1" ;;
  esac
}
content_of() {  # <路径> → 内容（--staged 取 git 索引里的版本；--path 补上扫描根）
  if [ "$MODE" = "staged" ]; then git -C "$REPO" show ":$1" 2>/dev/null
  else cat "$(real_path "$1")" 2>/dev/null
  fi
}

hits() {  # <路径> <正则> [额外排除正则] [grep 附加标志，如 -i] → 命中的行号
  # 注意必须用 grep -e：像 -----BEGIN… 这种以 - 开头的模式会被 grep 当成选项解析
  local p="$1" re="$2" ex="${3-$PLACEHOLDER_RE}" fl="${4:-}" out
  if [ -n "$ex" ]; then
    out="$(content_of "$p" 2>/dev/null | grep -nE $fl -e "$re" 2>/dev/null | grep -vE -e "$ex" || true)"
  else
    out="$(content_of "$p" 2>/dev/null | grep -nE $fl -e "$re" 2>/dev/null || true)"
  fi
  [ -n "$out" ] && printf '%s\n' "$out" | cut -d: -f1 | tr '\n' ' '
  return 0
}

scan_file() {  # <路径（相对模式根）>
  local p="$1" base
  base="$(basename "$p")"
  if [ "$ALL" != "1" ] && is_binary_ext "$p"; then N_SKIP=$((N_SKIP+1)); return 0; fi
  N_FILES=$((N_FILES+1))
  # 文件名类规则
  case "$base" in
    .credentials.yaml|*credentials*.yaml|*credentials*.yml|.credentials.json|*credentials*.json)
      case "$base" in *credentials*README*|*credentials*.md) ;; *) find_s error E3-凭据文件 "$p" '文件名像凭据文件（不该进仓库）' ;; esac ;;
  esac
  case "$p" in
    */sessions/*|*/storages/*|*/.anonymous-user-id|*/profiles/*) find_s error E4-会话数据 "$p" '会话/用户数据路径（不该进仓库）' ;;
  esac
  # 内容类规则
  local h
  h="$(hits "$p" "$KEY_RE")"
  [ -n "$h" ] && find_s error E1-私钥 "$p:${h% }" '出现 PRIVATE KEY 头'
  h="$(hits "$p" "$TOKEN_RE")"
  [ -n "$h" ] && find_s error E2-令牌 "$p:${h% }" '出现形如 API 令牌的字符串'
  h="$(hits "$p" "$ENVSEC_RE" "$PLACEHOLDER_RE" '-i')"
  [ -n "$h" ] && find_s warn W1-赋值型密钥 "$p:${h% }" '出现疑似密钥赋值（确认不是占位）'
  h="$(hits "$p" "$HOMEPATH_RE" '')"
  [ -n "$h" ] && find_s warn W2-绝对家目录 "$p:${h% }" '出现绝对家目录路径（暴露用户名/结构）'
  h="$(hits "$p" "$EMAIL_RE" "$EMAIL_EXCLUDE_RE")"
  [ -n "$h" ] && find_s warn W3-邮箱 "$p:${h% }" '出现邮箱地址（公开仓需确认）'
  # 体积
  local kb=0
  if [ "$MODE" = "staged" ]; then
    kb="$(git -C "$REPO" cat-file -s ":$p" 2>/dev/null | awk '{printf "%d", $1/1024}')"
  else
    kb="$(du -k "$(real_path "$p")" 2>/dev/null | cut -f1 || echo 0)"
  fi
  if [ "${kb:-0}" -gt $((MAX_MB * 1024)) ]; then
    N_BIG=$((N_BIG+1))
    find_s warn W4-大文件 "$p" "体积 ${kb}KB 超过 ${MAX_MB}MB（确认该不该进仓库）"
  fi
  return 0
}

# ---- 收集待扫文件 ----
list_files() {
  case "$MODE" in
    path)
      [ -d "$TARGET" ] || { echo "[scan!] 目录不存在：$TARGET" >&2; exit 1; }
      ( cd "$TARGET" && find . -type f \
          -not -path './.git/*' -not -path '*/node_modules/*' -not -name '*.rdsh-trash.kv' \
          -printf '%P\n' 2>/dev/null | sort ) || true
      ;;
    staged)
      git -C "$REPO" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
      ;;
    files)
      printf '%s\n' "${FILES[@]:-}"
      ;;
  esac
}
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scan_file "$f"
done < <(list_files)

# 零扫描 → error（跟 doctor 同一条纪律）。例外：--staged 且索引为空是正常状态（没有可泄漏的东西）
if [ "$N_FILES" = "0" ]; then
  if [ "$MODE" = "staged" ]; then
    find_s info E0-空索引 '-' 'git 索引里没有待提交内容 → 无需扫描'
  else
    find_s error E0-零扫描 '-' "一个文件都没扫到（模式 $MODE$([ -n "$TARGET" ] && printf ' 目标 %s' "$TARGET")）—— 拒绝报「干净」"
  fi
fi

EXIT=0
[ "$N_WARN" -gt 0 ] && EXIT=1
[ "$N_ERROR" -gt 0 ] && EXIT=2
[ "$STRICT" = "1" ] && [ "$EXIT" -ge 1 ] && EXIT=2

if [ "$JSON" = "1" ]; then
  esc(){ printf '%s' "$1" | tr '\n\t' '  ' | tr -d '"\\'; }
  printf '{"mode":"%s","scanned":%s,"skipped_binary":%s,"error":%s,"warn":%s,"findings":[' \
    "$(esc "$MODE")" "$N_FILES" "$N_SKIP" "$N_ERROR" "$N_WARN"
  i=0; first=1
  while [ "$i" -lt "${#LEVELS[@]}" ]; do
    [ "$first" = "1" ] || printf ','
    printf '{"level":"%s","rule":"%s","loc":"%s","note":"%s"}' \
      "$(esc "${LEVELS[$i]}")" "$(esc "${RULES[$i]}")" "$(esc "${LOCS[$i]}")" "$(esc "${NOTES[$i]}")"
    first=0; i=$((i+1))
  done
  printf ']}\n'
else
  if [ "$QUIET" != "1" ]; then
    printf '\n隐私守卫（模式 %s%s）—— 扫了 %s 个文件，跳过 %s 个二进制扩展名\n' \
      "$MODE" "$([ -n "$TARGET" ] && printf '，目标 %s' "$TARGET")" "$N_FILES" "$N_SKIP"
    i=0
    while [ "$i" -lt "${#LEVELS[@]}" ]; do
      printf '  [%s] %-12s %-34s %s\n' "${LEVELS[$i]}" "${RULES[$i]}" "${LOCS[$i]}" "${NOTES[$i]}"
      i=$((i+1))
    done
  fi
  printf '  结论：扫 %s 个文件 → error %s / warn %s%s\n' \
    "$N_FILES" "$N_ERROR" "$N_WARN" "$([ "$N_BIG" -gt 0 ] && printf '（含 %s 个大文件）' "$N_BIG")"
  if [ "$N_ERROR" -gt 0 ]; then
    printf '  有 error：**不要提交/推送**——先清掉命中项，或把该路径加入忽略。\n'
  elif [ "$N_WARN" -gt 0 ]; then
    printf '  只有 warn（不阻塞）：逐条确认，公开仓尤其要看 W2/W3。\n'
  else
    printf '  干净。\n'
  fi
fi
exit "$EXIT"
