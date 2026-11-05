#!/usr/bin/env bash
# =============================================================================
# session-archive.sh —— 会话历史档案库（**在 dsh 之外**，纯 shell，不耗词元）
#
# 需求（用户 2026-10-08）：统一管理所有版本的所有会话；可自选会话复制并加入指定实例。
# 定位：rdsh 的**附属脚本**（同 patch-manager.sh / plugin-sync.sh 的范式），
#       经 `rdsh archive …` 转发；能力要进 `rdsh bridge --spec` 才能被 dsh 侧插件看见。
#
# 已实测的事实（设计依据，别再猜）：
#   · 会话自包含：session.lock + session.v3/v4.jsonl.zstd，无外部引用
#   · 注册表：<数据 home>/storages/workspace.json
#       { unit:{name,version}, global:{initialized,workspaceIds:[wsUuid…]},
#         tables:{ workspaces:{ <wsUuid>:{ createdAt, path, sessionIds:[sessionUuid…] } } } }
#   · 工作区目录名 = cwd 的 '/'→'-' 加 '--' 包裹（如 /p/ws → --p-ws--）
#   · 标题随会话数据走（JSONL 里有 session/title 记录），projcache 只是派生
#   · 工具链：zstd / jq / python3 / rsync 均可用
#
# 隐私：档案库是**本地隐私区，永不进任何仓库**（会话数据在 scan-secrets 里是 error 级）。
#
# 用法:
#   session-archive.sh --manifest                                   # 外部能力清单（给 rdsh 读）
#   session-archive.sh collect [<版本|--all>] [--dry-run]     # 收档（按 session-id 幂等；session-<uuid> 与裸 <uuid> 都收）
#   session-archive.sh ls [--version V] [--workspace K] [--since YYYY-MM-DD] [--grep 词]
#   session-archive.sh show <session-id> [--head N]           # 看标题/时间/首条用户消息
#   session-archive.sh export <session-id> --to <目录>        # 导出可读 JSONL（复盘当材料用）
#   session-archive.sh verify [--rebuild-index]               # 完整性检查 / 重建索引
#   session-archive.sh inject <session-id…> --into <版本> [--apply]   # **加入指定实例**（默认只出计划）
#   session-archive.sh inject <会话id> --into <版本> --as-context [--apply]  # 格式不兼容时的**替代方案**：只落明文供目标实例当上下文读
#   session-archive.sh browse --to <目录> [--all-text] [--open]  # **在 dsh 之外浏览**：生成 index.html（可按需导出正文）
#   session-archive.sh scan --from <版本|home|archive> [--json] [--since YYYY-MM-DD] [--grep 词]
#                                                             # **直接扫源 home**（无需先 collect）：表格或 JSON 数组
#   session-archive.sh pick --from <版本|home|archive> --select-only --out <selection.json>
#                           [--ids a,b,c | --file f] [--preview N]   # 只落选择清单（迁移前门用），不碰任何 home
#   session-archive.sh pick --from <版本|home|archive> --into <版本|home路径>
#                           [--ids a,b,c | --file f] [--preview N] [--apply] [--json]
#                                                             # **从源 home 直接注入目标实例**（默认只出计划）
#   · pick 的会话选择：给了 --ids/--file 就用它；否则**只有 TTY** 才进纯 bash 编号选择器
#     （n/b 翻页、p <n> 预览、1,3-5 / all / none）；非 TTY 又没给 --ids → 报错退出，绝不静默选。
#   · selection JSON（供 rdsh migrate --sessions-file 读）:
#       { schema, from, fromHome, createdAt, count, sessions:[会话id…], items:[{id,title,createdAt,
#         createdAtMs,cwd,workspace,bytes,preview,dir}…] }   —— 前门只读 sessions/items，本脚本不解释它
#   · --preview N：预览消息条数（默认 2；0=不预览），用于 TTY 的 p 与 --into 的计划展示。
# 环境变量:
#   RDSH_BASE            套件基目录（优先级同 rdsh：env > 配置文件 > 默认 $HOME/Mapp）
#   SESSION_ARCHIVE_DIR  档案库位置（默认 $BASE/Archive/sessions）——测试用
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"

# ---- 基目录解析：与 rdsh 同优先级，且**不写死任何本机路径**（2026-10-08 硬编码调查结论）----
resolve_base() {   # 环境契约优先：主脚本（rdsh）调用我们时会把已解析的根放进 RDSH_BASE
  if [ -n "${RDSH_BASE:-}" ]; then printf '%s\n' "$RDSH_BASE"; return; fi
  if [ -f "$RDSH_CONFIG" ]; then
    local b; b="$(sed -nE 's/^[[:space:]]*BASE[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$RDSH_CONFIG" | tail -1)"
    [ -n "$b" ] && { printf '%s\n' "${b/#\~/$HOME}"; return; }
  fi
  printf '%s\n' "$HOME/Mapp"
}
BASE="$(resolve_base)"
SUITE="$BASE/.dsh-suite"
DATA_DIR="$SUITE/data"
# 2026-11-02 P2：会话归档与工作产物归档统一收进 $BASE/Archive/（sessions/ 与 works/）——用户口径。
ARCHIVE="${RDSH_ARCHIVE_DIR:-${SESSION_ARCHIVE_DIR:-$BASE/Archive/sessions}}"
INDEX="$ARCHIVE/index.tsv"
BACKUP_ROOT="$SUITE/backup"

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
log() { printf '[archive] %s\n' "$*" >&2; }

# ---- 审计：每条命令都留下"谁在什么时候对哪台实例做了什么"（对齐 rdsh 的 journal 习惯）----
journal() { # <动作> <对象> <备注>
  local j="${RDSH_JOURNAL:-$SUITE/state/journal.log}"
  [ -d "$(dirname "$j")" ] || return 0
  printf '%s|session-archive|%s|%s\n' "$(date +%Y-%m-%dT%H:%M:%S%:z)" "$1" "$2${3:+ note=$3}" >> "$j"
}

# ---- 元数据提取：从会话 JSONL 流里取 createdAt/cwd/标题/首条用户消息 ----
# 2026-11-01（scan/pick）：旧实现有三个问题，这里一次修掉——
#   ① 消息正文在 data.content（[{type:text,text}]）里，旧代码取 d["content"]/d["data"] 只能拿到 dict 的
#      Python repr，故"首条用户消息"兜底实际是垃圾字符串；现在按 data.content → data.text → 顶层 content/text 依次取。
#   ② 标题事件会**多次更新**（先 fallback 占位、后 provider 生成），旧代码取第一条会拿到截断占位；现在取**最后一条**。
#   ③ 需要给 scan/pick 的 preview（首条用户消息截断）与按时间排序用的毫秒时间戳，旧接口没有。
# 兼容性：meta_of 的输出契约（id \t createdAt \t cwd \t title）不变，仍给 collect/inject/verify 用。
meta_full_of() { # <会话目录> → TSV: id \t createdAt(原始) \t createdAtMs \t cwd \t title \t preview
  local dir="$1" id f out
  id="$(basename "$dir")"
  f="$(session_file_of "$dir")"
  [ -n "$f" ] || { printf '%s\t\t\t\t\t\n' "$id"; return; }
  f="$dir/$f"
  # 用 ( set +o pipefail; ... ) 包住：python 读满 200000 行会提前 break，上游 zstd 吃 SIGPIPE 以 70 退出，
  # 在 set -o pipefail 下整条管道会被判失败，进而被 set -e 掀翻脚本（2026-10-08 实测 collect 静默中止）。
  out="$( set +o pipefail
  zstd -dc -- "$f" 2>/dev/null | python3 -c '
import sys, json
created = cwd = title = ""
cms = 0
first_user = ""
# 跳过宿主自动注入的"不是人话"用户消息（系统提醒/工作区指令/运行时快照/审批策略等），
# 让 preview 与"[首条用户消息]"兜底落在**真正的人写内容**上；全跳过则 preview 为空。
BOILER = ("<system-reminder>", "Current runtime context.", "Time sampled while preparing turn",
          "Elapsed since the preceding", "Approval prompts are disabled",
          "You are interacting with the user through", "Browser time zone for this request:")
def ctext(x):
    if isinstance(x, list):
        return " ".join(p for p in (ctext(y) for y in x) if p)
    if isinstance(x, dict):
        if "text" in x: return ctext(x["text"])
        if "content" in x: return ctext(x["content"])
        return ""
    return "" if x is None else str(x)
def msgtext(d):
    cands = []
    data = d.get("data")
    if isinstance(data, dict):
        cands.append(data.get("content")); cands.append(data.get("text"))
    cands.append(d.get("content")); cands.append(d.get("text"))
    for c in cands:
        t = ctext(c).strip()
        if t: return t
    return ""
def squash(s):
    return " ".join(str(s).replace("\t", " ").split())
for i, line in enumerate(sys.stdin):
    if i > 200000: break
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if not created and d.get("createdAt"):
        created = str(d["createdAt"])
        try: cms = int(float(created))
        except Exception: cms = 0
    if not cwd and d.get("cwd"): cwd = str(d["cwd"]).replace("\t", " ").replace("\n", " ")
    t = d.get("type", "")
    if t == "user/message":
        s = squash(msgtext(d))
        if s and not s.startswith(BOILER) and not first_user: first_user = s
    elif t == "session/title":
        data = d.get("data")
        v = data.get("title") if isinstance(data, dict) else d.get("title")
        if v: title = squash(v)
if not title and first_user:
    title = "[首条用户消息] " + first_user[:120]
preview = first_user[:80]
print("\t".join([created, str(cms), cwd, title, preview]))
' )"
  printf '%s\t%s\n' "$id" "${out:-}"
}

meta_of() { # <会话目录>  →  TSV: id \t createdAt \t cwd \t title（collect/inject/verify 的旧契约）
  # 旧契约的 id 是**去掉 session- 前缀**的裸 uuid（老版本目录名就是裸 uuid）；这里保持原样，
  # 免得改 collect 索引/verify 重建的行格式。scan/pick 要的是**目录名原样**，直接用 meta_full_of。
  meta_full_of "$1" | cut -f1,2,4,5 | sed -e 's/^session-//'
}


# ---- 取"最高版本"的会话数据文件（实测有 4 种名字：session.jsonl.zstd / v2 / v3 / v4）----
session_file_of() {  # <会话目录>
  find "$1" -maxdepth 1 -name 'session*.jsonl.zstd' -printf '%f\n' 2>/dev/null | sort -V | tail -1
}
# 会话文件版本标签（v1/v2/v3/v4，无 v 视为 v1）
session_ver_of() {  # <会话目录>
  local f; f="$(session_file_of "$1")"
  case "$f" in
    *session.jsonl.zstd) printf 'v1\n' ;;
    *) printf '%s\n' "$(printf '%s' "$f" | sed -E 's/^session\.(v[0-9]+)\..*/\1/')" ;;
  esac
}

ws_key_of() { # <cwd> → 会话目录名（工作区键）
  printf -- '--%s--\n' "$(printf '%s' "$1" | sed -e 's|^/||' -e 's|/|-|g')"
}


# =============================================================================
# scan / pick 公共件（2026-11-01）
#   · 源解析：--from 接受「版本名」/「数据 home 路径」/ archive（档案库 objects 目录）
#   · 元数据：直扫 <home>/sessions/<工作区键>/<会话id>/session*.jsonl.zstd，**不依赖档案库索引**
#   · 输出：表格 / JSON（用 python3，脚本既有依赖；不引入 fzf/dialog/whiptail/gum）
# =============================================================================

# ---- 临时文件兜底清理（异常路径也不留垃圾）----
TMPFILES=()
cleanup_tmpfiles() { local f; for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do [ -n "$f" ] && rm -f -- "$f"; done; return 0; }
trap cleanup_tmpfiles EXIT

# ---- 源/目标解析：<版本名|home路径|archive> → 绝对路径 ----
resolve_home() {  # <版本|home路径|archive> [来源|目标] → 绝对路径（找不到即 die）
  local x="${1:-}" what="${2:-目标}" real=""
  [ -n "$x" ] || die "缺少参数：$what（版本名或数据 home 路径）"
  if [ "$x" = "~" ]; then
    x="$HOME"
  elif [ "${x:0:1}" = "~" ] && [ "${x:1:1}" = "/" ]; then   # ~/ 前缀（只认家目录；~user 不支持）
    x="$HOME/${x:2}"
  fi
  if [ "$x" = "archive" ] || [ "$x" = "档案库" ]; then printf '%s\n' "$ARCHIVE/objects"; return 0; fi
  if [ -d "$x" ]; then real="$(cd "$x" && pwd -P)"; fi
  if [ -z "$real" ] && [ -d "$DATA_DIR/$x" ]; then real="$(cd "$DATA_DIR/$x" && pwd -P)"; fi
  [ -n "$real" ] || die "找不到$what：$x（既不是目录，也不是 $DATA_DIR 下的版本；看 rdsh list）"
  printf '%s\n' "$real"
}

# ---- 展示/格式化小工具 ----
short_id_of() { local x="${1#session-}"; printf '%s\n' "${x:0:8}"; }
short_ws_of() {  # --home-srs-workspace-wsdsh-- → home-srs-workspace-wsdsh（过长取尾部）
  local w="$1"; w="${w#--}"; w="${w%--}"
  [ "${#w}" -le 26 ] || w="…${w: -25}"
  printf '%s\n' "$w"
}
trim_str() { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s\n' "$s"; }
human_size() { awk -v b="${1:-0}" 'BEGIN{ if (b>=1048576) printf "%.1fM", b/1048576; else if (b>=1024) printf "%.0fK", b/1024; else printf "%dB", b }'; }
when_of() {  # <createdAt原始> [createdAtMs] → "YYYY-MM-DD HH:MM"
  local c="${1:-}" ms="${2:-0}"
  if [ "$ms" != "0" ] && [ -n "$ms" ]; then date -d "@$((ms / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0; fi
  case "$c" in
    '') printf '?\n' ;;
    *[!0-9]*) date -d "$c" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s\n' "${c:0:16}" ;;
    *) date -d "@$((c / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?\n' ;;
  esac
}
date_of() {  # <createdAt原始> <createdAtMs> → YYYY-MM-DD（取不到输出空，供 --since 过滤）
  local c="${1:-}" ms="${2:-0}"
  if [ "$ms" != "0" ] && [ -n "$ms" ]; then date -d "@$((ms / 1000))" '+%F' 2>/dev/null && return 0; fi
  case "$c" in
    '') return 0 ;;
    *[!0-9]*) printf '%s\n' "${c:0:10}" ;;
    *) date -d "@$((c / 1000))" '+%F' 2>/dev/null || return 0 ;;
  esac
}

# ---- 单个会话目录 → 9 列 TSV 行：id \t createdAt \t createdAtMs \t cwd \t 字节 \t 目录 \t 工作区 \t 标题 \t preview
row_of_dir() {  # <会话目录> [工作区兜底键]
  local d="$1" fallback_ws="${2:-}" meta id created cms cwd title preview bytes ws
  meta="$(meta_full_of "$d")" || return 1
  IFS=$'\t' read -r id created cms cwd title preview <<< "$meta"
  [ -n "$id" ] || return 1
  bytes="$(du -sb "$d" 2>/dev/null | cut -f1)"; [ -n "$bytes" ] || bytes=0
  ws=""; [ -n "$cwd" ] && ws="$(ws_key_of "$cwd")"
  [ -n "$ws" ] || ws="$fallback_ws"
  [ -n "$ws" ] || ws="--unknown--"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "${created:-}" "${cms:-0}" "$cwd" "$bytes" "$d" "$ws" "$title" "$preview"
}

# ---- 行过滤（--since / --grep）：SCAN_SINCE / SCAN_GREP 为空即不过滤 ----
should_keep_row() {  # <9 列行>
  local line="$1" id created cms cwd bytes sdir ws title preview d
  IFS=$'\t' read -r id created cms cwd bytes sdir ws title preview <<< "$line"
  if [ -n "$SCAN_SINCE" ]; then
    d="$(date_of "$created" "$cms")"
    [ -n "$d" ] || return 1
    if [[ "$d" < "$SCAN_SINCE" ]]; then return 1; fi
  fi
  if [ -n "$SCAN_GREP" ]; then
    if ! printf '%s\n' "$id | $cwd | $ws | $title | $preview" | grep -F -i -q -- "$SCAN_GREP"; then return 1; fi
  fi
  return 0
}

# ---- 扫源，填充 ROWS（按时间倒序）与 ITEM_* 数组（同序）----
collect_items() {  # <from 参数>；读全局 SCAN_SINCE / SCAN_GREP
  local from="$1" root kind sdir line fallback_ws raw=() sorted i
  local id created cms cwd bytes ws title preview
  root="$(resolve_home "$from" "来源")"
  kind="home"
  if [ "$from" = "archive" ] || [ "$from" = "档案库" ]; then
    kind="archive"
    [ -d "$root" ] || die "档案库为空（$ARCHIVE/objects 不存在；先跑 collect，或改用 --from <版本|home>）"
  elif [ -d "$ARCHIVE/objects" ] && [ "$root" = "$(cd "$ARCHIVE/objects" && pwd -P)" ]; then
    kind="archive"
  fi
  if [ "$kind" = "archive" ]; then
    log "来源：档案库 $root（objects 目录）"
  else
    [ -d "$root/sessions" ] || die "来源 home 下没有 sessions/：$root"
    log "来源：$from → $root"
  fi
  SRC_ARG="$from"; SRC_HOME="$root"
  ROWS=(); ITEM_ID=(); ITEM_CREATED=(); ITEM_CMS=(); ITEM_CWD=(); ITEM_BYTES=(); ITEM_DIR=(); ITEM_WS=(); ITEM_TITLE=(); ITEM_PREVIEW=()
  if [ "$kind" = "archive" ]; then
    while IFS= read -r sdir; do
      line="$(row_of_dir "$sdir" "--unknown--")" || continue
      if should_keep_row "$line"; then raw+=("$line"); fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  else
    while IFS= read -r sdir; do
      fallback_ws="$(basename "$(dirname "$sdir")")"
      line="$(row_of_dir "$sdir" "$fallback_ws")" || continue
      if should_keep_row "$line"; then raw+=("$line"); fi
    done < <(find "$root/sessions" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
  fi
  if [ "${#raw[@]}" -gt 0 ]; then
    sorted="$(printf '%s\n' "${raw[@]}" | sort -t $'\t' -k3,3nr -k1,1)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ROWS+=("$line")
    done <<< "$sorted"
  fi
  for line in ${ROWS[@]+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id created cms cwd bytes sdir ws title preview <<< "$line"
    ITEM_ID+=("$id"); ITEM_CREATED+=("$created"); ITEM_CMS+=("$cms"); ITEM_CWD+=("$cwd")
    ITEM_BYTES+=("$bytes"); ITEM_DIR+=("$sdir"); ITEM_WS+=("$ws")
    ITEM_TITLE+=("$title"); ITEM_PREVIEW+=("$preview")
  done
  if [ "${#ROWS[@]}" -eq 0 ]; then
    if [ -n "$SCAN_SINCE$SCAN_GREP" ]; then log "过滤后没有匹配的会话"; else log "来源里没有找到任何会话"; fi
  fi
  return 0
}

# ---- 把数组当行喂给 stdout（空数组也安全）----
print_rows() {  # <数组名>
  local -n _rows_ref="$1"
  if [ "${#_rows_ref[@]}" -gt 0 ]; then printf '%s\n' "${_rows_ref[@]}"; fi
}

# ---- JSON 输出：stdin = 9 列行；mode=scan 输出数组，selection/into 输出对象 ----
emit_json() {  # <mode:scan|selection|into> <from> <fromHome> <into> <intoHome> <apply:0|1>
  local script
  script="$(cat <<'PY'
import sys, json, datetime
mode, src, src_home, into, into_home, apply_flag = (sys.argv[1:7] + [''] * 6)[:6]
items = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line: continue
    f = line.split('\t')
    while len(f) < 9: f.append('')
    sid, created, cms, cwd, nbytes, sdir, ws, title, preview = f[:9]
    try: cms_v = int(cms) if cms else None
    except ValueError: cms_v = None
    try: nb = int(nbytes)
    except ValueError: nb = 0
    items.append({'id': sid, 'title': title, 'createdAt': created or '',
                  'createdAtMs': cms_v, 'cwd': cwd, 'workspace': ws,
                  'bytes': nb, 'preview': preview, 'dir': sdir})
if mode == 'scan':
    print(json.dumps(items, ensure_ascii=False, indent=2))
    sys.exit(0)
now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
doc = {'schema': 'rdsh-session-selection/1', 'from': src, 'fromHome': src_home,
       'createdAt': now, 'count': len(items),
       'sessions': [x['id'] for x in items], 'items': items}
if mode == 'into':
    doc['into'] = into
    doc['intoHome'] = into_home
    doc['apply'] = (apply_flag == '1')
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
)"
  python3 -c "$script" "$@"
}

# ---- 预览一个会话：首 N 条消息 + 最近一条助手消息（TTY 的 p <n> / --preview）----
preview_session() {  # <会话目录> [条数]
  local dir="$1" n="${2:-2}" f
  f="$(session_file_of "$dir")"
  [ -n "$f" ] || { printf '      （该会话没有数据文件）\n'; return 0; }
  ( set +o pipefail
  zstd -dc -- "$dir/$f" 2>/dev/null | python3 -c '
import sys, json
limit = max(1, int(sys.argv[1]))
first = []; last = None
# 跳过宿主自动注入的"不是人话"用户消息（系统提醒/工作区指令/运行时快照/审批策略等），
# 让 preview 与"[首条用户消息]"兜底落在**真正的人写内容**上；全跳过则 preview 为空。
BOILER = ("<system-reminder>", "Current runtime context.", "Time sampled while preparing turn",
          "Elapsed since the preceding", "Approval prompts are disabled",
          "You are interacting with the user through", "Browser time zone for this request:")
def ctext(x):
    if isinstance(x, list): return " ".join(p for p in (ctext(y) for y in x) if p)
    if isinstance(x, dict):
        if "text" in x: return ctext(x["text"])
        if "content" in x: return ctext(x["content"])
        return ""
    return "" if x is None else str(x)
def msgtext(d):
    cands = []; data = d.get("data")
    if isinstance(data, dict):
        cands += [data.get("content"), data.get("text")]
    cands += [d.get("content"), d.get("text")]
    for c in cands:
        t = ctext(c).strip()
        if t: return t
    return ""
for i, line in enumerate(sys.stdin):
    if i > 200000: break
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    t = d.get("type", "")
    if t not in ("user/message", "assistant/message"): continue
    s = " ".join(msgtext(d).replace("\t", " ").split())
    if not s or s.startswith(BOILER): continue
    role = "用户" if t == "user/message" else "助手"
    if len(first) < limit: first.append((role, s))
    last = (role, s)          # 最近一条消息（用户或助手都算，"最近消息"预览用）
seen = set()
for role, s in first:
    key = role + "|" + s[:80]
    if key in seen: continue
    seen.add(key)
    print("      [%s] %s" % (role, s[:200]))
tail = " ".join(x[1][:80] for x in first)
if last and last[1][:80] not in tail:
    print("      [最近·%s] %s" % (last[0], last[1][:200]))
' "$n" ) || true
}


# ---------------------------------------------------------------- 外部能力协议（rdsh 插件接入点）
# 作为 rdsh 的**第一个外部能力**：`rdsh archive <子命令> …`
# 主脚本会执行 `<本文件> --manifest` 读这里的能力清单，并在调用时把已解析的环境放进环境变量
# （RDSH_BASE / RDSH_JOURNAL / RDSH_IFACE_VERSION …），所以本脚本**不需要自己再解析一遍根目录**。
print_manifest() {
  cat <<'MF'
iface=1
x-session-archive|archive|collect/ls/show/export/verify/inject/browse/scan/pick|write||会话历史档案库：统一管理所有版本的会话，可自选复制并加入指定实例；scan 直扫源 home、pick 出选择清单或直接注入（纯 shell，在 dsh 之外，不耗词元）
MF
  exit 0
}

# ---------------------------------------------------------------- collect
cmd_collect() {
  local target="" dry=0 a
  for a in "$@"; do case "$a" in
    --dry-run) dry=1 ;; --all) target="--all" ;; -*) die "未知选项: $a" ;; *) target="$a" ;;
  esac; done
  local versions=()
  if [ -z "$target" ] || [ "$target" = "--all" ]; then
    while IFS= read -r d; do versions+=("$(basename "$d")"); done < <(find "$DATA_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
  else
    [ -d "$DATA_DIR/$target" ] || die "找不到版本/实例的数据 home: $target"
    versions=("$target")
  fi
  mkdir -p "$ARCHIVE/objects"
  [ -f "$INDEX" ] || printf 'id\tversion\tworkspace\tcreatedAt\ttitle\tbytes\tcollectedAt\n' > "$INDEX"
  local added=0 skipped=0 v
  for v in "${versions[@]}"; do
    local home="$DATA_DIR/$v"
    while IFS= read -r sdir; do
      local base id
      base="$(basename "$sdir")"
      # 旧 home 的会话目录可能是 session-<uuid>，也可能是裸 <uuid>（0.1.x 常见）；
      # 两者都收，**归档目录名原样保留**（目录名要与会话 header 的 id 一致，v0 的 header id 是裸 uuid），
      # 源 home 不重命名、不写入。
      case "$base" in
        session-*) id="${base#session-}" ;;
        [0-9a-fA-F]*-*-*-*-*) id="$base" ;;
        *) continue ;;
      esac
      if [ -d "$ARCHIVE/objects/$base" ] || [ -d "$ARCHIVE/objects/session-$id" ] || [ -d "$ARCHIVE/objects/$id" ]; then
        skipped=$((skipped+1)); continue
      fi
      local meta created cwd title
      meta="$(meta_of "$sdir")"
      IFS=$'\t' read -r _ created cwd title <<< "$meta"
      local key bytes
      key="$(ws_key_of "${cwd:-/unknown}")"
      bytes="$(du -sb "$sdir" 2>/dev/null | cut -f1)"
      if [ "$dry" = 1 ]; then
        printf '  将收：%s  [%s]  %s  %s  %s 字节\n' "$id" "$v" "${created:-?}" "${title:-（无标题）}" "$bytes"
      else
        rsync -a --exclude 'session.lock' "$sdir/" "$ARCHIVE/objects/$base/"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$v" "$key" "${created:-}" "${title:-}" "${bytes:-0}" "$(date +%F)" >> "$INDEX"
      fi
      added=$((added+1))
    done < <(find "$home/sessions" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
  done
  if [ "$dry" = 1 ]; then log "干跑：将收 $added 个会话（已存在 $skipped 个）"; else
    log "已收 $added 个会话（跳过已存在 $skipped 个）→ $ARCHIVE"; journal collect "${versions[*]}" "added=$added"; fi
}

# ---------------------------------------------------------------- ls
cmd_ls() {
  [ -f "$INDEX" ] || die "档案库还没有索引（先跑 collect）"
  local ver="" ws="" since="" pat=""
  while [ $# -gt 0 ]; do case "$1" in
    --version) ver="$2"; shift 2 ;; --workspace) ws="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;; --grep) pat="$2"; shift 2 ;; *) die "未知选项: $1" ;;
  esac; done
  awk -F'\t' -v ver="$ver" -v ws="$ws" -v since="$since" -v pat="$pat" '
    NR==1 { printf "  %-38s %-12s %-14s %-10s %s\n", "会话ID", "版本", "时间(ms)", "字节", "标题"; next }
    (ver==""||$2==ver) && (ws==""||index($3,ws)>0) && (since==""||$4>=since) && (pat==""||index($5,pat)>0) {
      t=$5; if (length(t)>48) t=substr(t,1,46)"…"
      printf "  %-38s %-12s %-14s %-10s %s\n", $1, $2, $4, $6, t
      n++
    }
    END { printf "  —— 共 %d 条\n", n+0 }
  ' "$INDEX"
}


# ---- 把会话渲染成人可读文本（user/assistant 消息，逐条）----
render_transcript() {  # <会话目录> [最多条数，0=不限]
  local dir="$1" limit="${2:-0}"
  local fn; fn="$(session_file_of "$dir")"
  [ -n "$fn" ] || { printf '（该会话没有数据文件）\n'; return 0; }
  ( set +o pipefail   # 下游可能提前 break，见 meta_of 的说明
  zstd -dc "$dir/$fn" 2>/dev/null | python3 -c '
import sys, json
limit = int(sys.argv[1]); n = 0
def text_of(d):
    c = d.get("content") or d.get("text") or d.get("data")
    if isinstance(c, list):
        return " ".join(str(x.get("text", "")) if isinstance(x, dict) else str(x) for x in c)
    return "" if c is None else str(c)
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    t = d.get("type", "")
    if t == "user/message":
        print("\n### 用户\n"); print(text_of(d)); n += 1
    elif t == "assistant/message":
        print("\n### 助手\n"); print(text_of(d)); n += 1
    if limit and n >= limit: break
' "$limit" ) || true
}

# ---------------------------------------------------------------- show
cmd_show() {
  local id="${1:-}"; shift || true
  local head=3; [ "${1:-}" = "--head" ] && { head="${2:-3}"; }
  [ -n "$id" ] || die "用法: show <session-id> [--head N]"
  local dir="$ARCHIVE/objects/session-$id"
  [ -d "$dir" ] || die "档案库里没有这个会话: $id"
  echo "  目录: $dir"
  echo "  文件:"; find "$dir" -maxdepth 1 -type f -printf '    %8s  %f\n'
  local f; f="$(session_file_of "$dir")"; f="$dir/${f:-无}"
  echo "  内容预览（前 $head 条用户消息）:"
  ( set +o pipefail   # 同上：下游取够 limit 就 break，别让 pipefail 掀翻脚本
  zstd -dc "$f" 2>/dev/null | python3 -c '
import sys, json
n = 0; limit = int(sys.argv[1])
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    t = d.get("type", "")
    if t in ("user/message",) or (t == "assistant/message" and False):
        txt = ""
        c = d.get("content") or d.get("text") or d.get("data")
        if isinstance(c, list):
            txt = " ".join(str(x.get("text", "")) if isinstance(x, dict) else str(x) for x in c)
        else: txt = str(c)
        print("    - " + txt.replace("\n", " ")[:160]); n += 1
        if n >= limit: break
' "$head" ) || true
}

# ---------------------------------------------------------------- export
cmd_export() {
  local id="${1:-}"; shift || true
  local to=""; [ "${1:-}" = "--to" ] && to="${2:-}"
  [ -n "$id" ] && [ -n "$to" ] || die "用法: export <session-id> --to <目录>"
  local dir="$ARCHIVE/objects/session-$id"
  [ -d "$dir" ] || die "档案库里没有这个会话: $id"
  mkdir -p "$to"
  local f out; out="$to/session-$id.jsonl"
  f="$(session_file_of "$dir")"; f="$dir/${f:-无}"
  zstd -dc "$f" > "$out"
  log "已导出可读文本：$out（$(wc -l < "$out") 行）"
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  local rebuild=0; [ "${1:-}" = "--rebuild-index" ] && rebuild=1
  [ -d "$ARCHIVE/objects" ] || die "档案库为空（先跑 collect）"
  local n=0 bad=0 empty=0
  while IFS= read -r d; do
    local id; id="$(basename "$d")"; id="${id#session-}"
    local fn; fn="$(session_file_of "$d")"
    if [ -z "$fn" ]; then
      if [ -f "$d/session.lock" ]; then printf '  [空] %s：只有 lock，没有会话数据\n' "$id"; empty=$((empty+1))
      else printf '  [坏] %s：没有任何会话文件\n' "$id"; bad=$((bad+1)); fi
      continue
    fi
    if ! zstd -t "$d/$fn" >/dev/null 2>&1; then printf '  [坏] %s：zstd 校验失败（%s）\n' "$id" "$fn"; bad=$((bad+1)); continue; fi
    n=$((n+1))
  done < <(find "$ARCHIVE/objects" -mindepth 1 -maxdepth 1 -type d | sort)
  log "完整：$n 个会话；空会话：$empty 个；坏：$bad 个"
  [ "$bad" = 0 ] || return 1
  if [ "$rebuild" = 1 ]; then
    printf 'id\tversion\tworkspace\tcreatedAt\ttitle\tbytes\tcollectedAt\n' > "$INDEX.new"
    while IFS= read -r d; do meta_of "$d" >> "$INDEX.new"; done < <(find "$ARCHIVE/objects" -mindepth 1 -maxdepth 1 -type d | sort)
    mv "$INDEX.new" "$INDEX"; log "索引已重建：$INDEX"
  fi
}

# ---------------------------------------------------------------- 注入核心（inject 与 pick --into 共用）
# 把「一个源会话目录」装进「一个已存在的数据 home」：
#   ① 备份目标注册表 workspace.json（沿用既有命名 bak-...sessionarchive-<时间戳>，再带 8 位会话 id 防同秒相撞）
#   ② 拷会话目录（排除 session.lock；**目录名原样保留**，它就是 DSH 的会话 id）
#   ③ 更新 workspace.json：找 path==cwd 的工作区；没有就新建 uuid 并登记到 global.workspaceIds
# 只增不改：目标已有同 id（目录）→ 直接 die，不给覆盖的口子。
# 2026-11-01：原 inject 里内联的 ①②③ 抽成函数；同时修一个真 bug——
#   旧代码把会话拷成 session-<id> 目录，却把**去掉 session- 前缀的裸 id** 写进注册表；
#   新版按注册表 id 拼目录，找不到会话。现在注册表里的 id 与目标目录名严格一致。
install_session_into() {  # <源会话目录> <目标 home> <目标版本名(格式闸门用)> [force:0|1]
  local src="$1" dest="$2" gatever="$3" force="${4:-0}"
  local reg="$dest/storages/workspace.json" sid meta created cms cwd title key ver
  [ -d "$dest" ] || die "目标实例不存在: $dest"
  [ -f "$reg" ] || die "目标实例没有注册表: $reg"
  sid="$(basename "$src")"
  [ -n "$(session_file_of "$src")" ] || die "源会话没有数据文件，拒绝注入: $sid"
  meta="$(meta_full_of "$src")"
  IFS=$'\t' read -r _ created cms cwd title _ <<< "$meta"
  [ -n "$cwd" ] || die "读不到该会话的 cwd，无法定位目标工作区: $sid"
  key="$(ws_key_of "$cwd")"
  # 只增不改：目标已有同 id 目录 → 拒绝（不覆盖，也不改名硬塞）
  if find "$dest/sessions" -maxdepth 2 -type d -name "$sid" -print -quit 2>/dev/null | grep -q .; then
    die "目标实例已有该会话，拒绝覆盖: $sid"
  fi
  # 格式闸门（沿用 inject 2026-10-08 的规则）
  ver="$(session_ver_of "$src")"
  if [ "$force" != 1 ]; then
    case "$gatever" in
      0.1.[0-6]*) die "格式闸门：目标 $gatever 较老，而会话格式为 $ver。两条出路：① 确认能读就加 --force-format；② **改用替代方案 --as-context**（只落明文供目标实例当上下文读，不动注册表）" ;;
    esac
  fi
  # ① 备份注册表
  cp -p "$reg" "$dest/storages/workspace.json.bak-sessionarchive-$(date +%Y%m%d-%H%M%S)-$(short_id_of "$sid")"
  # ② 拷会话（目录名 = 会话 id，原样保留；不收 lock）
  mkdir -p "$dest/sessions/$key"
  rsync -a --exclude 'session.lock' "$src/" "$dest/sessions/$key/$sid/"
  # ③ 更新注册表
  python3 - "$reg" "$cwd" "$sid" "$created" <<'PY'
import json, sys, uuid, io, os, datetime
reg, cwd, sid = sys.argv[1], sys.argv[2], sys.argv[3]
created_raw = sys.argv[4] if len(sys.argv) > 4 else ''

def iso(ms=None):
    """时间戳（ms 数字或 ISO 串）→ 与真实条目同格式的 ISO 串（如 2026-09-08T15:29:57.110Z）。"""
    t = None
    if ms:
        try:
            t = datetime.datetime.fromtimestamp(int(float(ms)) / 1000, datetime.timezone.utc)
        except (TypeError, ValueError):
            try: t = datetime.datetime.fromisoformat(str(ms).replace('Z', '+00:00'))
            except (TypeError, ValueError): t = None
    if t is None: t = datetime.datetime.now(datetime.timezone.utc)
    if t.tzinfo is None: t = t.replace(tzinfo=datetime.timezone.utc)
    t = t.astimezone(datetime.timezone.utc)
    return t.strftime('%Y-%m-%dT%H:%M:%S.') + f'{t.microsecond // 1000:03d}Z'

now = iso()
d = json.load(io.open(reg, encoding='utf-8'))
tbl = d.setdefault('tables', {}).setdefault('workspaces', {})
found = None
for wsid, w in tbl.items():
    if w.get('path') == cwd: found = wsid; break
if found is None:
    found = str(uuid.uuid4())
    # 照真实条目形状写：path / title(=目录名) / sessionIds / createdAt(=会话时间，取不到则现在) / updatedAt
    tbl[found] = {'path': cwd, 'title': os.path.basename(cwd.rstrip('/')) or cwd,
                  'sessionIds': [], 'createdAt': iso(created_raw), 'updatedAt': now}
    d.setdefault('global', {}).setdefault('workspaceIds', []).append(found)
if sid not in tbl[found].setdefault('sessionIds', []):
    tbl[found]['sessionIds'].append(sid)
tbl[found]['updatedAt'] = now   # 真实写入者也会更新它
json.dump(d, io.open(reg, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"    注册表已更新：工作区 {found[:8]}…，会话数 {len(tbl[found]['sessionIds'])}，会话 id {sid}")
PY
}


# ---------------------------------------------------------------- inject（默认只出计划）
cmd_inject() {
  local ids=(); local into="" apply=0 force=0 asctx=0 a
  while [ $# -gt 0 ]; do case "$1" in
    --into) into="${2:-}"; shift 2 ;; --apply) apply=1; shift ;;
    --force-format) force=1; shift ;; --as-context) asctx=1; shift ;;
    -*) die "未知选项: $1" ;; *) ids+=("$1"); shift ;;
  esac; done
  [ "${#ids[@]}" -gt 0 ] && [ -n "$into" ] || die "用法: inject <session-id…> --into <版本> [--apply]"
  local dest="$DATA_DIR/$into"
  [ -d "$dest" ] || die "目标实例不存在: $into（看 rdsh list）"
  local reg="$dest/storages/workspace.json"
  [ -f "$reg" ] || die "目标实例没有注册表: $reg"

  # 运行中的实例会在内存里持有注册表 → 磁盘改了可能被覆盖（先查）
  if command -v ss >/dev/null 2>&1 && pgrep -fa 'ds[h].*web' >/dev/null 2>&1; then
    log "注意：本机有 dsh 实例在跑。请确认**目标实例不在跑**，否则注册表可能被内存覆盖。"
  fi

  local id
  for id in "${ids[@]}"; do
    local src="$ARCHIVE/objects/session-$id"
    [ -d "$src" ] || die "档案库里没有: $id"
    # 目标是否已有同 id（只增不改）
    if find "$dest/sessions" -maxdepth 2 -type d -name "session-$id" -print -quit 2>/dev/null | grep -q .; then
      die "目标实例已有该会话，拒绝覆盖: $id"
    fi
    local meta created cwd title
    meta="$(meta_of "$src")"; IFS=$'\t' read -r _ created cwd title <<< "$meta"
    [ -n "$cwd" ] || die "读不到该会话的 cwd，无法定位目标工作区: $id"
    local key; key="$(ws_key_of "$cwd")"
    # 格式闸门（用户 2026-10-08 批准"要"）：粗判会话文件版本 vs 目标版本
    local ver; ver="$(find "$src" -maxdepth 1 -name 'session.v*.jsonl.zstd' -printf '%f\n' | sed -E 's/session\.(v[0-9]+)\..*/\1/')"
    printf '  %s\n    来源: 档案库  时间: %s\n    目标: %s  工作区: %s（目录 %s）\n    会话格式: %s  标题: %s\n' \
      "$id" "${created:-?}" "$into" "$cwd" "$key" "${ver:-?}" "${title:-（无标题）}"
    if [ "$asctx" = 1 ]; then
      # 替代方案（用户 22:31 批示要求）：不做"注入"，只落一份明文供目标实例当指定上下文读
      if [ "$apply" != 1 ]; then
        echo "    计划：导出明文 → ${dest}/session-archive-inbox/session-$id.md（不动注册表、不写 sessions/）"; continue
      fi
      local inbox="$dest/session-archive-inbox"; mkdir -p "$inbox"
      local out="$inbox/session-$id.md"
      {
        printf '# 会话正文（来自会话档案库）\n\n'
        printf -- '- 会话 id：`%s`\n- 来源版本：见档案库索引\n- 原始时间戳：%s\n' "$id" "${created:-未知}"
        printf -- '- 原始格式：%s\n- 工作区：`%s`\n' "${ver:-?}" "${cwd:-未知}"
        printf -- '- **这不是"注入"**：因为目标实例（%s）的格式与它会话格式（%s）不兼容，故只落明文；\n' "$into" "${ver:-?}"
        printf -- '  请让该实例（或其某个会话）把本文件当作**指定上下文**来读。\n\n---\n'
        render_transcript "$src" 0
      } > "$out"
      log "已落明文上下文：$out（$(wc -l < "$out") 行）——未动目标实例的 sessions/ 与注册表"
      journal inject-as-context "$id" "into=$into"
      continue
    fi
    if [ "$apply" != 1 ]; then
      echo "    （未加 --apply：以上只是计划，未动任何文件）"; continue
    fi
    install_session_into "$src" "$dest" "$into" "$force"
    journal inject "$id" "into=$into ws=$key"
    log "已注入 $id → $into"
  done
  echo "  提示：注入后请用**只读**方式确认新实例能列出该会话，再宣称成功。"
}

# ---------------------------------------------------------------- scan（直扫源 home，不依赖档案库索引）
cmd_scan() {
  local from="" json=0 a
  SCAN_SINCE=""; SCAN_GREP=""
  while [ $# -gt 0 ]; do case "$1" in
    --from) from="${2:-}"; shift 2 ;;
    --json) json=1; shift ;;
    --since) SCAN_SINCE="${2:-}"; shift 2 ;;
    --grep) SCAN_GREP="${2:-}"; shift 2 ;;
    -*) die "未知选项: $1" ;;
    *) die "未知参数: $1（scan 只接受 --from/--json/--since/--grep）" ;;
  esac; done
  [ -n "$from" ] || die "用法: scan --from <版本|home|archive> [--json] [--since YYYY-MM-DD] [--grep 词]"
  if [ -n "$SCAN_SINCE" ] && ! [[ "$SCAN_SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    die "--since 要 YYYY-MM-DD（收到: $SCAN_SINCE）"
  fi
  collect_items "$from"
  if [ "$json" = 1 ]; then
    print_rows ROWS | emit_json scan "$from" "$SRC_HOME" "" "" 0 || die "生成 JSON 失败"
    return 0
  fi
  printf '\n  %-4s %-16s %-26s %-6s %-9s %s\n' "序号" "时间" "工作区" "大小" "短id" "标题"
  local i=0 id created cms ws bytes title when t
  while [ "$i" -lt "${#ITEM_ID[@]}" ]; do
    id="${ITEM_ID[$i]}"; created="${ITEM_CREATED[$i]}"; cms="${ITEM_CMS[$i]}"
    ws="${ITEM_WS[$i]}"; bytes="${ITEM_BYTES[$i]}"; title="${ITEM_TITLE[$i]}"
    when="$(when_of "$created" "$cms")"
    t="${title:-（无标题）}"; [ "${#t}" -le 60 ] || t="${t:0:59}…"
    printf '  %-4d %-16s %-26s %-6s %-9s %s\n' "$((i+1))" "$when" "$(short_ws_of "$ws")" \
      "$(human_size "$bytes")" "$(short_id_of "$id")" "$t"
    i=$((i+1))
  done
  printf '  —— 共 %d 条（来源 %s）\n' "${#ITEM_ID[@]}" "$from"
  if [ -n "$SCAN_SINCE$SCAN_GREP" ]; then log "过滤条件：${SCAN_SINCE:+since=$SCAN_SINCE }${SCAN_GREP:+grep=$SCAN_GREP}"; fi
}

# ---------------------------------------------------------------- pick（选会话：选择清单 / 直接注入）
# 两种出口：--select-only --out <json>（迁移前门用，目标 home 不存在时也能用）
#           --into <版本|home> [--apply]（独立功能：把选中的会话直接加进一个已存在实例）
# 选择来源：--ids / --file 优先；否则**只有 TTY** 进纯 bash 编号选择器；非 TTY 报错，不静默选。
PICK_PREVIEW=2
RAW_IDS=()
SELECTED=()

add_ids() {  # <字符串：逗号/空白分隔>
  local s="$1" tok
  [ -n "$s" ] || return 0
  while IFS= read -r tok; do
    tok="$(trim_str "$tok")"
    [ -n "$tok" ] && RAW_IDS+=("$tok")
  done < <(printf '%s\n' "$s" | tr ',[:space:]' '\n')
}
add_ids_from_file() {  # <文件；每行可含逗号分隔多个，'#' 后为注释，空行忽略>
  local f="$1" line
  [ -f "$f" ] || die "--file 不存在：$f"
  while IFS= read -r line || [ -n "$line" ]; do
    add_ids "${line%%#*}"
  done < "$f"
}

resolve_selection_by_ids() {  # 把 RAW_IDS 规范化成 SELECTED（ITEM_* 下标）；重复/未知即 die
  local want i found cand canon
  local -A seen=()
  SELECTED=()
  for want in "${RAW_IDS[@]}"; do
    found=-1
    for i in "${!ITEM_ID[@]}"; do
      for cand in "$want" "${want#session-}" "session-${want#session-}"; do
        if [ "$cand" = "${ITEM_ID[$i]}" ]; then found=$i; break; fi
      done
      [ "$found" -ge 0 ] && break
    done
    [ "$found" -ge 0 ] || die "源里找不到会话 id：$want（先跑 scan --from $SRC_ARG 看可用 id；也可只给 uuid）"
    canon="${ITEM_ID[$found]}"
    if [ -n "${seen[$canon]:-}" ]; then die "重复的会话 id（规范化后相同）：$want → $canon"; fi
    seen[$canon]=1
    SELECTED+=("$found")
  done
}

parse_selection_spec() {  # <spec：1,3-5 / all / none> → SELECTED
  local spec="$1" part a b i parts=()
  local -A mark=()
  SELECTED=()
  if [ "$spec" = "none" ]; then return 0; fi
  if [ "$spec" = "all" ]; then
    for i in "${!ITEM_ID[@]}"; do SELECTED+=("$i"); done
    return 0
  fi
  IFS=',' read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="$(trim_str "$part")"; [ -n "$part" ] || continue
    case "$part" in
      *-*) a="${part%%-*}"; b="${part##*-}" ;;
      *) a="$part"; b="$part" ;;
    esac
    if ! [[ "$a" =~ ^[0-9]+$ ]] || ! [[ "$b" =~ ^[0-9]+$ ]]; then
      die "选择编号格式不对：$part（应如 1 或 3-5，逗号分隔；或 all/none）"
    fi
    a=$((10#$a)); b=$((10#$b))
    if [ "$a" -lt 1 ] || [ "$b" -gt "${#ITEM_ID[@]}" ] || [ "$a" -gt "$b" ]; then
      die "编号超出范围：$part（共 ${#ITEM_ID[@]} 条）"
    fi
    i=$((a - 1))
    while [ "$i" -le $((b - 1)) ]; do mark[$i]=1; i=$((i + 1)); done
  done
  for i in "${!ITEM_ID[@]}"; do [ -n "${mark[$i]:-}" ] && SELECTED+=("$i"); done
  if [ "${#SELECTED[@]}" -eq 0 ]; then die "没有选中任何会话"; fi
}

pick_interactive() {  # 纯 bash 分页编号选择器（本机无 fzf/dialog/whiptail/gum）
  local total="${#ITEM_ID[@]}" page=0 ps=15 pages="" line="" i start end t
  if [ -n "${LINES:-}" ] && [ "$LINES" -gt 12 ] 2>/dev/null; then ps=$((LINES - 8)); fi
  [ "$ps" -gt 25 ] && ps=25
  [ "$ps" -lt 8 ] && ps=8
  pages=$(( (total + ps - 1) / ps )); [ "$pages" -lt 1 ] && pages=1
  while :; do
    printf '\n  共 %d 条 · 第 %d/%d 页 · 编号选择（如 1,3-5 / all / none），n 下页，b 上页，p <n> 预览，q 取消\n' \
      "$total" "$((page+1))" "$pages"
    printf '  %-4s %-16s %-22s %-9s %s\n' "序号" "时间" "工作区" "短id" "标题"
    start=$((page * ps)); end=$((start + ps)); [ "$end" -gt "$total" ] && end="$total"
    i="$start"
    while [ "$i" -lt "$end" ]; do
      t="${ITEM_TITLE[$i]:-（无标题）}"; [ "${#t}" -le 52 ] || t="${t:0:51}…"
      printf '  %-4d %-16s %-22s %-9s %s\n' "$((i+1))" \
        "$(when_of "${ITEM_CREATED[$i]}" "${ITEM_CMS[$i]}")" \
        "$(short_ws_of "${ITEM_WS[$i]}")" "$(short_id_of "${ITEM_ID[$i]}")" "$t"
      i=$((i + 1))
    done
    printf '  选择> '
    if ! IFS= read -r line; then printf '\n  （输入结束，取消）\n'; die "未选择任何会话（已取消）"; fi
    line="$(trim_str "$line")"
    case "$line" in
      '') continue ;;
      q|quit|exit) die "已取消（未选择任何会话）" ;;
      n|next) page=$((page + 1)); [ "$page" -ge "$pages" ] && page=0; continue ;;
      b|back|prev) page=$((page - 1)); [ "$page" -lt 0 ] && page=$((pages - 1)); continue ;;
      p\ *)
        i=$((10#$(trim_str "${line#p }")))
        if [ "$i" -lt 1 ] || [ "$i" -gt "$total" ]; then die "预览编号超出范围：$i（共 $total 条）"; fi
        printf '\n  #%d  %s\n    工作区：%s\n    标题：%s\n' "$i" "${ITEM_ID[$((i-1))]}" \
          "${ITEM_CWD[$((i-1))]:-?}" "${ITEM_TITLE[$((i-1))]:-（无标题）}"
        preview_session "${ITEM_DIR[$((i-1))]}" "$PICK_PREVIEW"
        printf '\n'; continue ;;
    esac
    parse_selection_spec "$line"
    return 0
  done
}

check_dest_not_running() {  # <目标 home> <要写入:0|1>：目标 home 正被 dsh web 进程使用时，写入必停、只读计划仅告警
  local dest="$1" need_write="${2:-1}" real_dest pid home pids=() unreadable=0
  real_dest="$(cd "$dest" && pwd -P)"
  while IFS= read -r pid; do [ -n "$pid" ] && pids+=("$pid"); done < <(pgrep -f 'ds[h].*web' 2>/dev/null || true)
  [ "${#pids[@]}" -gt 0 ] || return 0
  for pid in "${pids[@]}"; do
    home="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^DSH_HOME=//p' | tail -1)"
    if [ -z "$home" ]; then unreadable=1; continue; fi
    if [ "$(cd "$home" 2>/dev/null && pwd -P)" = "$real_dest" ]; then
      if [ "$need_write" = 1 ]; then
        die "目标实例正在运行（pid $pid，DSH_HOME=$home）：注册表可能被内存覆盖。请先停止该实例（rdsh stop …）再加 --apply"
      fi
      log "注意：目标实例正在运行（pid $pid，DSH_HOME=$home）。仅出计划可以；加 --apply 会被拒绝，请先 rdsh stop。"
      return 0
    fi
  done
  if [ "$unreadable" = 1 ]; then
    log "注意：本机有 dsh web 进程在跑，但读不到其 DSH_HOME，无法确认目标实例是否在跑；写入前请自行确认。"
  else
    log "已确认目标实例不在运行（本机其他 dsh web 实例与目标 home 无关）。"
  fi
}

print_pick_plan() {  # 用 SELECTED；human 计划：逐条时间/工作区/标题/预览
  local idx i=0
  for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do
    i=$((i+1))
    printf '  %d) %s\n    时间: %s  大小: %s\n    工作区: %s\n      cwd: %s\n    标题: %s\n' \
      "$i" "${ITEM_ID[$idx]}" "$(when_of "${ITEM_CREATED[$idx]}" "${ITEM_CMS[$idx]}")" \
      "$(human_size "${ITEM_BYTES[$idx]}")" "$(short_ws_of "${ITEM_WS[$idx]}")" \
      "${ITEM_CWD[$idx]:-?}" "${ITEM_TITLE[$idx]:-（无标题）}"
    [ -n "${ITEM_PREVIEW[$idx]}" ] && printf '    预览: %s\n' "${ITEM_PREVIEW[$idx]}"
    if [ "${PICK_PREVIEW:-0}" -gt 0 ]; then preview_session "${ITEM_DIR[$idx]}" "$PICK_PREVIEW"; fi
  done
}

cmd_pick() {
  local from="" sel_only=0 out="" ids_arg="" file_arg="" into="" apply=0 json=0 force=0
  local a idx dir j tmp dest n i=0 interactive=0
  PICK_PREVIEW=2
  RAW_IDS=(); SELECTED=()
  SCAN_SINCE=""; SCAN_GREP=""
  while [ $# -gt 0 ]; do case "$1" in
    --from) from="${2:-}"; shift 2 ;;
    --select-only) sel_only=1; shift ;;
    --out) out="${2:-}"; shift 2 ;;
    --ids) ids_arg="${2:-}"; shift 2 ;;
    --file) file_arg="${2:-}"; shift 2 ;;
    --preview) PICK_PREVIEW="${2:-}"; shift 2 ;;
    --into) into="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --json) json=1; shift ;;
    --force-format) force=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) die "未知参数: $1（pick 只接受 --from/--select-only/--out/--ids/--file/--preview/--into/--apply/--json）" ;;
  esac; done
  [ -n "$from" ] || die "用法: pick --from <版本|home|archive> (--select-only --out <json> | --into <版本|home>) [--ids a,b,c|--file f] [--preview N] [--apply] [--json]"
  if ! [[ "$PICK_PREVIEW" =~ ^[0-9]+$ ]]; then die "--preview 要非负整数（收到: $PICK_PREVIEW）"; fi
  if [ "$sel_only" = 1 ] && [ -n "$into" ]; then die "--select-only 与 --into 只能二选一"; fi
  if [ "$sel_only" != 1 ] && [ -z "$into" ]; then die "必须给 --select-only --out <json> 或 --into <版本|home>"; fi
  if [ "$sel_only" = 1 ]; then
    [ -n "$out" ] || die "--select-only 需要 --out <selection.json>"
  elif [ -n "$out" ]; then
    die "--out 只用于 --select-only（--into 模式不需要）"
  fi
  if [ -n "$ids_arg" ] && [ -n "$file_arg" ]; then die "--ids 与 --file 只能二选一"; fi

  collect_items "$from"
  if [ "${#ITEM_ID[@]}" -eq 0 ]; then die "来源里没有可供挑选的会话：$from"; fi

  [ -n "$ids_arg" ] && add_ids "$ids_arg"
  [ -n "$file_arg" ] && add_ids_from_file "$file_arg"
  if [ "${#RAW_IDS[@]}" -gt 0 ]; then
    resolve_selection_by_ids
  else
    if [ ! -t 0 ]; then
      die "非交互环境（stdin 不是 TTY）必须用 --ids a,b,c 或 --file f 指定会话；不静默选任何东西"
    fi
    interactive=1
    pick_interactive
  fi
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    if [ "$sel_only" = 1 ] && [ "$interactive" = 1 ]; then
      log "你显式选了 none：将写出空选择清单"
    else
      die "没有选中任何会话"
    fi
  fi

  # ---- 出口一：只写选择清单（不碰任何 home）----
  if [ "$sel_only" = 1 ]; then
    dir="$(dirname "$out")"; mkdir -p "$dir"
    local sel_rows=()
    for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do sel_rows+=("${ROWS[$idx]}"); done
    j="$(print_rows sel_rows | emit_json selection "$from" "$SRC_HOME" "" "" 0)" || die "生成 selection JSON 失败"
    if ! printf '%s\n' "$j" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      die "生成的 selection JSON 不合法（内部错误）"
    fi
    tmp="$out.tmp.$$"
    printf '%s\n' "$j" > "$tmp"
    mv "$tmp" "$out"
    log "已写选择清单：$out（${#SELECTED[@]} 个会话，from=$from）——未动任何 home"
    journal pick-select "${#SELECTED[@]}" "from=$from out=$out"
    [ "$json" = 1 ] && printf '%s\n' "$j"
    return 0
  fi

  # ---- 出口二：直接注入一个已存在实例（默认只出计划）----
  dest="$(resolve_home "$into" "目标")"
  [ -f "$dest/storages/workspace.json" ] || die "目标实例没有注册表：$dest/storages/workspace.json"
  [ -d "$dest/sessions" ] || die "目标 home 下没有 sessions/：$dest（看起来不是数据 home）"
  [ "$dest" != "$SRC_HOME" ] || die "目标与来源相同（$dest）：没有可搬的东西"
  check_dest_not_running "$dest" "$apply"
  # 写前只读预检：目标已有同 id → 全部拒绝（计划阶段也拒绝，避免"计划像成功、apply 才失败"）
  for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do
    if find "$dest/sessions" -maxdepth 2 -type d -name "${ITEM_ID[$idx]}" -print -quit 2>/dev/null | grep -q .; then
      die "目标已有同 id 会话，拒绝覆盖：${ITEM_ID[$idx]}"
    fi
  done
  n="${#SELECTED[@]}"
  if [ "$apply" != 1 ]; then
    if [ "$json" = 1 ]; then
      local sel_rows_p=()
      for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do sel_rows_p+=("${ROWS[$idx]}"); done
      print_rows sel_rows_p | emit_json into "$from" "$SRC_HOME" "$into" "$dest" 0 || die "生成 JSON 失败"
      return 0
    fi
    printf '\n  来源：%s → %s\n  目标：%s（%s）\n  将加入 %d 个会话\n' "$from" "$SRC_HOME" "$into" "$dest" "$n"
    print_pick_plan
    echo "  （未加 --apply：以上只是计划，未动任何文件）"
    return 0
  fi
  if [ "$json" != 1 ]; then
    printf '\n  来源：%s → %s\n  目标：%s（%s）\n' "$from" "$SRC_HOME" "$into" "$dest"
  fi
  for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do
    i=$((i+1))
    log "[$i/$n] ${ITEM_ID[$idx]} → 工作区 ${ITEM_WS[$idx]}"
    install_session_into "${ITEM_DIR[$idx]}" "$dest" "$(basename "$dest")" "$force"
    journal pick-into "${ITEM_ID[$idx]}" "from=$from into=$into ws=${ITEM_WS[$idx]}"
    log "已加入 ${ITEM_ID[$idx]} → $into"
  done
  log "已把 $n 个会话加入 $into（$dest）"
  if [ "$json" = 1 ]; then
    local sel_rows_a=()
    for idx in ${SELECTED[@]+"${SELECTED[@]}"}; do sel_rows_a+=("${ROWS[$idx]}"); done
    print_rows sel_rows_a | emit_json into "$from" "$SRC_HOME" "$into" "$dest" 1 || die "生成 JSON 失败"
    return 0
  fi
  echo "  提示：注入后请用**只读**方式确认新实例能列出该会话（rdsh start 后看会话列表），再宣称成功。"
}


# ---------------------------------------------------------------- browse（外部浏览）
cmd_browse() {
  local to="" alltext=0 open=0 a
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="${2:-}"; shift 2 ;; --all-text) alltext=1; shift ;;
    --open) open=1; shift ;; -*) die "未知选项: $1" ;; *) shift ;;
  esac; done
  [ -n "$to" ] || die "用法: browse --to <目录> [--all-text] [--open]"
  [ -f "$INDEX" ] || die "档案库还没有索引（先跑 collect）"
  mkdir -p "$to/text"
  local n=0
  if [ "$alltext" = 1 ]; then
    while IFS= read -r d; do
      local id; id="$(basename "$d")"; id="${id#session-}"
      render_transcript "$d" 0 > "$to/text/$id.txt" 2>/dev/null || true
      n=$((n+1))
    done < <(find "$ARCHIVE/objects" -mindepth 1 -maxdepth 1 -type d | sort)
    log "已导出 $n 份正文 → $to/text/"
  fi
  python3 - "$INDEX" "$to" "$alltext" <<'PY'
import sys, io, html, os, datetime
index, to, alltext = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
rows = []
data = io.open(index, encoding="utf-8").read().split("\n")[1:]
for line in data:
    f = line.split("	")
    if len(f) < 7 or not f[0]: continue
    sid, ver, ws, created, title, size, coll = f[0], f[1], f[2], f[3], f[4], f[5], f[6]
    try: when = datetime.datetime.fromtimestamp(int(created)/1000).strftime("%Y-%m-%d %H:%M")
    except Exception: when = "?"
    rows.append((when, sid, ver, ws, title, size, coll))
rows.sort(reverse=True)
txt = os.path.join(to, "text")
out = []
out.append("<!doctype html><meta charset='utf-8'><title>会话档案库</title>")
out.append("<style>body{font:14px/1.6 system-ui,sans-serif;margin:24px;max-width:1200px}"
           "table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #ddd;padding:6px 8px;text-align:left}"
           "th{background:#f5f5f5;position:sticky;top:0}tr:hover{background:#fafafa}.dim{color:#888}"
           "input{padding:6px 10px;width:320px;margin-bottom:12px}code{background:#f2f2f2;padding:1px 4px}</style>")
out.append("<h1>会话档案库</h1>")
out.append(f"<p class='dim'>共 {len(rows)} 个会话 · 生成于 {datetime.datetime.now():%Y-%m-%d %H:%M} · "
           f"索引只回答<b>哪里有什么</b>，要数字请重跑 <code>collect</code></p>")
out.append("<input id='q' placeholder='过滤：标题 / 版本 / 工作区 / id' oninput='f()'>")
out.append("<table id='t'><thead><tr><th>时间</th><th>版本</th><th>工作区</th><th>标题</th><th>大小</th><th>正文</th></tr></thead><tbody>")
for when, sid, ver, ws, title, size, coll in rows:
    tf = os.path.join(txt, sid + ".txt")
    link = f"<a href='text/{html.escape(sid)}.txt'>看正文</a>" if os.path.exists(tf) else "<span class='dim'>—</span>"
    try: sz = f"{int(size)/1048576:.1f}M"
    except Exception: sz = "?"
    out.append("<tr>"
               f"<td>{when}</td><td>{html.escape(ver)}</td>"
               f"<td class='dim'>{html.escape(ws.strip('-')[:40])}</td>"
               f"<td>{html.escape(title) or '<span class=dim>（无标题）</span>'}</td>"
               f"<td class='dim'>{sz}</td><td>{link}</td>"
               f"<td class='dim'><code>{sid[:8]}</code></td></tr>")
out.append("</tbody></table>")
out.append("<script>function f(){const q=document.getElementById('q').value.toLowerCase();"
           "for(const r of document.querySelectorAll('#t tbody tr'))"
           "r.style.display=r.innerText.toLowerCase().includes(q)?'':'none';}</script>")
io.open(os.path.join(to, "index.html"), "w", encoding="utf-8").write("\n".join(out))
print(f"    索引已生成：{os.path.join(to, 'index.html')}（{len(rows)} 行）")
PY
  log "外部浏览：直接用浏览器打开 $to/index.html"
  [ "$open" = 1 ] && { command -v xdg-open >/dev/null 2>&1 && xdg-open "$to/index.html" || true; }
}

# ---------------------------------------------------------------- 分发
CMD="${1:-}"
case "$CMD" in --manifest) print_manifest ;; esac
shift || true
case "$CMD" in
  collect) cmd_collect "$@" ;;
  ls)      cmd_ls "$@" ;;
  show)    cmd_show "$@" ;;
  export)  cmd_export "$@" ;;
  verify)  cmd_verify "$@" ;;
  inject)  cmd_inject "$@" ;;
  scan)    cmd_scan "$@" ;;
  pick)    cmd_pick "$@" ;;
  browse)  cmd_browse "$@" ;;
  ""|-h|--help) sed -n '2,/^# =============================================================================/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "未知子命令: $CMD（collect|ls|show|export|verify|inject|browse|scan|pick）" ;;
esac
