#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
#  rdsh-dvd.py —— 通用 DVD±R/RW 数据刻录（rdsh 外部能力）
#
#  目标（用户 2026-11-01）：把 semester 用的刻录脚本泛化：
#    · 通用场景：任意目录/文件 → 容量分析 → 多盘切分 → ISO → 刻录 → 回读校验；
#    · 支持 DVD+R / DVD-R / DVD+RW / DVD-RW；
#    · rdsh 数据的一键刻录备份（rsync 快照后刻盘）；
#    · 作为 rdsh 外部能力：`rdsh dvd …`，并自动进 `rdsh bridge --spec`。
#
#  安全默认：burn / backup 默认 --dry-run（只造 ISO、核对、不落盘）；真刻录要 --apply。
#  写坏/写旧的一次性盘绝不覆盖；RW 盘按 --rw-policy 决定是否格式化再利用。
#
#  依赖：xorriso / growisofs / dvd+rw-mediainfo（RW 还要 dvd+rw-format），
#        以及 blockdev / cmp / sha256sum / rsync（备份用）。全部为系统自带。
#
#  用法见 --help；证据（manifest / ISO sha256 / 日志 / summary）落
#  $RDSH_BACKUP_ROOT/dvd-<时间戳>/ 并追加到 $RDSH_JOURNAL。
# =============================================================================
from __future__ import annotations

import argparse
import datetime as _dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat as _stat
import subprocess
import sys
import tempfile
import time

VERSION = "0.1.0"
TOOL = "x-rdsh-dvd"
PROG = "rdsh-dvd"
IFACE = 1

# ---------------- 根目录解析 ----------------
# 原则：**不复制 rdsh 的默认路径**。被 rdsh 调用时环境里已有全部根；
# 直接运行时向 rdsh 要（`rdsh base --json`），其次读配置文件，最后明确报错。
def _fatal(msg: str, code: int = 2) -> "None":
    print(f"[rdsh-dvd!] {msg}", file=sys.stderr)
    sys.exit(code)


def _expand(p: str) -> str:
    p = p.strip().strip('"').strip("'")
    return os.path.expanduser(p) if p else ""


def _cfg_path() -> str:
    return os.environ.get("RDSH_CONFIG") or os.path.join(os.path.expanduser("~"), ".config", "rdsh", "config")


def _cfg_get(key: str) -> str:
    cfg = _cfg_path()
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"\s*" + re.escape(key) + r"\s*=\s*(.*?)\s*$", line)
                if m:
                    v = _expand(m.group(1))
                    if v:
                        return v
    except OSError:
        pass
    return ""


def _query_rdsh_paths() -> dict:
    """向 rdsh 要已解析的根（唯一真相源）；拿不到就返回空 dict。"""
    rd = shutil.which("rdsh")
    if not rd:
        return {}
    try:
        p = subprocess.run([rd, "base", "--json"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if p.returncode != 0:
        return {}
    try:
        d = json.loads(p.stdout)
    except json.JSONDecodeError:
        return {}
    return d if isinstance(d, dict) else {}


# 被 rdsh 调用时 plugin_env 已导出全部根，不必再问；否则问一次 rdsh。
_ENV_ROOTS = ("RDSH_DATA_ROOT", "RDSH_SHARED_ROOT", "RDSH_STATE_ROOT",
              "RDSH_PLUGIN_ROOT", "RDSH_PATCHES_ROOT", "RDSH_BACKUP_ROOT")
_PATHS = {} if all(os.environ.get(k) for k in _ENV_ROOTS) else _query_rdsh_paths()

BASE = _expand(os.environ.get("RDSH_BASE") or _PATHS.get("base") or _cfg_get("BASE"))
# `--manifest` / `--help` 是**元数据查询**，不该要求 BASE 存在（CI 干净环境/任意 clone 都能读清单）。
_BASE_OPTIONAL = len(sys.argv) >= 2 and sys.argv[1] in ("--manifest", "manifest", "--help", "-h")
if not BASE:
    if _BASE_OPTIONAL:
        BASE = "/nonexistent"
    else:
        _fatal("无法确定 rdsh 的 BASE：请通过 `rdsh dvd …` 调用，或设置 RDSH_BASE，"
               "或提供 rdsh 配置文件；本工具不再假设 ~/Mapp。")
if not _BASE_OPTIONAL and not os.path.isdir(BASE):
    _fatal(f"rdsh 的 BASE 不存在：{BASE}。请先运行 `rdsh base` 检查配置，"
           "或显式设置 RDSH_BASE；本工具不再假设 ~/Mapp。")

SUITE = os.path.join(BASE, ".dsh-suite")


def _root(env: str, key: str, *fallback: str) -> str:
    return (_expand(os.environ.get(env) or _PATHS.get(key) or "")
            or os.path.join(*fallback))


DATA_ROOT = _root("RDSH_DATA_ROOT", "dataRoot", SUITE, "data")
SHARED_ROOT = _root("RDSH_SHARED_ROOT", "sharedRoot", SUITE, "shared")
STATE_ROOT = _root("RDSH_STATE_ROOT", "stateRoot", SUITE, "state")
PLUGIN_ROOT = _root("RDSH_PLUGIN_ROOT", "pluginRoot", SUITE, "plugins")
PATCHES_ROOT = _root("RDSH_PATCHES_ROOT", "patchesRoot", SUITE, "patches")
BACKUP_ROOT = _root("RDSH_BACKUP_ROOT", "backupRoot", SUITE, "backup")
LOG_DIR = _root("RDSH_LOG_DIR", "logDir", SUITE, "logs")
JOURNAL = _expand(os.environ.get("RDSH_JOURNAL") or "") or os.path.join(STATE_ROOT, "journal.log")
CONFIG_FILE = _cfg_path()

DEFAULT_DEV = os.environ.get("RDSH_DVD_DEVICE", "/dev/sr0")
DEFAULT_SPEED = 8
DEFAULT_RESERVE = 32 * 1024 * 1024       # 32 MiB：给 ISO 系统区/目录区/元文件留余量
RW_REPORTED_TYPES = {"DVD+R", "DVD-R", "DVD+RW", "DVD-RW"}   # 支持刻录的类型
REWRITABLE = {"DVD+RW", "DVD-RW", "DVD-RAM"}


# ---------------- 输出 ----------------
def log(*a) -> None:
    print("[rdsh-dvd]", *a, file=sys.stderr)


def warn(*a) -> None:
    print("[rdsh-dvd!]", *a, file=sys.stderr)


def die(msg: str, code: int = 1) -> "None":
    print(f"[rdsh-dvd!] {msg}", file=sys.stderr)
    sys.exit(code)


def fmt_bytes(n: int | None) -> str:
    if n is None:
        return "?"
    v = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(v) < 1024 or unit == "TiB":
            return f"{v:.1f} {unit}" if unit != "B" else f"{int(v)} B"
        v /= 1024
    return f"{n} B"


_SIZE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([KMGTP]?)i?B?\s*$", re.I)


def parse_size(s: str | None) -> int | None:
    if s is None:
        return None
    if isinstance(s, int):
        return s
    m = _SIZE_RE.match(s)
    if not m:
        raise argparse.ArgumentTypeError(f"无法解析容量：{s}（示例：4482M / 4700372992）")
    val = float(m.group(1))
    unit = (m.group(2) or "").upper()
    mult = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3,
            "T": 1024 ** 4, "P": 1024 ** 5}[unit]
    return int(val * mult)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------- 命令执行 ----------------
def _which(cmd: str) -> str:
    p = shutil.which(cmd)
    if not p:
        die(f"缺少依赖命令：{cmd}（请先安装）")
    return p


def run_capture(cmd: list[str], timeout: int | None = None) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=timeout)
    except FileNotFoundError:
        die(f"命令不存在：{cmd[0]}")
    except subprocess.TimeoutExpired:
        return 124, f"超时：{' '.join(cmd)}"
    return p.returncode, p.stdout or ""


def run_stream(cmd: list[str], logpath: str | None = None) -> int:
    """把命令输出（stdout+stderr）实时打到 stderr 并落日志。"""
    lf = open(logpath, "ab") if logpath else None
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             bufsize=0)
        assert p.stdout is not None
        while True:
            chunk = p.stdout.read(4096)
            if not chunk:
                break
            if lf:
                lf.write(chunk)
                lf.flush()
            sys.stderr.write(chunk.decode("utf-8", "replace").replace("\r", "\n"))
            sys.stderr.flush()
        return p.wait()
    finally:
        if lf:
            lf.close()


# ---------------- 光驱 / 介质探测 ----------------
def _ioctl_drive_status(dev: str) -> int | None:
    """CDROM_DRIVE_STATUS：0 no info / 1 no disc / 2 tray open / 3 not ready / 4 disc ok"""
    try:
        fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        return int(fcntl.ioctl(fd, 0x5326, 0))
    except OSError:
        return None
    finally:
        os.close(fd)


def _dev_size(dev: str) -> int:
    try:
        st = os.stat(dev)
        if _stat.S_ISREG(st.st_mode):
            return st.st_size
    except OSError:
        pass
    rc, out = run_capture(["blockdev", "--getsize64", dev])
    if rc == 0 and out.strip().isdigit():
        return int(out.strip())
    return 0


def probe_media(dev: str) -> dict:
    info: dict = {
        "device": dev, "present": False, "media": None, "status": None,
        "capacityBytes": None, "freeBytes": None, "formatCapacityBytes": None, "rewritable": False,
        "writeOnce": False, "supported": False, "tray": "unknown",
        "bookType": None, "mediaId": None, "writeSpeed": None, "model": None,
        "driveStatus": _ioctl_drive_status(dev), "deviceBytes": 0,
    }
    ds = info["driveStatus"]
    if ds == 1:
        info["tray"] = "no-disc"
    elif ds == 2:
        info["tray"] = "open"
    elif ds == 3:
        info["tray"] = "not-ready"
    elif ds == 4:
        info["tray"] = "disc-ok"

    if not shutil.which("dvd+rw-mediainfo"):
        die("缺少依赖命令：dvd+rw-mediainfo（dvd+rw-tools）")
    rc, out = run_capture(["dvd+rw-mediainfo", dev], timeout=30)
    if rc != 0 or "no media mounted" in out or "Mounted Media:" not in out:
        info["deviceBytes"] = _dev_size(dev)
        return info

    m = re.search(r"^\s*Mounted Media:\s+\S+,\s*(.+?)\s*$", out, re.M)
    if m:
        info["media"] = m.group(1).strip()
    m = re.search(r"^\s*Disc status:\s*(.+?)\s*$", out, re.M)
    if m:
        info["status"] = m.group(1).strip()
    m = re.search(r"^\s*Free Blocks:\s*(\d+)\*2KB", out, re.M)
    if m:
        info["freeBytes"] = int(m.group(1)) * 2048
    m = re.search(r"^\s*formatted:\s*(\d+)\*2048", out, re.M)
    if m:
        info["formatCapacityBytes"] = int(m.group(1)) * 2048
    m = re.search(r"^\s*Media Book Type:\s*(.+?)\s*$", out, re.M)
    if m:
        info["bookType"] = m.group(1).strip()
    m = re.search(r"^\s*Media ID:\s*(.+?)\s*$", out, re.M)
    if m:
        info["mediaId"] = m.group(1).strip()
    m = re.search(r"^\s*Current Write Speed:\s*(.+?)\s*$", out, re.M)
    if m:
        info["writeSpeed"] = m.group(1).strip()
    m = re.search(r"INQUIRY:\s*\[(.*?)\]\s*\[(.*?)\]", out)
    if m:
        info["model"] = f"{m.group(1).strip()} {m.group(2).strip()}".strip()

    info["present"] = bool(info["media"])
    media = (info["media"] or "").upper()
    info["supported"] = media in RW_REPORTED_TYPES
    info["rewritable"] = media in REWRITABLE
    info["writeOnce"] = media in {"DVD+R", "DVD-R"}
    if info["freeBytes"] and info["freeBytes"] > 0:
        info["capacityBytes"] = info["freeBytes"]
    elif info.get("formatCapacityBytes"):
        info["capacityBytes"] = info["formatCapacityBytes"]
    info["deviceBytes"] = _dev_size(dev)
    return info


def _wait_for_media(dev: str, timeout: int, purpose: str = "空白 DVD±R/RW") -> dict:
    deadline = time.time() + max(0, timeout)
    last = 0.0
    while True:
        info = probe_media(dev)
        if info["present"]:
            return info
        now = time.time()
        if now - last >= 10:
            if info["tray"] == "open":
                log(f"等待介质：光驱托盘是弹开的，请推回（目标：{purpose}）……")
            else:
                log(f"等待介质：请放入{purpose}（设备 {dev}）……")
            last = now
        if now >= deadline:
            die(f"超时：没有检测到光盘。请放入{purpose}后重跑，或用 --wait-media 加长等待。")
        time.sleep(2)


def _unmount_device(dev: str) -> None:
    """真盘可能被桌面自动挂载；格式化/刻录前尽力卸载（失败不致命）。"""
    if not shutil.which("udisksctl"):
        return
    for args in (["udisksctl", "unmount", "-b", dev],
                 ["udisksctl", "unmount", "-b", dev, "--force"]):
        rc, _ = run_capture(args)
        if rc == 0:
            return


def _format_rw(dev: str, logpath: str) -> None:
    if not shutil.which("dvd+rw-format"):
        die("介质是可擦写盘，但缺少 dvd+rw-format（dvd+rw-tools）")
    log("可擦写盘不是空白：按 --rw-policy=auto 做格式化（dvd+rw-format -force）……")
    _unmount_device(dev)
    rc = run_stream(["dvd+rw-format", "-force", dev], logpath)
    if rc != 0:
        die(f"格式化失败（rc={rc}）。可擦写盘可能已损坏；详见 {logpath}")


def ensure_writable_media(dev: str, args, logpath: str) -> tuple[dict, int]:
    """等到可写介质；必要时格式化 RW。返回 (info, capacity_bytes)。"""
    timeout = args.wait_media if args.wait_media is not None else (
        600 if sys.stdin.isatty() else 20)
    info = _wait_for_media(dev, timeout)
    media = (info["media"] or "").upper()
    if not info["supported"]:
        die(f"不支持的介质类型：{info['media']}（本工具只支持 DVD+R / DVD-R / DVD+RW / DVD-RW）")
    status = (info["status"] or "").lower()
    if status == "blank":
        cap = info["capacityBytes"]
        if not cap:
            die("盘是空白盘，但读不到可写容量（驱动异常？）")
        return info, cap
    if info["rewritable"]:
        if args.rw_policy == "refuse":
            die(f"介质 {media} 不是空白（status={status}），且 --rw-policy=refuse。"
                "请换空白盘，或改 --rw-policy=auto 让它先格式化。")
        if getattr(args, "_preformatted", False) and info["capacityBytes"]:
            return info, int(info["capacityBytes"])
        _format_rw(dev, logpath)
        info = probe_media(dev)
        cap = info["capacityBytes"]
        if not info["present"] or not cap:
            die("格式化后仍读不到可用容量；这张可擦写盘可能不可用")
        return info, cap
    die(f"一次性写入介质 {media} 不是空白（status={status}）：不能覆盖。请换一张空白盘。")


# ---------------- 扫描与分盘 ----------------
def _iter_files(src: str):
    """产出 (relpath, abspath, size)；**不跟随符号链接**（避免 node_modules 之类的链接把盘撑爆），
    只收普通文件；符号链接记一条警告后跳过。"""
    src = os.path.abspath(src)
    st = os.stat(src)          # 直接给的文件参数若是符号链接，按目标处理（用户点名要它）
    if _stat.S_ISREG(st.st_mode):
        yield os.path.basename(src), src, st.st_size
        return
    if not os.path.isdir(src):
        die(f"源不是普通文件或目录：{src}")
    base = os.path.basename(src.rstrip(os.sep)) or "root"
    skipped_links = 0
    stack: list[tuple[str, str]] = [("", src)]
    while stack:
        relbase, path = stack.pop()
        try:
            entries = sorted(os.scandir(path), key=lambda e: e.name)
        except OSError as e:
            die(f"读目录失败：{path}（{e}）")
        for ent in entries:
            p = os.path.join(path, ent.name)
            rel = os.path.join(relbase, ent.name) if relbase else ent.name
            if ent.is_symlink():
                skipped_links += 1
                continue
            try:
                if ent.is_dir(follow_symlinks=False):
                    stack.append((rel, p))
                elif ent.is_file(follow_symlinks=False):
                    yield os.path.join(base, rel), p, ent.stat(follow_symlinks=False).st_size
            except OSError:
                continue
    if skipped_links:
        warn(f"跳过 {skipped_links} 个符号链接（不跟随，避免把链接目标整棵树带上盘）：{src}")


def scan_sources(sources: list[str]) -> list[dict]:
    groups: list[dict] = []
    used_names: set[str] = set()
    for src in sources:
        if not os.path.exists(src):
            die(f"源不存在：{src}")
        files = list(_iter_files(src))
        if not files:
            warn(f"跳过空源：{src}")
            continue
        name = os.path.basename(os.path.abspath(src).rstrip(os.sep)) or "root"
        base = name
        n = 2
        while name in used_names:
            name = f"{base}-{n}"
            n += 1
        used_names.add(name)
        # 用 name 替换 _iter_files 给出的顶层目录名
        fixed = []
        for rel, ap, size in files:
            parts = rel.split(os.sep, 1)
            if len(parts) == 2:
                rel2 = os.path.join(name, parts[1])
            else:
                rel2 = name if not src.endswith(os.sep) else name
            fixed.append((rel2, ap, size))
        groups.append({
            "name": name, "source": os.path.abspath(src),
            "files": [{"path": r, "src": a, "size": s} for r, a, s in fixed],
            "bytes": sum(s for _, _, s in fixed),
        })
    if not groups:
        die("没有可刻录的文件（源为空？）")
    return groups


def _place_file(bins: list[dict], f: dict, budget: int) -> None:
    for b in bins:
        if b["bytes"] + f["size"] <= budget:
            b["files"].append(f)
            b["bytes"] += f["size"]
            return
    bins.append({"files": [f], "bytes": f["size"]})


def pack_groups(groups: list[dict], capacity: int, reserve: int, mode: str) -> list[dict]:
    budget = capacity - reserve
    if budget <= 0:
        die(f"单盘可用空间不足：容量 {fmt_bytes(capacity)} - 预留 {fmt_bytes(reserve)} ≤ 0")
    bins: list[dict] = []
    if mode == "file":
        allfiles = [f for g in groups for f in g["files"]]
        for f in sorted(allfiles, key=lambda x: x["size"], reverse=True):
            if f["size"] > budget:
                die(f"单个文件超过单盘可用空间：{f['path']}（{fmt_bytes(f['size'])}）")
            _place_file(bins, f, budget)
    else:
        for g in sorted(groups, key=lambda x: x["bytes"], reverse=True):
            if g["bytes"] <= budget:
                placed = False
                for b in bins:
                    if b["bytes"] + g["bytes"] <= budget:
                        b["files"].extend(g["files"])
                        b["bytes"] += g["bytes"]
                        placed = True
                        break
                if not placed:
                    bins.append({"files": list(g["files"]), "bytes": g["bytes"]})
            else:
                for f in sorted(g["files"], key=lambda x: x["size"], reverse=True):
                    if f["size"] > budget:
                        die(f"单个文件超过单盘可用空间：{f['path']}（{fmt_bytes(f['size'])}）")
                    _place_file(bins, f, budget)
    for b in bins:
        b["files"].sort(key=lambda f: f["path"])
    return bins


def build_plan(sources: list[str], capacity: int, reserve: int, mode: str,
               volume_prefix: str, label_prefix: str) -> dict:
    groups = scan_sources(sources)
    total = sum(g["bytes"] for g in groups)
    bins = pack_groups(groups, capacity, reserve, mode)
    stamp = _dt.datetime.now().strftime("%Y%m%d")
    prefix = re.sub(r"[^A-Za-z0-9_]", "_", volume_prefix or "RDVD").upper()
    prefix = (prefix + "_" + stamp)[:26]
    discs = []
    for i, b in enumerate(bins, 1):
        vol = re.sub(r"[^A-Z0-9_]", "_", f"{prefix}_D{i}")[:32]
        discs.append({
            "index": i, "volumeId": vol,
            "label": f"{label_prefix} {i}/{len(bins)}",
            "bytes": b["bytes"], "files": b["files"],
        })
    return {
        "schema": 1, "tool": PROG, "version": VERSION,
        "generatedAt": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "capacityBytes": capacity, "reserveBytes": reserve, "pack": mode,
        "sources": [os.path.abspath(s) for s in sources],
        "totalBytes": total, "discCount": len(discs), "discs": discs,
    }


def plan_table(plan: dict) -> str:
    lines = [
        f"单盘容量 {fmt_bytes(plan['capacityBytes'])}，预留 {fmt_bytes(plan['reserveBytes'])}，"
        f"共 {plan['totalBytes'] if 'totalBytes' in plan else sum(d['bytes'] for d in plan['discs'])}，"
        f"分 {len(plan['discs'])} 张（pack={plan['pack']}）",
        f"{'盘':>3}  {'文件数':>6}  {'数据量':>12}  {'填充率':>6}  内容",
        "-" * 72,
    ]
    cap = max(1, plan["capacityBytes"] - plan["reserveBytes"])
    for d in plan["discs"]:
        tops = sorted({f["path"].split(os.sep)[0] for f in d["files"]})
        shown = "、".join(tops[:4]) + ("…" if len(tops) > 4 else "")
        lines.append(f"{d['index']:>3}  {len(d['files']):>6}  {fmt_bytes(d['bytes']):>12}  "
                     f"{d['bytes'] / cap * 100:>5.1f}%  {shown}")
    lines.append("-" * 72)
    for d in plan["discs"]:
        lines.append(f"  第 {d['index']} 张：卷标 {d['volumeId']}；标签「{d['label']}」")
    return "\n".join(lines)


# ---------------- ISO 构建与内容核对 ----------------
def _stage_tree(disc: dict, tree: str) -> None:
    os.makedirs(tree, exist_ok=True)
    for f in disc["files"]:
        dst = os.path.join(tree, f["path"])
        src = f["src"]
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            st = os.stat(src)
            if st.st_size != f["size"]:
                die(f"源文件大小已变化：{src}（计划 {f['size']}，现在 {st.st_size}）")
            real = os.path.realpath(src)
            try:
                os.link(real, dst)
            except OSError:
                shutil.copy2(real, dst)
        except FileNotFoundError:
            die(f"源文件不见了：{src}")


def _manifest_of_tree(tree: str, out_path: str) -> tuple[int, int]:
    files: list[tuple[str, int]] = []
    for root, _dirs, names in os.walk(tree):
        for n in names:
            p = os.path.join(root, n)
            if not os.path.isfile(p):
                continue
            rel = os.path.relpath(p, tree)
            files.append((rel, os.path.getsize(p)))
    files.sort(key=lambda x: x[0])
    with open(out_path, "w", encoding="utf-8") as fh:
        for rel, _size in files:
            fh.write(f"{sha256_file(os.path.join(tree, rel))}  {rel}\n")
    return len(files), sum(s for _, s in files)


def _write_readme(tree: str, plan: dict, disc: dict, extra_note: str = "") -> str:
    path = os.path.join(tree, "00-本盘说明.txt")
    tops = sorted({f["path"].split(os.sep)[0] for f in disc["files"]})
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"{disc['label']}\n")
        fh.write(f"刻录日期：{_dt.datetime.now():%Y-%m-%d %H:%M:%S %z}\n")
        fh.write(f"卷标：{disc['volumeId']}\n")
        fh.write(f"本盘文件：{len(disc['files'])} 个；数据量：{disc['bytes']} 字节\n")
        fh.write(f"内容顶层目录：{'、'.join(tops)}\n")
        fh.write("\n校验：在本盘根目录执行  sha256sum -c MANIFEST.sha256\n")
        fh.write("说明：数据盘（m4a/文档等按原样存放）；普通 DVD 播放机不保证能播。\n")
        fh.write(f"工具：{PROG} {VERSION}\n")
        if extra_note:
            fh.write(f"\n{extra_note}\n")
    return path


def _iso_listing(iso: str) -> tuple[int, int]:
    rc, out = run_capture(["xorriso", "-indev", iso, "-find", "/", "-type", "f",
                           "-exec", "lsdl"], timeout=300)
    if rc != 0:
        die(f"读取 ISO 失败（rc={rc}）：{iso}")
    count = 0
    total = 0
    for line in out.splitlines():
        if not line.startswith("-"):
            continue
        m = re.match(r"^\S+\s+\d+\s+\d+\s+\d+\s+(\d+)\s", line)
        if m:
            count += 1
            total += int(m.group(1))
    return count, total


def build_iso(tree: str, iso: str, volume_id: str, logpath: str) -> int:
    rc = run_stream(["xorriso", "-as", "mkisofs", "-R", "-J", "-joliet-long",
                     "-V", volume_id, "-o", iso, tree], logpath)
    if rc != 0:
        die(f"造 ISO 失败（rc={rc}）；详见 {logpath}")
    return os.path.getsize(iso)


# ---------------- 证据 / 日志 ----------------
def _evidence_dir(args, stamp: str) -> str:
    if args.out:
        d = os.path.abspath(args.out)
    else:
        d = os.path.join(BACKUP_ROOT, f"dvd-{stamp}")
    os.makedirs(d, exist_ok=True)
    return d


def journal(action: str, obj: str, note: str) -> None:
    try:
        os.makedirs(os.path.dirname(JOURNAL), exist_ok=True)
        with open(JOURNAL, "a", encoding="utf-8") as fh:
            fh.write(f"{_dt.datetime.now().astimezone().isoformat(timespec='seconds')}"
                     f"|rdsh-dvd|{action}|{obj} note={note}\n")
    except OSError:
        warn(f"写 journal 失败（不影响刻录）：{JOURNAL}")


# ---------------- 单盘刻录 ----------------
def _make_stage(args, prefix: str) -> str:
    """建本次运行的暂存目录：--stage 下新建子目录，绝不删用户给的目录本身。"""
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    if args.stage:
        base = os.path.abspath(args.stage)
        os.makedirs(base, exist_ok=True)
        return os.path.join(base, f"run-{stamp}")
    parent = SUITE if os.path.isdir(SUITE) else None
    return tempfile.mkdtemp(prefix=f"{prefix}-", dir=parent)


def burn_one(plan: dict, disc: dict, args, dry: bool, stage_root: str,
             plan_path: str | None, extra_note: str = "") -> dict:
    n = disc["index"]
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    work = os.path.join(stage_root, f"d{n}")
    shutil.rmtree(work, ignore_errors=True)
    tree = os.path.join(work, "tree")
    os.makedirs(tree, exist_ok=True)
    iso = os.path.join(work, f"{disc['volumeId']}.iso")
    build_log = os.path.join(work, "build.log")
    burn_log = os.path.join(work, "burn.log")

    def cleanup_work() -> None:
        if not args.keep_iso:
            shutil.rmtree(work, ignore_errors=True)

    # 空间预检：ISO 约等于内容量；若源与暂存不同文件系统，还要再复制一份
    stage_dev = os.stat(work).st_dev
    need = disc["bytes"] + 256 * 1024 * 1024
    for f in disc["files"]:
        try:
            if os.stat(f["src"]).st_dev != stage_dev:
                need += disc["bytes"]
                break
        except OSError:
            continue
    free = shutil.disk_usage(work).free
    if free < need:
        die(f"暂存空间不足：需要 {fmt_bytes(need)}，可用 {fmt_bytes(free)}（暂存 {work}）")

    log(f"=== 第 {n}/{len(plan['discs'])} 张：{disc['label']}（{len(disc['files'])} 个文件，"
        f"{fmt_bytes(disc['bytes'])}） ===")

    # 1) 真实刻录前先确认介质（容量/是否空白/是否要格式化）
    cap = plan["capacityBytes"]
    media = None
    if not dry:
        media, cap = ensure_writable_media(args.device, args, burn_log)
        if disc["bytes"] > cap:
            die(f"本盘内容 {fmt_bytes(disc['bytes'])} 超过介质可用容量 {fmt_bytes(cap)}")

    # 2) 暂存树（硬链接；跨文件系统才复制）
    _stage_tree(disc, tree)
    manifest_path = os.path.join(tree, "MANIFEST.sha256")
    content_count, content_bytes = _manifest_of_tree(tree, manifest_path)
    _write_readme(tree, plan, disc, extra_note)
    readme_size = os.path.getsize(os.path.join(tree, "00-本盘说明.txt"))
    manifest_size = os.path.getsize(manifest_path)
    want_count = content_count + 2
    want_bytes = content_bytes + readme_size + manifest_size
    log(f"暂存完成：{content_count} 个内容文件，{fmt_bytes(content_bytes)}；生成 MANIFEST 与说明")

    # 3) ISO
    iso_size = build_iso(tree, iso, disc["volumeId"], build_log)
    if iso_size > cap:
        die(f"ISO {fmt_bytes(iso_size)} 超过盘可用容量 {fmt_bytes(cap)}；请重新 plan（--reserve 加大）")
    count, total = _iso_listing(iso)
    if count != want_count or total != want_bytes:
        die(f"ISO 内容不符：ISO 内 {count} 个 / {total} B，应为 {want_count} 个 / {want_bytes} B")
    log(f"ISO 已生成并核对通过：{iso}（{fmt_bytes(iso_size)}）")

    result = {
        "index": n, "volumeId": disc["volumeId"], "label": disc["label"],
        "files": content_count, "bytes": content_bytes, "iso": iso,
        "isoBytes": iso_size, "isoSha256": None, "verify": "dry-run" if dry else "pending",
    }

    if dry:
        log("[dry-run] 未刻录（加 --apply 才真刻录）。")
        if not args.keep_iso:
            cleanup_work()
        else:
            result["isoSha256"] = sha256_file(iso)
        return result

    # 4) 刻录
    if media is None:
        media, cap = ensure_writable_media(args.device, args, burn_log)
    log(f"开始刻录：{media['media']}，{fmt_bytes(cap)} 可用，速度 {args.speed}x ……")
    _unmount_device(args.device)
    rc = run_stream(["growisofs", "-dvd-compat", f"-speed={args.speed}",
                     "-Z", f"{args.device}={iso}"], burn_log)
    if rc != 0:
        die(f"刻录失败（rc={rc}）。这张盘请作废；ISO 保留在 {iso}；详见 {burn_log}")

    # 5) 等介质就绪（growisofs 可能把托盘留在弹开状态），再逐字节回读校验
    log("等待光盘就绪后做回读校验……")
    timeout = args.wait_tray if args.wait_tray is not None else 240
    deadline = time.time() + timeout
    last = 0.0
    while True:
        info = probe_media(args.device)
        if info["present"] and _dev_size(args.device) > 0:
            break
        now = time.time()
        if now - last >= 10:
            if info["tray"] == "open":
                log("光驱托盘是弹开的：请把托盘推回（盘留在光驱里），脚本会自动继续。")
            last = now
        if now >= deadline:
            die(f"等待介质就绪超时（{timeout}s）。盘可能已经刻好但未校验；ISO 保留在 {iso}")
        time.sleep(2)

    result["verify"] = "ok"
    if not args.no_verify:
        iso_bytes = os.path.getsize(iso)
        ok = False
        for attempt in range(1, 4):
            rc, out = run_capture(["cmp", "-n", str(iso_bytes), iso, args.device], timeout=1200)
            if rc == 0:
                ok = True
                break
            if attempt < 3:
                log(f"第 {attempt} 次回读比较未通过，5 秒后重试……")
                time.sleep(5)
        if not ok:
            die(f"回读校验失败：盘上数据与 ISO 不一致。ISO 保留在 {iso}")
        log("回读校验通过（逐字节一致）")
    else:
        warn("按 --no-verify 跳过了回读校验（不推荐）")
        result["verify"] = "skipped"

    # 6) 证据
    ev = _evidence_dir(args, stamp)
    shutil.copy2(manifest_path, os.path.join(ev, f"disc{n}-MANIFEST.sha256"))
    shutil.copy2(os.path.join(tree, "00-本盘说明.txt"), os.path.join(ev, f"disc{n}-README.txt"))
    shutil.copy2(build_log, os.path.join(ev, f"disc{n}-build.log"))
    shutil.copy2(burn_log, os.path.join(ev, f"disc{n}-burn.log"))
    iso_sha = sha256_file(iso)
    result["isoSha256"] = iso_sha
    with open(os.path.join(ev, f"disc{n}-iso.sha256"), "w", encoding="utf-8") as fh:
        fh.write(f"{iso_sha}  {disc['volumeId']}.iso\n")
    if plan_path:
        shutil.copy2(plan_path, os.path.join(ev, "plan.json"))
    else:
        with open(os.path.join(ev, "plan.json"), "w", encoding="utf-8") as fh:
            json.dump(plan, fh, ensure_ascii=False, indent=2)
    journal("burn", f"disc{n}", (f"label={disc['label']} media={media['media']} "
                                 f"bytes={iso_size} iso_sha256={iso_sha} verify={result['verify']} "
                                 f"out={ev}"))
    log(f"证据已保存：{ev}")

    sync_rc, _ = run_capture(["sync"])
    if not args.no_eject:
        rc, out = run_capture(["eject", args.device])
        if rc != 0:
            warn("自动弹出失败（可能有程序占用光驱，如 Wine/Proton 游戏）；请手动按弹出键")
    cleanup_work()
    return result


# ---------------- 子命令 ----------------
def cmd_probe(args) -> int:
    info = probe_media(args.device)
    if args.json:
        print(json.dumps(info, ensure_ascii=False, indent=2))
    else:
        print(f"设备：{args.device}")
        if not info["present"]:
            print("介质：无（光驱里没有盘，或托盘弹开 / 未就绪）")
            print(f"托盘：{info['tray']}")
            return 3
        cap = info["capacityBytes"]
        print(f"介质：{info['media']}（{info['mediaId'] or '?'}）")
        print(f"状态：{info['status']}    可擦写：{'是' if info['rewritable'] else '否'}"
              f"    可写：{'是' if info['supported'] else '否'}")
        print(f"容量：{fmt_bytes(cap) if cap else '未知（非空白介质需 --disc-size）'}")
        print(f"托盘：{info['tray']}    写入速度：{info['writeSpeed'] or '?'}    "
              f"Book：{info['bookType'] or '?'}")
        print(f"型号：{info['model'] or '?'}")
        if not info["supported"]:
            print("提示：本工具只支持 DVD+R / DVD-R / DVD+RW / DVD-RW。")
    return 0 if info["present"] else 3


def _load_plan(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        die(f"读 plan 失败：{path}（{e}）")
    if not isinstance(plan, dict) or not isinstance(plan.get("discs"), list):
        die(f"plan 格式不正确：{path}")
    return plan


def _select_discs(plan: dict, args) -> list[dict]:
    discs = plan["discs"]
    if getattr(args, "all", False):
        return discs
    n = getattr(args, "disc", None) or 1
    if n < 1 or n > len(discs):
        die(f"盘号越界：{n}（共 {len(discs)} 张）")
    return [discs[n - 1]]


def _detect_capacity(args, allow_format: bool) -> int:
    """确定单盘可用容量：--disc-size > 空白盘 Free Blocks > (apply 时) 格式化 RW 后再读。"""
    if args.disc_size:
        return args.disc_size
    info = probe_media(args.device)
    if not info["present"]:
        die("读不到单盘容量：没有介质。请放入空白盘，或用 --disc-size 指定（如 4482M）")
    media = (info["media"] or "").upper()
    if not info["supported"]:
        die(f"不支持的介质类型：{info['media']}（本工具只支持 DVD+R / DVD-R / DVD+RW / DVD-RW）")
    status = (info["status"] or "").lower()
    if status == "blank":
        if info["capacityBytes"]:
            return info["capacityBytes"]
        die("盘是空白盘，但读不到可写容量（驱动异常？）；可用 --disc-size 指定")
    if info["writeOnce"]:
        die(f"一次性写入介质 {media} 不是空白（status={status}）：不能覆盖，请换一张空白盘")
    if info["rewritable"]:
        if getattr(args, "rw_policy", "auto") == "refuse":
            die(f"可擦写介质 {media} 不是空白（status={status}），且 --rw-policy=refuse；"
                "请换空白盘或改 --rw-policy=auto")
        # 已格式化的 RW 能直接报出 formatted 容量：dry-run/plan 不必擦盘；
        # 真刻录时由 burn_one 的 ensure_writable_media 负责先格式化。
        if info["capacityBytes"]:
            return info["capacityBytes"]
        if not allow_format:
            die(f"可擦写介质 {media} 不是空白，且读不到 formatted 容量："
                "请用 --disc-size 指定，或加 --apply 让它先格式化（dry-run 不会擦盘）")
        warn(f"介质 {media} 不是空白（status={status}）且读不到 formatted 容量：先格式化……")
        _format_rw(args.device, None)
        setattr(args, "_preformatted", True)
        info = probe_media(args.device)
        if info["present"] and info["capacityBytes"]:
            return info["capacityBytes"]
        die("格式化后仍读不到可用容量；这张可擦写盘可能不可用")
    die(f"无法确定容量（media={info['media']} status={status}）；请用 --disc-size 指定")


def cmd_plan(args) -> int:
    cap = args.disc_size
    if cap is None:
        info = probe_media(args.device)
        if not info["present"]:
            die("没有介质，无法确定单盘容量：请放入空白 DVD 或用 --disc-size 指定（如 4482M）")
        if not info["capacityBytes"]:
            die("介质非空白，读不到容量：请用 --disc-size 指定（如 4482M）")
        cap = info["capacityBytes"]
    reserve = args.reserve if args.reserve is not None else DEFAULT_RESERVE
    sources = args.sources or []
    if not sources:
        die("plan 需要至少一个源路径（目录或文件）")
    plan = build_plan(sources, cap, reserve, args.pack,
                      args.volume_prefix or "RDVD", args.label_prefix or "DVD 数据盘")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(plan, fh, ensure_ascii=False, indent=2)
        log(f"plan 已写入：{args.out}")
    if args.json:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
    else:
        print(plan_table(plan))
    return 0


def cmd_burn(args) -> int:
    if args.apply and args.dry_run:
        die("--apply 与 --dry-run 不能同时用")
    dry = not args.apply
    sources = list(args.sources or [])
    plan_path = None
    if args.plan:
        plan = _load_plan(args.plan)
        plan_path = os.path.abspath(args.plan)
        if sources:
            die("给了 --plan 就不要再给源路径")
    else:
        if not sources:
            die("burn 需要源路径，或用 --plan <plan.json>")
        cap = _detect_capacity(args, allow_format=(not dry))
        reserve = args.reserve if args.reserve is not None else DEFAULT_RESERVE
        plan = build_plan(sources, cap, reserve, args.pack,
                          args.volume_prefix or "RDVD", args.label_prefix or "DVD 数据盘")
    if len(plan["discs"]) > 1 and args.disc is None and not args.all:
        die(f"计划共 {len(plan['discs'])} 张：请用 --all 依次刻，或用 --disc N 刻其中一张")
    discs = _select_discs(plan, args)
    if len(discs) > 1 and not dry and args.wait_media is None and not sys.stdin.isatty():
        warn("多盘真实刻录时建议加 --wait-media 600；否则每张之间只等 20 秒")

    stage_parent = _make_stage(args, "rdsh-dvd")
    os.makedirs(stage_parent, exist_ok=True)
    extra_note = "本盘由 rdsh-dvd 生成；请在盘面写标签。"
    results = []
    ok = False
    try:
        for i, disc in enumerate(discs):
            if i > 0 and not dry:
                log(f"请换入第 {disc['index']} 张空白 DVD±R/RW；脚本会等待检测……")
            results.append(burn_one(plan, disc, args, dry, stage_parent, plan_path, extra_note))
        ok = True
    finally:
        if args.keep_iso or not ok:
            log(f"暂存/ISO 已保留：{stage_parent}")
        else:
            shutil.rmtree(stage_parent, ignore_errors=True)
    if args.json:
        print(json.dumps({"ok": True, "dryRun": dry, "device": args.device,
                          "plan": {"discCount": len(plan["discs"]),
                                   "capacityBytes": plan["capacityBytes"]},
                          "results": results}, ensure_ascii=False, indent=2))
    else:
        print(f"\n完成：{len(results)} 张（{'dry-run，未刻录' if dry else '已刻录并校验'}）")
    return 0


# ---------------- rdsh 数据备份 ----------------
def _scope_sources(args) -> list[tuple[str, str, str]]:
    """返回 [(name, path, kind)]；kind=dir/file。"""
    items: list[tuple[str, str, str]] = []

    def add(name: str, path: str, kind: str = "dir") -> None:
        if os.path.exists(path):
            items.append((name, path, kind))
        else:
            warn(f"跳过不存在的路径：{path}（{name}）")

    scope = args.scope
    add("data", DATA_ROOT)
    if scope == "suite":
        add("shared", SHARED_ROOT)
        add("state", STATE_ROOT)
        add("plugins", PLUGIN_ROOT)
        add("patches", PATCHES_ROOT)
        if args.with_backups:
            add("backup", BACKUP_ROOT)
        if args.with_logs:
            add("logs", LOG_DIR)
        if os.path.isfile(CONFIG_FILE):
            items.append(("config", CONFIG_FILE, "file"))
    if not items:
        die("没有可备份的 rdsh 路径；检查 RDSH_BASE / RDSH_* 环境")
    return items


def _snapshot(items: list[tuple[str, str, str]], snap: str) -> list[str]:
    os.makedirs(snap, exist_ok=True)
    if not shutil.which("rsync"):
        die("缺少 rsync（rdsh 数据快照需要）")
    total = 0
    for name, src, kind in items:
        dst = os.path.join(snap, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if kind == "file":
            if name == "config":
                sub = os.path.join(dst, "rdsh")
                os.makedirs(sub, exist_ok=True)
                shutil.copy2(src, os.path.join(sub, os.path.basename(src)))
            else:
                os.makedirs(dst, exist_ok=True)
                shutil.copy2(src, os.path.join(dst, os.path.basename(src)))
            total += os.path.getsize(src)
        else:
            os.makedirs(dst, exist_ok=True)
            rc = run_stream(["rsync", "-a", "--delete",
                             src.rstrip("/") + "/", dst + "/"])
            if rc != 0:
                die(f"rsync 快照失败：{src} → {dst}（rc={rc}）")
            for root, _d, names in os.walk(dst):
                for n in names:
                    p = os.path.join(root, n)
                    if os.path.isfile(p):
                        total += os.path.getsize(p)
    return [os.path.join(snap, n) for n, _s, _k in items]


def cmd_backup(args) -> int:
    if args.apply and args.dry_run:
        die("--apply 与 --dry-run 不能同时用")
    dry = not args.apply
    items = _scope_sources(args)
    cap = _detect_capacity(args, allow_format=(not dry))
    reserve = args.reserve if args.reserve is not None else DEFAULT_RESERVE

    stage_parent = _make_stage(args, "rdsh-dvd-bak")
    os.makedirs(stage_parent, exist_ok=True)
    snap = os.path.join(stage_parent, "snapshot")
    warn("备份内容包含 rdsh 数据（含会话/凭据等敏感数据）：盘面请标注，妥善保管。")
    if args.with_logs:
        warn("--with-logs 会带上 $SUITE/logs（含访问 token），请确认盘不会外流。")
    log("正在做 rsync 快照（非原子；建议先停掉正在写入的 dsh 实例）……")
    ok = False
    try:
        srcs = _snapshot(items, snap)
        # 元信息
        meta_dir = os.path.join(snap, "meta")
        os.makedirs(meta_dir, exist_ok=True)
        with open(os.path.join(meta_dir, "BACKUP.json"), "w", encoding="utf-8") as fh:
            json.dump({
                "schema": 1, "tool": PROG, "version": VERSION,
                "createdAt": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                "base": BASE, "scope": args.scope,
                "withBackups": bool(args.with_backups), "withLogs": bool(args.with_logs),
                "sources": [{"name": n, "path": s, "kind": k} for n, s, k in items],
                "note": "rsync snapshot (not atomic); symlinks preserved, not followed",
            }, fh, ensure_ascii=False, indent=2)
        srcs = [os.path.join(snap, n) for n, _s, _k in items] + [meta_dir]
        plan = build_plan(srcs, cap, reserve, args.pack,
                          args.volume_prefix or "RDSH", args.label_prefix or "rdsh 数据备份")
        if args.plan_only or dry:
            if args.json:
                print(json.dumps(plan, ensure_ascii=False, indent=2))
            else:
                print(plan_table(plan))
            log("[dry-run/plan-only] 只出计划，未刻录。")
            ok = True
            return 0
        if len(plan["discs"]) > 1 and args.disc is None and not args.all:
            die(f"计划共 {len(plan['discs'])} 张：请用 --all 依次刻，或用 --disc N 刻其中一张")
        if not args.json:
            print(plan_table(plan))
        # 真刻录：直接复用 burn 的流程
        stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        results = []
        for i, disc in enumerate(_select_discs(plan, args)):
            if i > 0:
                log(f"请换入第 {disc['index']} 张空白 DVD±R/RW；脚本会等待检测……")
            results.append(burn_one(plan, disc, args, False, stage_parent, None,
                                    "本盘为 rdsh 数据备份（含敏感数据），请妥善保管。"))
        if args.json:
            print(json.dumps({"ok": True, "dryRun": False, "scope": args.scope,
                              "results": results}, ensure_ascii=False, indent=2))
        ok = True
        return 0
    finally:
        if args.keep_iso or not ok:
            log(f"快照/暂存已保留：{stage_parent}")
        else:
            shutil.rmtree(stage_parent, ignore_errors=True)


# ---------------- 参数与入口 ----------------
def add_common(p: argparse.ArgumentParser, *, backup: bool = False) -> None:
    p.add_argument("--device", default=DEFAULT_DEV, help=f"光驱设备（默认 {DEFAULT_DEV}）")
    p.add_argument("--disc-size", type=parse_size, default=None,
                   help="单盘可用容量（字节或 4482M）；无空白盘时必填")
    p.add_argument("--reserve", type=parse_size, default=None,
                   help=f"每盘预留空间（默认 {DEFAULT_RESERVE // 1024 // 1024}M）")
    p.add_argument("--speed", type=int, default=DEFAULT_SPEED, help="刻录速度（默认 8）")
    p.add_argument("--pack", choices=["dir", "file"], default="dir",
                   help="分盘策略：dir=尽量整目录同盘（默认）/ file=按文件最佳填充")
    p.add_argument("--rw-policy", choices=["auto", "refuse"], default="auto",
                   help="可擦写盘非空白时：auto=先格式化（默认）/ refuse=报错")
    p.add_argument("--wait-media", type=int, default=None,
                   help="等待放入光盘的秒数（默认：TTY 600 / 非 TTY 20）")
    p.add_argument("--wait-tray", type=int, default=240,
                   help="刻完等待介质就绪（推回托盘）的秒数（默认 240）")
    p.add_argument("--no-verify", action="store_true", help="跳过逐字节回读校验（不推荐）")
    p.add_argument("--no-eject", action="store_true", help="刻完不自动弹出托盘")
    p.add_argument("--keep-iso", action="store_true", help="保留 ISO 与暂存目录")
    p.add_argument("--stage", default=None, help="暂存目录（默认在 $SUITE 下建临时目录）")
    p.add_argument("--out", default=None, help="证据输出目录（默认 $RDSH_BACKUP_ROOT/dvd-<时间戳>）")
    p.add_argument("--volume-prefix", default=None, help="ISO 卷标前缀（默认 RDVD / 备份 RDSH）")
    p.add_argument("--label-prefix", default=None, help="盘面标签前缀")
    p.add_argument("--json", action="store_true", help="机器可读输出（stdout 只放 JSON）")
    p.add_argument("--apply", action="store_true",
                   help="真刻录（默认 dry-run）；会写盘，请确认")
    p.add_argument("--dry-run", action="store_true", help="只造 ISO 并核对，不刻录（默认）")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog=PROG, description="通用 DVD±R/RW 数据刻录（容量分析→分盘→ISO→刻录→回读校验）")
    ap.add_argument("--version", action="version", version=f"{PROG} {VERSION}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="探测光驱与介质")
    p.add_argument("--device", default=DEFAULT_DEV)
    p.add_argument("--json", action="store_true")
    p.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("plan", help="容量分析 + 分盘（只读）")
    p.add_argument("sources", nargs="+", help="源目录/文件")
    p.add_argument("--device", default=DEFAULT_DEV)
    p.add_argument("--disc-size", type=parse_size, default=None)
    p.add_argument("--reserve", type=parse_size, default=None)
    p.add_argument("--pack", choices=["dir", "file"], default="dir")
    p.add_argument("--out", default=None, help="写出 plan JSON")
    p.add_argument("--json", action="store_true")
    p.add_argument("--volume-prefix", default=None)
    p.add_argument("--label-prefix", default=None)
    p.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("burn", help="刻录（默认 dry-run）")
    p.add_argument("sources", nargs="*", help="源目录/文件")
    p.add_argument("--plan", default=None, help="用 plan 命令生成的 JSON")
    p.add_argument("--disc", type=int, default=None, help="只刻第 N 张")
    p.add_argument("--all", action="store_true", help="按计划刻全部盘")
    add_common(p)
    p.set_defaults(func=cmd_burn)

    p = sub.add_parser("backup", help="rdsh 数据备份（rsync 快照 + 刻盘；默认 dry-run）")
    p.add_argument("--scope", choices=["data", "suite"], default="suite",
                   help="data=各版本数据 home；suite=+shared/state/plugins/patches/config（默认）")
    p.add_argument("--with-backups", action="store_true", help="把现有 backup/ 快照也刻进去")
    p.add_argument("--with-logs", action="store_true", help="把 logs/ 也刻进去（含 token，注意）")
    p.add_argument("--plan-only", action="store_true", help="只出分盘计划，不刻")
    p.add_argument("--disc", type=int, default=None)
    p.add_argument("--all", action="store_true")
    add_common(p, backup=True)
    p.set_defaults(func=cmd_backup)

    return ap


def print_manifest() -> None:
    print(f"iface={IFACE}")
    print("x-rdsh-dvd|dvd|probe / plan <源…> / burn <源…> [--apply] / backup [--scope data/suite]|write|--dry-run|通用 DVD±R/RW 数据刻录（容量分析/分盘/回读校验；含 rdsh 数据备份）")


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] in ("--manifest", "manifest"):
        print_manifest()
        return 0
    ap = build_parser()
    args = ap.parse_args(argv[1:])
    return int(args.func(args))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        print("\n已中断。", file=sys.stderr)
        sys.exit(130)
