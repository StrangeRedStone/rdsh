# rdsh —— DSH 多版本运维工具链

> 让一台机器上**并存多个 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）版本**成为常规操作：每版本独立数据根，升级 / 回退 / 插件 / 补丁都有工具兜底。
>
> 本仓库是作者机器上实际运行、逐条实测过的脚本集合；不是设计稿。

## 它解决什么

| 痛点 | rdsh 的做法 |
|---|---|
| 换一个 dsh 版本 = 一次高风险手工搬迁 | `migrate.sh` 一条命令：备份 → 建链 → 搬数据 → 装插件 → 探针 → 记回退基线 |
| 多版本并行时数据互相污染 | 每个版本独立 `DSH_HOME`（`$BASE/.dsh/<版本>/`） |
| 与版本无关的作者资产（skills / lessons / AGENTS）在版本间分叉 | 外置到**稳定根** `$BASE/.dsh-shared/`，各版本 home 内只建软链 |
| 插件代码在新旧版本各存一份、修一处另一处不变 | **权威副本** `$BASE/dsh-plugins/` + `plugin-sync.sh`（带方向守卫） |
| 升级换了检出，打过的补丁全丢 | `patch-manager.sh` 重放补丁，冲突即停手、绝不半应用 |
| 升级后想回退但没有基线 | 每次迁移把「源/目标/备份/还原命令/探针结论」追加进 `回退基线.md` |

## 命令一览

主入口 `rdsh`（即 `Rdsh.sh`）：

| 子命令 | 作用 |
|---|---|
| `rdsh` / `rdsh run [版本\|序号\|路径]…` | 列表菜单 / 启动 1..N 个实例（默认**后台化** + 端口**递增**；`--dry-run` 预览，`--foreground` 占终端） |
| `rdsh stop [目标\|端口]` | 停实例：默认停"**端口最大的那一个**"（后进先出）；`--all` 从大到小、`--port N` 点名、`--dry-run` 只打印、`--probe` 只验投递链路 |
| `rdsh list` | 列版本（检出状态 / 数据目录） |
| `rdsh status` | 运行实例（全部端口，含 `debug:<id>` 与"你所在的实例"）+ 数据总览 |
| `rdsh debug new\|start\|stop\|ls\|add\|detach\|rm\|env` | **可丢弃沙箱**：`new` 建全新空 `DSH_HOME`（不播种、不链任何东西），`add/detach` 按调试目的加/摘作者资产与凭据，`rm` 先停实例再整体挪进回收目录（**永不 `rm`**）+ 还原命令 |
| `rdsh exec <版本\|debug-id> -- <命令>` | 在指定环境里跑一次性命令（排障用） |
| `rdsh add <检出路径>` | 把检出纳入管理 |
| `rdsh install [版本]` | `pnpm install` + 构建 + 打标 |
| `rdsh data [-o] [版本]` | 显示 / 打开数据目录 |
| `rdsh backup [版本]` | 备份数据目录到 `$BASE/.dsh-backup/` |
| `rdsh logs [-f] [-o] [--clean] [版本]` | 查看启动日志（显示时自动打码 token；按端口分家） |
| `rdsh base [路径] [--unset]` | 查看 / 设置基目录（只改指向，**不搬数据**） |
| `rdsh fetch --list / <版本>` | 从 GitHub 列举 / 下载版本（默认 `git clone --depth 1`；`--tarball` 走归档，无 `.git`） |
| `rdsh patch …` | 转发到 `patch-manager.sh` |

> `start` 与 `run` 等价（兼容别名）。多实例归属靠"**端口 + DSH_HOME**"两个维度：
> 同一 `DSH_HOME` 拒绝双开（会互相写 `workspace.json`/`settings`）；**同版本多开走 `rdsh debug`**。

配套脚本：

| 脚本 | 作用 |
|---|---|
| `migrate.sh` | 跨版本迁移器（七步、幂等、**全脚本无 `rm`**、`--dry-run`） |
| `reindex-workspaces.sh` | 重建工作区归属（手拷会话后 UI 显示「未分组」时用；**须先停实例**） |
| `plugin-sync.sh` | 插件一致性：`--check` / `--sync` / `--adopt` / `--init` / `--status` |
| `rdsh-restart.sh` | 安全重启当前 web 实例（systemd 逃逸舱；`--dry-run` / `--probe`） |
| `patch-manager.sh` | 补丁管理：`list` / `status` / `apply` / `revert` / `export` |

每个脚本都支持 `--help`。

## 目录布局

全部由**单一旋钮 `BASE`** 决定（默认 `$HOME/Mapp`）：

```
$BASE/
├── dsh/                  # 本仓库 + 各版本检出（<检出目录>/ 自动扫描）
├── .dsh/<版本号>/        # 每版本独立数据根（DSH_HOME）
├── .dsh-shared/          # 与版本无关的作者资产（软链进各 home）
├── .dsh-backup/          # 备份 + 回退基线.md
├── .dsh-logs/            # 启动日志（700/600，含访问 token）
└── dsh-plugins/          # 插件的唯一权威副本
```

## 依赖

- **必需**：`bash` 4+、`git`、`coreutils`、`python3`、`jq`
- **启动/重启**：`iproute2`（`ss`）、`systemd`（`systemd-run --user`）、`flock`
- **构建/安装**：`node` + `pnpm`
- **备份**：`rsync`

## 快速开始

```bash
# 1) 本仓库按设计要落在 $BASE/dsh（默认 ~/Mapp/dsh）——与检出同目录
git clone <repo-url> ~/Mapp/dsh
chmod +x ~/Mapp/dsh/*.sh

# 2) 装一个入口命令
mkdir -p ~/.local/bin
ln -s ~/Mapp/dsh/Rdsh.sh ~/.local/bin/rdsh

# 3) 看看有什么版本可下
rdsh fetch --list

# 4) 下载并安装一个版本
rdsh fetch 0.1.6-alpha.1 --install

# 5) 启动
rdsh start
```

> 想把数据放到别处？`rdsh base ~/mydsh` 只改指向、不搬数据。也可以直接设环境变量 `RDSH_BASE`。

## 配置

优先级：**环境变量 > 配置文件 > 默认**。配置文件默认 `~/.config/rdsh/config`（纯 `KEY=VALUE`，**不 source**，可用 `RDSH_CONFIG` 指定）。示例见 [`examples/config`](examples/config)。

| 变量 | 默认 | 含义 |
|---|---|---|
| `RDSH_BASE` | `$HOME/Mapp` | 唯一旋钮，下列默认值都从它派生 |
| `RDSH_MANAGE_ROOT` | `$BASE/dsh` | 检出根 |
| `RDSH_DATA_ROOT` | `$BASE/.dsh` | 数据根 |
| `RDSH_BACKUP_ROOT` | `$BASE/.dsh-backup` | 备份根 |
| `RDSH_SHARED_HOME` | `$BASE/.dsh-shared` | 作者资产稳定根 |
| `RDSH_PLUGIN_ROOT` | `$BASE/dsh-plugins` | 插件权威副本 |
| `DSH_LOG_DIR` | `$BASE/.dsh-logs` | 启动日志目录 |
| `RDSH_TRASH` | `/tmp` | 「删除」的回收目录（永不 `rm`） |
| `RDSH_CONFIG` | `~/.config/rdsh/config` | 配置文件路径 |

## 安全设计（原则 P1）

1. **只检测、只留痕、只放行** —— 不替用户做不可逆决定，也不阻止用户做。
2. **永不 `rm`** —— 删除一律先 `mv` 到回收目录，并在输出里说明去了哪。
3. **幂等 + `--dry-run`** —— 任何写操作都能安全重跑；不覆盖已有数据，冲突只警告。
4. **每个动作留证据** —— 备份目录带还原说明，基线进 `回退基线.md`，探针出报告。
5. **不用 `pkill/pgrep -f`** —— 重启脚本只对 `ss` 给出的端口 owner PID 发 `SIGTERM`，且发信号前核对进程归属。

## 已知限制（诚实边界）

- **检出放在 `MANAGE_ROOT` 下**（默认 `$BASE/dsh`）。未显式配置、且 `$BASE/dsh` 不是本工具所在处时，`MANAGE_ROOT` 会回退到**脚本自身目录**——所以 `git clone` 到任意目录后可直接运行，检出也会落在那里（已被 `.gitignore` 忽略）。要换位置用 `rdsh base <路径>` 或设 `RDSH_MANAGE_ROOT`。
- `plugin-sync` 的方向判断基于 **mtime**，是近似值（`cp -a` 会保留时间、手改会刷新）；更稳的「构建记录」尚未实现。
- 插件权威副本「谁最新」目前由人（或 `--adopt`）决定，**没有自动构建流水线**。
- `rdsh fetch` 依赖 GitHub；网络不畅时可能失败（`--list` 有 10 分钟磁盘缓存与 `git ls-remote` 回退）。
- `settings.yaml` 目前是每版本一份的实文件，**跨版本升级会丢插件开关与配置**（见路线图）。
- 没有功能级测试套件；CI 做 `bash -n`、干净 HOME 下的 `--help` 冒烟、可移植性冒烟，外加 **shellcheck（error 级阻塞、warning 级咨询）**。已知 warning 族见 `docs/路线图.md`。
- 本仓库脚本为**内部实测版整理而来**，非从零设计的通用软件。

## 文档

- [`docs/架构.md`](docs/架构.md) —— 三层资产模型、单一旋钮、软链与权威副本
- [`docs/路线图.md`](docs/路线图.md) —— 待做事项（P0/P1/P2）
- [`docs/故障手册.md`](docs/故障手册.md) —— 常见故障与处置
- [`docs/升级与回退指南.md`](docs/升级与回退指南.md) —— **升级/回退的逐条命令、检查单、验收清单、演练**

## 维护者：本机工作目录 ↔ 发布仓库

本仓库是**发布快照**；日常在用的真身放在本机工作目录里（默认 `~/Mapp/dsh/`）。那个目录同时还放着 dsh 的检出（上游代码，6G+），**所以绝不能把整个目录当仓库**。

两者关系是**单向**的：本机是权威，仓库只是发布目标。

```bash
# 1) 在 ~/Mapp/dsh 里改脚本（跟平时一样）
# 2) 看差异（只读，有差异时退出码 1）
bash tools/publish.sh --check
# 3) 把白名单文件集中进仓库
bash tools/publish.sh --stage
# 4) 提交并推送
git add -A && git commit -m "..." && git push
```

`tools/publish.sh` **只搬运写死在白名单里的那 6 个脚本**，不通配扫目录 —— 所以本机工作目录里的检出（上游代码）永远不会被带进仓库。

## 许可证

**[MIT](LICENSE)**（2026-09-19 由「暂不加」改为 MIT）。可自由使用、修改、分发、商用，只需保留版权与许可声明。

> 将来若把 `dsh-patches/`（补丁派生于 MIT 的上游 DSH）随「我的 dsh」仓库发布，需随附上游的版权与许可声明（MIT 兼容）。

## 来源

脚本头部的日期即实测日期；全部逻辑来自一台长期运行的 DSH 工作机上的真实升级与故障处置。
