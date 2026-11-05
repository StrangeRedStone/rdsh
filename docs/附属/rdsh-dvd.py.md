# plugins.d/rdsh-dvd.py —— 通用 DVD±R/RW 数据刻录（外部能力）

> **一句话**：把任意目录/文件做容量分析、分盘、造 ISO、刻盘并逐字节回读校验；支持
> DVD+R/DVD-R/DVD+RW/DVD-RW；`rdsh dvd` 调用，并自动进 `rdsh bridge --spec` 给 dsh 侧看见。
> 另有 `rdsh dvd backup` 一键把 rdsh 数据（rsync 快照）刻成离线备份盘。

## 依赖

- 系统工具：`xorriso`、`growisofs`（dvd+rw-tools）、`dvd+rw-mediainfo`、`cmp`、
  `blockdev`、`eject`；RW 另需 `dvd+rw-format`；备份另需 `rsync`。
- 权限：当前用户对 `/dev/sr0` 有读写权（本机在 `cdrom` 组）。
- Python 3（脚本为 `python3`，无第三方库）。
- 安装：把 `plugins.d/rdsh-dvd.py` 复制到 `$MANAGE_ROOT/plugins.d/` 并 `chmod 755`，然后 `rdsh selfcheck`；
  它不在 `tools/publish.sh` 的白名单里（外部能力与主体脚本分开部署）。

## 能力（子命令）

| 命令 | 风险 | 作用 |
|---|---|---|
| `rdsh dvd probe` | read | 打印/JSON 输出光驱与介质：类型、状态、容量、可擦写、写速、Book、托盘 |
| `rdsh dvd plan <源…>` | read | 容量分析 + 分盘，输出表格或 plan JSON（可 `--out` 落文件） |
| `rdsh dvd burn <源…>` / `--plan <json>` | write（默认 dry-run） | 造 ISO → 核对 → 刻录 → 逐字节回读校验 → 写证据 |
| `rdsh dvd backup [--scope data\|suite]` | write（默认 dry-run） | rsync 快照 rdsh 数据 → 分盘 → 刻盘 |

## 提供的定义

- **受理**：任意普通文件/目录；rdsh 备份的 `data`（各版本数据 home）或 `suite`
  （`data` + `shared` + `state` + `plugins` + `patches` + `~/.config/rdsh/config`，
  可选 `--with-backups` / `--with-logs`）。
- **产出**：每盘一张 ISO9660+Joliet+RR 数据盘（卷标 `RDVD_*` / 备份 `RDSH_*`），
  盘内含全部文件 + `MANIFEST.sha256` + `00-本盘说明.txt`。
- **边界**：
  - 仅数据盘；不做音频 CD / DVD-Video / 双层特殊处理（双层盘按 `dvd+rw-mediainfo` 报告的
    可用块数走，未实测）。
  - **符号链接不跟随**（跳过并计数）；盘上只放普通文件。
  - 只支持 DVD±R/RW；DVD-ROM、CD-R/RW、DVD-RAM 明确拒绝。
  - 一次性盘非空白 → 拒绝覆盖；可擦写盘非空白 → `--rw-policy=auto` 先格式化（旧数据会丢），
    `refuse` 直接报错。
  - `backup` 的快照是 rsync 时点复制，**不是文件系统快照**；正在写的实例可能造成文件处于中间态。

## 提供的证据

- 盘内：`MANIFEST.sha256`（每文件 sha256，盘根执行 `sha256sum -c` 复核）、`00-本盘说明.txt`。
- 刻后：`cmp -n <iso_size> <iso> /dev/sr0` **逐字节**比对通过才算成功。
- 证据目录（默认 `$RDSH_BACKUP_ROOT/dvd-<时间戳>/`）：
  `discN-MANIFEST.sha256`、`discN-README.txt`、`discN-build.log`、`discN-burn.log`、
  `discN-iso.sha256`、`plan.json`。
- 流水：`$RDSH_JOURNAL` 追加 `…|rdsh-dvd|burn|discN note=label=… media=… bytes=… iso_sha256=… verify=ok out=…`。

## 工作方式

1. `plan`/`burn` 扫描源（跳过符号链接）→ 按 `--pack dir|file` 装进
   「单盘容量 − `--reserve`（默认 32 MiB）」的仓；
2. 每盘：硬链接暂存树（跨文件系统才复制）→ 生成 MANIFEST/说明 →
   `xorriso -as mkisofs -R -J -joliet-long -V <卷标>` → 核对文件数/字节数；
3. 真刻录前确认介质；RW 非空白按策略格式化；`growisofs -dvd-compat -speed=N -Z dev=iso`；
4. 等介质就绪（growisofs 可能把托盘弹开 → 提示推回）→ `cmp` 回读 → 写证据 → 自动弹出；
5. 失败保留暂存/ISO 供重试；不覆盖用过的写一次盘。

## 变量

| 变量 | 含义 |
|---|---|
| `RDSH_BASE` | rdsh 基目录（rdsh 调用时自动传入；直接运行先问 `rdsh base --json`，再读配置；**不再假设 `~/Mapp`**） |
| `RDSH_DATA_ROOT` / `RDSH_SHARED_ROOT` / `RDSH_STATE_ROOT` / `RDSH_PLUGIN_ROOT` / `RDSH_PATCHES_ROOT` / `RDSH_BACKUP_ROOT` / `RDSH_LOG_DIR` | 各根（rdsh 调用时已解析） |
| `RDSH_JOURNAL` | 证据流水文件 |
| `RDSH_CONFIG` | rdsh 配置文件（备份 `--scope suite` 会带上） |
| `RDSH_DVD_DEVICE` | 默认光驱设备（默认 `/dev/sr0`） |

## 命令示例

```bash
rdsh dvd probe --json
rdsh dvd plan ~/some-data --disc-size 4482M --out /tmp/plan.json
rdsh dvd burn ~/some-data --apply                 # 默认 4.7G 空白盘；自动分盘
rdsh dvd burn --plan /tmp/plan.json --disc 2 --apply
rdsh dvd backup --scope suite --apply             # 默认 dry-run；加 --apply 真刻
rdsh dvd backup --scope data --plan-only          # 只出分盘计划
```

## 实测状态（2026-11-01 ~ 11-05）

| 项 | 结果 |
|---|---|
| 隔离冒烟 `tools/smoke-dvd.sh` | **22 通过 / 0 失败**（假光驱/假设备；含负样本） |
| 真 rdsh 数据 + 假设备 `backup --scope data` | 924 文件 / 527.6 MiB → 530.0 MiB ISO；`cmp` 通过；证据/journal 齐全 |
| 真 rdsh 数据 `backup --scope suite --plan-only` | 1218 文件 / 529.9 MiB → 1 张盘 |
| **真机 DVD+RW 写入**（2026-11-05） | 通过：3 文件/3.0 MiB，自动 `dvd+rw-format -force` 后刻录，`cmp` 逐字节通过；证据 `real-test-evidence-1` |
| **真机 DVD+RW 复写**（2026-11-05） | 通过：同一张盘第二组 2 文件/1.0 MiB，格式化→刻录→`cmp` 通过；证据 `real-test-evidence-2` |
| **最终代码真机复验**（2026-11-05） | 通过：3 文件，`--apply` 真刻录，`cmp` 通过；证据 `real-test-evidence-3` |
| **真机 DVD-R / DVD-RW** | **暂不实测**（用户长期没有这两种介质）。以后计划买的 M-Disc 是 **DVD-R** 规格，届时优先验证 DVD-R 路径；DVD-RW 可能不买 |

> 实测踩到的坑：`growisofs -Z` 在非交互环境下遇到盘上已有 ISO 会 FATAL
> `already carries isofs!`，所以可擦写盘非空白时必须先 `dvd+rw-format -force`
> （本机 4.7G +RW 格式化约 3 分钟）；空白的 +RW 可直接写。
> DVD-R / DVD-RW 暂不实测；以后 M-Disc（DVD-R）到手时，先拿可弃盘做小数据冒烟再正式用。
