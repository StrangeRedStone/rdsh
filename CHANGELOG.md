# Changelog

本文件记录 rdsh 的显著变更。日期为实测/提交日期。

## 0.3.0 — 2026-09-26

### 新增

- **多实例：`rdsh run [目标]…`**（`start` 保留为等价别名）。
  - **默认后台化**：走 `systemd-run --user --unit=dsh-web-<版本>-<端口>`，脱离终端与 DSH 自己的 cgroup（否则新实例会被旧实例的关停连带 dispose）。`--foreground` 回到"占着终端跑"的老行为。单元内部一律前台，并有 `DSH_LAUNCH_DETACHED` 兜底，结构上排除"套两层单元"。
  - **端口默认加一**：取在跑实例的最大端口 +1（一个都没有则 3080）；`--port N` 指定起始、`--step N` 定步长（多目标依次递增）。
  - **同一 `DSH_HOME` 拒绝双开**：多开会互相写 `workspace.json`/`settings`（会话级 flock 只保护单会话）。同版本多开走 `rdsh debug`。
  - 启动后等端口就绪再回报，并**校验端口 owner 确实是我们的 dsh web** 才登记。
- **`rdsh stop [目标|端口]`**：默认停"**端口最大的那一个**"（后进先出，与端口递增对称）；`--all` 从最大端口往小逐个停；`--dry-run` 只打印计划；`--timeout N`；`--probe` 只验证投递链路不发信号。
  - **托管实例走 `systemctl --user stop <unit>`**（一次收掉整个 cgroup，含 pnpm 包装进程）；未托管回落 SIGTERM + 等端口释放 + 归属校验补刀。
  - **自杀防护**：目标是本进程的祖先（就是你在用的那个实例）时，非交互环境直接拒绝；`--force` 确认后把自己投递到一次性 systemd 单元、延迟执行（`--delay`，默认 3s），让调用方先把当前回合落盘。
- **实例注册表 `$BASE/.dsh-suite/run/instances/<端口>.kv`**：**注解层，不是真相**。真相永远是 `ss` + `/proc`（PID/cwd/`DSH_HOME` 现场读）；注册表只补 `ss` 查不到的字段（kind、debug id、systemd 单元名、日志、启动时间）。注解丢失不影响识别，过期条目自动退休到 `run/stale/`（不 `rm`）。附带好处：新版本一上来就能管住"没登记过的旧实例"。
- **`rdsh debug`（可丢弃沙箱）**：`new|start|stop|ls|add|detach|rm|env`。
  - `debug new` **默认全新**：建一个**完全空**的 `DSH_HOME`（不播种 `settings`、不链作者资产、不链凭据）。实测首启后只剩 dsh 自己的 `.anonymous-user-id`/`profiles`/`storages` + 一个空凭据文件，**0 个软链**。
  - 按调试目的单独加料：`--assets`（软链作者资产）、`--creds`（软链凭据，读写同一份）、`--copy-creds`（独立复制并 `chmod 600` —— dsh 对凭据文件有"不得有组/其他位"的硬校验）；`detach` 反向摘掉，**只挪软链、真身不动**（前后快照逐字节一致）。
  - `debug rm`：先停实例 → home + 清单整体挪进 `/tmp/rdsh-trash-debug-*` → 打印还原命令。**永不 `rm`**，且硬白名单只认 `$BASE/.dsh-suite/debug/` 下带清单的环境。
  - **同版本多开的正路**：`debug new <版本> --tag t1 --start` 与 `--tag t2 --start` 各得一份独立 home 与端口。id 必须以字母开头，保证 `rdsh run <版本>` 永不撞上沙箱名。
- **`rdsh exec <版本|debug-id> -- <命令>`**：在指定环境（检出 + `DSH_HOME`）里跑一次性命令。
- `rdsh status` 升级为**实例表**：端口 / PID / 版本 / 检出 / `DSH_HOME` / URL / 单元 / 启动时间，标出 `debug:<id>` 与"← 你所在的实例"。

### 变更

- `rdsh run`/`start` **默认后台化**（老行为用 `--foreground`）；后台启动时**显式 `--setenv` 转发 `RDSH_*`/`DSH_*`** —— systemd 用户单元只继承 `PATH`/`HOME`/`XDG_RUNTIME_DIR`，**不继承自定义变量**（实测）。
- **启动日志按端口分家**（`web-<版本>-<端口>.log`），`rdsh logs` 优先取"该版本在跑实例的端口"，再回退默认端口、再回退旧命名 `web-<版本>.log`。
- **`rdsh-restart.sh` 适配 0.3.0** 并新增日志自兜底：dry-run 用 `--takeover` 放行"同一 home 已在跑"（重启本来就会停掉它），启动时加 `--foreground --takeover` 并**钉住 `--port "$PORT"`**（否则会被"最大端口+1"挪走）；调用方没给 `DSH_RESTART_LOG` 时**自己定一个**（先探可写，探不到就警告并继续）——此前经 `reboot` 插件触发的重启只进 journal，事后翻查麻烦。`DSH_RESTART_NOLOG=1` 可关。
- **`migrate.sh` 探针 v2**（本机 2026-09-25 的改动，此前未发布，本次一并发布）：第 6 步改用 `compat-check` v2 的 CLI（`--home/--checkout/--scope/--selftest/--from`，可选 `--live` 实机实测门），退出码 = 最高严重度（P1：只提示不拦），旧版探针回退时明确告警。

### 设计约束（都写进代码，不是写在文档里）

- **归属校验是唯一红线**：只对过得了 `is_dsh_web_pid`（cmdline 是 web 入口 + cwd 是已管理检出或名字像 dsh 检出）的进程动手；**没有 `--force` 能覆盖这一条**；不用 `pkill/pgrep -f`；**绝不发 `-9`**。
- **一切"停"都要能说清杀谁**：`--dry-run` 打印目标与依据（PID / cwd / 走 `systemctl` 还是 SIGTERM）。

## 0.2.2 — 2026-09-25

### 变更

- **`rdsh fetch` 默认改为 `git clone --depth 1 --branch <tag>`**（此前默认归档 tarball）。理由：rdsh 的下游能力全都吃 `.git` —— `rdsh patch export` 在无 git 的检出上**直接失败**（`patch-manager.sh` 首句判定），`git apply --3way` 退化成 `patch -p1 --merge`，上游 diff、`git status` 干净判定、`tag → commit` 溯源也都需要对象库；而 tarball 省下的是 23MB vs 151MB 的下载量，相对 2GB 级检出（`.git` 约 200MB ≈ 8%）不是决定性收益。新默认同时与官方 README「Run from source」的 `git clone` 一致。
- **`--tarball` 保留为回退**（网络极差时的单次 HTTPS + 重试）；用归档方式拉取**成功后新增告警**，当场说明该检出没有 `.git`、不能 `rdsh patch export`。
- `--git` 仍可作为显式写法（与默认等价）；`--full` 仍表示克隆完整历史。

## 0.2.1 — 2026-09-19

### 变更

- **许可证：改为 [MIT](LICENSE)**（同日早些时候的决定是「暂不加」，现更新）。添加 `LICENSE`，README 的「许可证」一节改为 MIT 声明。

## 0.2.0 — 2026-09-19

### 新增

- **`tools/publish.sh`（维护者工具）**：本机工作目录（权威）→ 仓库的**单向**发布。按显式白名单搬运脚本，**不通配扫目录** —— 本机目录里的 dsh 检出（上游代码）永远不会被带进仓库。`--check` / `--stage` / `--dry-run`。
- **《DSH 升级与回退指南》**（[docs/升级与回退指南.md](docs/升级与回退指南.md)）：升级/回退逐条命令、升级前检查单、升级特有坑、升级后验收清单、回退演练、命令速查。

### 变更

- **`patch-manager.sh`**：补丁仓与备份根改为可配置 —— `--patches` > `RDSH_PATCHES` > 配置项 `PATCHES`；`RDSH_BACKUP_ROOT` > 配置项 `BACKUP_ROOT`。此前两者写死为 `$BASE` 下，把目录移出 `$BASE` 后会失效（默认路径下行为不变）。
- **CI**：`shellcheck` 由「恒成功」推进为 **error 级阻塞、warning 级咨询**（当前 error = 0；warning 40 条已逐个分诊，均为误报或无害，见 [docs/路线图.md](docs/路线图.md)）。
- README 的「已知限制」与「许可证」两节更新。

### 决定记录

- **许可证：暂不加**（保留全部权利）。这是 2026-09-19 的决定；改为 MIT = 加 `LICENSE` 文件 + 更新 README 对应一节。

## 0.1.1 — 2026-09-19

### 新增

- **可移植性**：未显式配置 `MANAGE_ROOT`、且 `$BASE/dsh` 不含 `Rdsh.sh` 时，回退到脚本自身所在目录 —— `git clone` 到任意目录后即可运行；有既定布局（`$BASE/dsh`）时行为不变。`RDSH_MANAGE_ROOT` 与 `rdsh base` 仍优先。
- **检出校验**：只把根目录含 `package.json` 的目录当作 dsh 检出，避免把工具自带的 `docs/`、`examples/` 误列成"版本"。
- **CI**：新增「可移植性冒烟」；`--help` 冒烟改为在**干净 `HOME`** 下执行（贴近"别人 clone 下来"的真实场景）。

### 修复

- `patch-manager.sh`：`--help` 此前会被当作子命令消费，进而在**没有补丁仓的机器上直接退出**、看不到用法。现于参数解析前短路。
- `patch-manager.sh` / `rdsh-restart.sh`：`--help` 曾用写死行号打印头部，会把代码行混进帮助文本；改为「打印到分隔线」。
- CI 的 `shellcheck` 作业此前依赖已失效的第三方 action，现改用 runner 自带 shellcheck（仍为咨询性、不阻塞）。

> 对应提交 `17e2f20`、`379c68c`。

## 0.1.0 — 2026-09-19

首次整理发布。内容来自作者机器上 `~/Mapp/dsh/` 的内测脚本（2026-09-08 ~ 09-18 陆续写成并实测）。

### 包含

- 主入口 `Rdsh.sh`（v4）：list / status / start / add / install / data / backup / logs / base / fetch / patch
- `migrate.sh`（v1）：跨版本迁移器，七步、幂等、无 `rm`、`--dry-run`
- `reindex-workspaces.sh`：重建工作区归属
- `plugin-sync.sh`：插件一致性 check / sync / adopt / init / status
- `rdsh-restart.sh`：安全重启（systemd 逃逸舱、`--probe` 演练）
- `patch-manager.sh`：补丁 list / status / apply / revert / export

### 相对内测版的改动（发布前整理）

- **脱敏**：移除注释与提示文本中的个人绝对路径与私有文档引用，改为 `$HOME` / `$BASE` / 仓库内文档引用。
- **修正**：`rdsh patch` 转发目标由 `$BASE/dsh/patch-manager.sh` 改为 `$MANAGE_ROOT/patch-manager.sh`，与 `MANAGE_ROOT` 可显式覆盖的设计一致（默认路径下二者等价）。
- 新增 `README.md`、`CHANGELOG.md`、`docs/`、`examples/config`、CI。

### 内测期里程碑（供追溯）

- 2026-09-17：跨版本迁移闭环；真实升级 0.1.3-alpha.2 → 0.1.6-alpha.1 并验收。
- 2026-09-18：插件权威副本 + `plugin-sync`；补丁工具链；安全重启与自动续跑。
- 2026-09-18：`plugin-sync` 加 mtime 方向守卫（修「单向覆盖把新版盖回去」风险）。

## 未发布（规划）

见 [`docs/路线图.md`](docs/路线图.md)。
