#!/usr/bin/env bash
# =============================================================================
# smoke-dvd.sh —— rdsh-dvd.py 的隔离冒烟（不碰真光驱）
#
# 作法：在临时 BASE 里拷贝 Rdsh.sh + rdsh-dvd.py，用假的
#       dvd+rw-mediainfo / growisofs / dvd+rw-format / eject 组成：
#         · 假介质状态（DVD+R 空白 / 用过的 DVD+R / DVD+RW / CD-R）
#         · 假 growisofs 把 ISO 复制到「设备文件」（普通文件），从而真跑通
#           建 ISO → 刻录 → 回读 cmp → 证据/日志 的整条链路
# 不验证真盘物理写入；真盘由人配合另行实测（见 README「证据与边界」）。
#
# 用法: bash smoke-dvd.sh [--plugin <rdsh-dvd.py>] [--rdsh <Rdsh.sh>]
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PLUGIN="${RDSH_DVD_PLUGIN:-}"
if [ -z "$PLUGIN" ] && command -v rdsh >/dev/null 2>&1; then
  PLUGIN="$(rdsh base --json 2>/dev/null | jq -r '.manageRoot + "/plugins.d/rdsh-dvd.py"' 2>/dev/null || true)"
fi
[ -n "$PLUGIN" ] || PLUGIN="/home/srs/dsh/rdsh/plugins.d/rdsh-dvd.py"
RDSH_SH="$SELF_DIR/../Rdsh.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) PLUGIN="${2:?}"; shift 2 ;;
    --rdsh)   RDSH_SH="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[ -f "$PLUGIN" ] || { echo "找不到插件：$PLUGIN" >&2; exit 2; }
[ -f "$RDSH_SH" ] || { echo "找不到 Rdsh.sh：$RDSH_SH" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-dvd.XXXXXX")"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
B="$T/base"; M="$T/manage"; FB="$T/bin"
mkdir -p "$B" "$M/plugins.d" "$FB" "$T/work" "$T/src/a" "$T/src/b"

cp -p "$RDSH_SH" "$M/Rdsh.sh"
cp -p "$PLUGIN" "$M/plugins.d/rdsh-dvd.py"
chmod 755 "$M/plugins.d/rdsh-dvd.py"
# rdsh selfcheck 需要至少一个「检出」对象；造一个假检出（不碰真实检出）
mkdir -p "$M/ck-1"
printf '{"name":"deepseek-harness","version":"9.9.9-rc.9"}\n' > "$M/ck-1/package.json"
printf x > "$M/ck-1/.installed"

# ---- 假工具 ----
cat > "$FB/dvd+rw-mediainfo" <<'EOF'
#!/usr/bin/env bash
kind="${FAKE_MEDIA:-dvd+r}"
if [[ -n "${FAKE_STATE:-}" && -f "$FAKE_STATE" ]]; then
  case "$kind" in dvd+rw-used) kind="dvd+rw-blank" ;; dvd-rw-used) kind="dvd-rw-blank" ;; esac
fi
case "$kind" in
  none)        echo ":-( no media mounted, exiting..."; echo "INQUIRY: [FAKE][NONE][1.0]"; exit 1 ;;
  dvd+r)       media="1Bh, DVD+R";  status="blank";    free="2295104" ;;
  dvd+r-used)  media="1Bh, DVD+R";  status="complete"; free="0" ;;
  dvd-r)       media="2Bh, DVD-R";  status="blank";    free="2295104" ;;
  dvd-r-used)  media="2Bh, DVD-R";  status="complete"; free="0" ;;
  dvd+rw-used) media="1Ah, DVD+RW"; status="complete"; free="0" ;;
  dvd+rw-blank)media="1Ah, DVD+RW"; status="blank";    free="2295104" ;;
  dvd-rw-used) media="2Ah, DVD-RW"; status="complete"; free="0" ;;
  dvd-rw-blank)media="2Ah, DVD-RW"; status="blank";    free="2295104" ;;
  cd)          media="1h, CD-R";    status="blank";    free="0" ;;
  *)           media="1Bh, DVD+R";  status="blank";    free="2295104" ;;
esac
cat <<TXT
INQUIRY:                [FAKE    ][DVD TEST        ][1.0]
GET [CURRENT] CONFIGURATION:
 Mounted Media:         $media
 Media ID:              FAKE/MEDIA
 Current Write Speed:   8.0x1385=11080KB/s
 Media Book Type:       00h, DVD-ROM book [revision 0]
READ DISC INFORMATION:
 Disc status:           $status
 Number of Sessions:    1
READ TRACK INFORMATION[#1]:
 Track State:           $status
 Track Size:            $free*2KB
 Free Blocks:           $free*2KB
READ CAPACITY:          0*2048=0
TXT
EOF

cat > "$FB/growisofs" <<'EOF'
#!/usr/bin/env bash
dev=""; iso=""
for a in "$@"; do case "$a" in -Z) ;; *=*) dev="${a%%=*}"; iso="${a#*=}" ;; esac; done
[ -n "$dev" ] && [ -n "$iso" ] || { echo "fake growisofs: bad args $*" >&2; exit 2; }
echo "fake growisofs: $iso -> $dev"
cp -- "$iso" "$dev"
EOF

cat > "$FB/dvd+rw-format" <<'EOF'
#!/usr/bin/env bash
echo "fake dvd+rw-format $*"
[ -n "${FAKE_STATE:-}" ] && : > "$FAKE_STATE"
EOF

cat > "$FB/eject" <<'EOF'
#!/usr/bin/env bash
echo "fake eject $*"
EOF
chmod +x "$FB"/*

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（缺：$2）" ;; esac; }

rdsh_run() {  # 在隔离 BASE 里调 rdsh（不读真实配置/资产）
  env -u RDSH_PLUGINS_DIR -u RDSH_JOURNAL \
    PATH="$FB:$PATH" RDSH_CONFIG="$T/noconfig" RDSH_BASE="$B" \
    RDSH_MANAGE_ROOT="$M" RDSH_BACKUP_ROOT="$T/backup" RDSH_JOURNAL="$T/journal.log" \
    FAKE_MEDIA="${FAKE_MEDIA:-dvd+r}" FAKE_STATE="${FAKE_STATE:-}" \
    bash "$M/Rdsh.sh" "$@" </dev/null 2>&1
}
plugin_direct() {
  env -u RDSH_PLUGINS_DIR PATH="$FB:$PATH" RDSH_BASE="$B" RDSH_MANAGE_ROOT="$M" \
    RDSH_BACKUP_ROOT="$T/backup" RDSH_JOURNAL="$T/journal.log" \
    FAKE_MEDIA="${FAKE_MEDIA:-dvd+r}" FAKE_STATE="${FAKE_STATE:-}" \
    python3 "$M/plugins.d/rdsh-dvd.py" "$@" </dev/null 2>&1
}
plugin_json() {
  env -u RDSH_PLUGINS_DIR PATH="$FB:$PATH" RDSH_BASE="$B" RDSH_MANAGE_ROOT="$M" \
    RDSH_BACKUP_ROOT="$T/backup" RDSH_JOURNAL="$T/journal.log" \
    FAKE_MEDIA="${FAKE_MEDIA:-dvd+r}" FAKE_STATE="${FAKE_STATE:-}" \
    python3 "$M/plugins.d/rdsh-dvd.py" "$@" </dev/null 2>"$T/plugin.err"
}

echo '--- 1) manifest / selfcheck / bridge ---'
OUT="$(plugin_direct --manifest)"; has "$OUT" "x-rdsh-dvd" "manifest 含 x-rdsh-dvd"
OUT="$(rdsh_run selfcheck)"; has "$OUT" "外部能力接口版本检查通过" "rdsh selfcheck 通过外部能力检查"
OUT="$(rdsh_run bridge --spec --json)"
python3 - "$OUT" <<'PY' && ok "bridge --spec --json 含能力且字段合法" || bad "bridge --spec --json 能力缺失/格式错"
import json,sys
d=json.loads(sys.argv[1])
c=[x for x in d["capabilities"] if x["id"]=="x-rdsh-dvd"]
assert len(c)==1 and c[0]["subcommand"]=="dvd" and c[0]["risk"]=="write", c
PY

echo '--- 2) probe：空白 DVD+R / 无介质 ---'
OUT="$(FAKE_MEDIA=dvd+r plugin_direct probe --device "$T/fake.dev" --json)"
python3 - "$OUT" <<'PY' && ok "probe 解析空白 DVD+R 正确" || bad "probe 解析错误"
import json,sys
d=json.loads(sys.argv[1]); assert d["present"] and d["media"]=="DVD+R" and d["status"]=="blank"; assert d["capacityBytes"]==4700372992, d
PY
OUT="$(FAKE_MEDIA=none plugin_direct probe --device "$T/fake.dev" --json)"; rc=$?
[ "$rc" = 1 ] || [ "$rc" = 3 ] && ok "probe 无介质返回非零（rc=$rc）" || bad "probe 无介质返回 rc=$rc"

echo '--- 3) plan：小容量多盘，文件不丢不重 ---'
dd if=/dev/urandom of="$T/src/a/one.bin" bs=200K count=1 status=none
dd if=/dev/urandom of="$T/src/a/two.bin" bs=200K count=1 status=none
dd if=/dev/urandom of="$T/src/b/three.bin" bs=200K count=1 status=none
OUT="$(plugin_direct plan "$T/src" --disc-size 300K --reserve 0 --json)"
python3 - "$OUT" <<'PY' && ok "plan 分盘正确、文件数守恒" || bad "plan 分盘错误"
import json,sys
p=json.loads(sys.argv[1]); files=[f["path"] for d in p["discs"] for f in d["files"]]
assert len(p["discs"])>=2, p
assert len(files)==3 and len(set(files))==3, files
for d in p["discs"]: assert d["bytes"] <= p["capacityBytes"], d
PY

echo '--- 4) burn --dry-run：造 ISO 并核对（不碰盘） ---'
OUT="$(plugin_direct burn "$T/src" --disc-size 1M --reserve 0 --stage "$T/stage-dry" --keep-iso --dry-run)"
rc=$?; [ "$rc" = 0 ] && ok "dry-run 退出码 0" || bad "dry-run rc=$rc：$OUT"
has "$OUT" "ISO 已生成并核对通过" "dry-run 造 ISO 并通过内容核对"

echo '--- 5) burn --apply：假设备全链路（ISO→刻录→cmp→证据） ---'
rm -f "$T/dev-r.bin"
OUT="$(FAKE_MEDIA=dvd+r plugin_direct burn "$T/src" --device "$T/dev-r.bin" --apply \
      --stage "$T/stage-r" --out "$T/ev-r" --keep-iso)"
rc=$?; [ "$rc" = 0 ] && ok "apply 退出码 0" || bad "apply rc=$rc：$OUT"
has "$OUT" "回读校验通过" "apply 回读 cmp 通过"
if [ -f "$T/dev-r.bin" ]; then ok "假设备已写入数据"; else bad "假设备没有数据"; fi
ISO="$(find "$T/stage-r" -name '*.iso' | head -1)"
if [ -n "$ISO" ] && cmp -s "$ISO" "$T/dev-r.bin"; then ok "盘上数据与 ISO 逐字节一致"; else bad "盘上数据与 ISO 不一致"; fi
[ -f "$T/ev-r/disc1-MANIFEST.sha256" ] && ok "证据含 MANIFEST" || bad "证据缺 MANIFEST"
[ -f "$T/ev-r/disc1-iso.sha256" ] && ok "证据含 ISO sha256" || bad "证据缺 ISO sha256"
grep -q 'rdsh-dvd|burn' "$T/journal.log" 2>/dev/null && ok "journal 已记账" || bad "journal 无记录"

echo '--- 6) 负样本：用过的 DVD+R / CD-R / RW+refuse 必须失败 ---'
OUT="$(FAKE_MEDIA=dvd+r-used plugin_direct burn "$T/src" --device "$T/dev-x.bin" --apply --stage "$T/stage-x")"; rc=$?
[ "$rc" != 0 ] && has "$OUT" "不是空白" "用过的 DVD+R 被拒绝" || bad "用过的 DVD+R 未被拒绝"
OUT="$(FAKE_MEDIA=cd plugin_direct burn "$T/src" --device "$T/dev-x.bin" --apply --stage "$T/stage-x")"; rc=$?
[ "$rc" != 0 ] && has "$OUT" "不支持的介质类型" "CD-R 被拒绝" || bad "CD-R 未被拒绝"
rm -f "$T/rw.state"
OUT="$(FAKE_MEDIA=dvd+rw-used FAKE_STATE="$T/rw.state" plugin_direct burn "$T/src" --device "$T/dev-x.bin" --apply --rw-policy refuse --stage "$T/stage-x")"; rc=$?
[ "$rc" != 0 ] && has "$OUT" "refuse" "RW 非空白 + refuse 被拒绝" || bad "RW 非空白 + refuse 未被拒绝"

echo '--- 7) RW：非空白 + auto 应先格式化再刻 ---'
rm -f "$T/rw.state"; rm -f "$T/dev-rw.bin"
OUT="$(FAKE_MEDIA=dvd+rw-used FAKE_STATE="$T/rw.state" plugin_direct burn "$T/src" \
      --device "$T/dev-rw.bin" --apply --stage "$T/stage-rw" --out "$T/ev-rw")"
rc=$?; [ "$rc" = 0 ] && ok "RW auto 刻录成功" || bad "RW auto rc=$rc：$OUT"
has "$OUT" "格式化" "RW 先执行了格式化"
[ -f "$T/rw.state" ] && ok "格式化标记已写入" || bad "格式化未执行"

echo '--- 8) backup：rsync 快照 + plan（隔离 rdsh 数据） ---'
mkdir -p "$B/.dsh-suite/data/0.1/sessions" "$B/.dsh-suite/state"
dd if=/dev/urandom of="$B/.dsh-suite/data/0.1/sessions/s1.jsonl" bs=100K count=1 status=none
echo kv > "$B/.dsh-suite/state/versions.kv"
OUT="$(plugin_json backup --scope data --disc-size 1M --reserve 0 --plan-only --json)"
rc=$?; python3 - "$OUT" <<'PY' && ok "backup plan 含 data 快照" || bad "backup plan 错误"
import json,sys
p=json.loads(sys.argv[1]); files=[f["path"] for d in p["discs"] for f in d["files"]]
assert any(x.startswith("data/0.1/sessions/s1.jsonl") for x in files), files
assert any(x.startswith("meta/BACKUP.json") for x in files), files
PY

echo
printf 'smoke-dvd：%d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
