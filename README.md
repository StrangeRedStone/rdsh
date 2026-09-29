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
| `rdsh backup [<目标>\|--all] [--snapshot\|--full] [--state] [--verify] [--keep N]` | **本地**快照数据 home 与状态账本。`--snapshot` 用 `rsync --link-dest` 做**增量**（未变化的文件是硬链接，只存变化）；`--verify` 核查快照定稿后有没有被改过；`--keep N` 保留策略（超出的进回收站）；`--list` 列快照 |
| `rdsh restore --list` / `--type <类> [--from <源>] [--file <路径>] [--diff] [--merge] [--yes]` | 从**本地快照 / 本地克隆 / 远端仓库**恢复。`data`/`state` **只认本地源**；凭据默认不恢复（`--with-creds`）；记忆三库默认**按条目追加**；覆盖前既有目标整体进回收站；收尾自动调 `doctor` |
| `rdsh logs [-f] [-o] [--clean] [版本]` | 查看启动日志（显示时自动打码 token；按端口分家） |
| `rdsh base [路径] [--unset]` | 查看 / 设置基目录（只改指向，**不搬数据**） |
| `rdsh fetch --list / <版本>` | 从 GitHub 列举 / 下载版本（默认 `git clone --depth 1`；`--tarball` 走归档，无 `.git`） |
| `rdsh du [--purge <类>] [--older-than Nd] [--yes] [--force] [--json]` | **衍生物账本**：回收站 / 备份快照 / 调试沙箱 / fetch 临时 / 注册表陈旧 / 启动日志的体积与份数。**默认只列不删**；`--purge` 才是真删（备份类必须给 `--older-than`；回收项小于 `RDSH_TRASH_KEEP_DAYS`（默认 7 天）要 `--force`） |
| `rdsh trash ls / restore <条目名\|--last> [--force]` | **回收站**（"永不 rm"的落点）：每个条目自带清单（原路径 / 体积 / 原因 / 逐项还原命令 / 跨设备标记）。`restore` 目标已存在则跳过不覆盖，`--force` 才腾位 |
| `rdsh doctor [--only <维度,…>] [--json] [--quiet]` | **一键只读体检**（九个维度：检出 / 数据 home / 软链完整性 / 插件一致性 / 状态账本 / 实例 / 日志 / 磁盘内存 / 配置）。**必报"检查了几个对象"，总数为 0 时报 error**；退出码 `0` 无发现 / `1` 有 warn / `2` 有 error —— restore / retire / migrate 共用它 |
| `rdsh state [list\|show\|role\|render\|sync\|journal\|--init]` | **状态账本（唯一权威）**：谁是什么角色（`current`/`baseline`/`retire-candidate`/`retired`）。权威是 `$BASE/.dsh-suite/state/versions.kv` + 只追加的 `journal.log`；各检出里的 `.installed` 是它的回声（KEY=VALUE），`回退基线.md` 是它的**生成视图** |
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
├── .dsh-backup/          # 备份 + 回退基线.md（生成物）+ snapshots/ + state-snapshots/
├── .dsh-logs/            # 启动日志（700/600，含访问 token）
├── dsh-plugins/          # 插件的唯一权威副本
└── .dsh-suite/           # 运行期状态（新件都在这一层，可用配置逐项改位置）
    ├── state/            #   状态账本：versions.kv + journal.log（唯一权威，700）
    ├── run/              #   实例注册表（注解层；真相是 ss + /proc）
    ├── debug/            #   调试沙箱（rdsh debug）
    └── trash/            #   回收站：<时间戳>-<标签>/ + 清单（**与 BASE 同文件系统**）
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
| `RDSH_TRASH` | `$BASE/.dsh-suite/trash` | 回收站根。**默认与 `BASE` 同文件系统** —— 跨设备 `mv` 会退化成"复制+删除"（慢、瞬时双份占用），旧默认 `/tmp` 还可能是 tmpfs（≈内存） |
| `RDSH_TRASH_KEEP_DAYS` | `7` | 回收项小于这个天数时，`du --purge trash` 需要 `--force` |
| `RDSH_STATE_ROOT` | `$BASE/.dsh-suite/state` | 状态账本（唯一权威）：`versions.kv` + `journal.log` |
| `RDSH_MYDSH_REPO` | （空） | 「我的 dsh」本地克隆路径；`rdsh restore` 不写 `--from` 时用它 |
| `RDSH_PATCHES` | `$BASE/dsh-patches` | 补丁仓（与 `patch-manager.sh` 同默认） |
| `RDSH_RUN_DIR` | `$BASE/.dsh-suite/run` | 实例注册表（注解层，真相是 `ss` + `/proc`） |
| `RDSH_DEBUG_ROOT` | `$BASE/.dsh-suite/debug` | 调试沙箱（`rdsh debug`） |
| `RDSH_CONFIG` | `~/.config/rdsh/config` | 配置文件路径 |

## 状态账本（state，0.4.0 起）

回答一个问题：**谁是什么角色**。此前这件事有三份手写来源（各检出里的 `.installed`、实例注册表、`回退基线.md`），必然漂移；现在收成一处：

| 角色 | 出处 | 用途 |
|---|---|---|
| **权威** | `$STATE_ROOT/versions.kv` | rdsh 唯一可写的状态源（原子替换，700） |
| **流水** | `$STATE_ROOT/journal.log` | **只追加**的事件历史（`时间｜事件｜对象｜细节`） |
| **回声** | `<检出>/.installed` | KEY=VALUE；文件**存在**仍表示"已构建" |
| **视图** | `$BACKUP_ROOT/回退基线.md` | 人读；由上面三者**生成**，不再手写 |

角色取值：`installed`（已安装未定）/ `current`（当前在用）/ `baseline`（回退基线）/ `retire-candidate`（可删）/ `retired`（已退役）。

老机器首次用：`rdsh state --init`。它会从现有检出（`.installed` 的 mtime、git remote、HEAD）和旧 `回退基线.md` **反向推断**，**逐条打印它推断了什么**，并把旧的手写文件移进 `$STATE_ROOT/回退基线-历史.md` 留档（`mv`，原文不改，还原命令会打印）。

> `.installed` 写在检出里，所以 `rdsh` 会把它加进 `.git/info/exclude`（本地生效、不进上游）——否则它会污染 `git status`，动摇补丁工具的"干净树"前提。

## 平台与目标

- **目标平台**：Linux + `bash` 4+ + POSIX `coreutils` + `systemd --user` + `git`。核心机制**结构性**依赖它们：`ss` + `/proc` 真相层、`systemd-run` 逃逸舱、POSIX 软链、同文件系统 `mv` 的原子语义。
- **非目标**：Windows（移植等于重写，且会丢掉全部"实机实测"的证据基础）；Rust/Go 重写（当前 ROI 低）。但内核在设计上向声明式靠拢——状态文件即期望状态，命令即 reconcile——将来真要换实现形态，内核不用动。

## 安全设计（原则 P1）

1. **只检测、只留痕、只放行** —— 不替用户做不可逆决定，也不阻止用户做。
2. **默认永不 `rm`** —— 所有"删除"都先 `mv` 进回收站（`rdsh trash`），条目带清单与还原命令。
   **唯一的真删**是 `rdsh du --purge`，五道约束：必须显式给类别 / 备份与 fetch 类必须给 `--older-than` / 没有 `--yes` 只预览 / 回收项小于 `RDSH_TRASH_KEEP_DAYS` 天要 `--force` / 路径必须在白名单内（回收站·备份·注册表陈旧·fetch 临时）。
3. **幂等 + `--dry-run`** —— 任何写操作都能安全重跑；不覆盖已有数据，冲突只警告。
4. **每个动作留证据** —— 备份目录带还原说明，基线进 `回退基线.md`，探针出报告。
5. **不用 `pkill/pgrep -f`** —— 重启脚本只对 `ss` 给出的端口 owner PID 发 `SIGTERM`，且发信号前核对进程归属。

## 已知限制（诚实边界）

- **检出放在 `MANAGE_ROOT` 下**（默认 `$BASE/dsh`）。未显式配置、且 `$BASE/dsh` 不是本工具所在处时，`MANAGE_ROOT` 会回退到**脚本自身目录**——所以 `git clone` 到任意目录后可直接运行，检出也会落在那里（已被 `.gitignore` 忽略）。要换位置用 `rdsh base <路径>` 或设 `RDSH_MANAGE_ROOT`。
- **写功能冒烟要连配置一起隔离**：`RDSH_CONFIG` 若被环境注入、或 `$BASE/dsh` 里没有 `Rdsh.sh`（触发自定位回退），"只换 HOME"的隔离测试仍会打到真机。`tools/smoke-state.sh` 演示了正确做法。
- **状态账本首次使用要播种**：0.4.0 之前装的机器没有账本，`rdsh state list` 会提示 `--init`；未播种时 `rdsh list` 的角色列显示 `-`（不报错）。
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
