# Changelog

本文件记录 rdsh 的显著变更。日期为实测/提交日期。

## 0.5.3 — 2026-09-29

### 新增

- **同版本共存编号（`-2` 次号）**：
  - **对象键** `版本` / `版本-2` / `版本-3`…，**全链一致**：检出目录名、数据目录、`list` 显示名、账本键、快照目录名。
  - **数据 home 自动分开**（`$DATA_ROOT/<键>` + `.map` 的 `dir|` 行）—— 否则两份会写同一个 `DSH_HOME`（互相写 `workspace.json`/`settings`）。
  - **身份一经分配就不变、不压缩、不重用**（含已 `retired` 的墓碑）；扫重覆盖 `state --init` / `install` / `add` / `fetch` 四个入口。
  - **快照按对象键归档**（此前按版本号 → 同版本两份的备份会混在一起）。
  - 匹配规则：**先全名精确**（含次号），片段命中多份则报错并列出各次号 —— 不替用户选。
  - `doctor` 新增"同版本多份"告警与"数据 home 撞车"错误。
- `tools/smoke-numbering.sh`（27 项断言）+ CI 一步。

### 修复（冒烟抓出）

- **`entry_ver` 是 `printf '%s'`（无换行）**，把它放进 `for` 循环会把所有版本号**拼成一行** → `sort | uniq -d` 永远为空 → doctor 的"同版本多份"检查**静默失效**。
- `state --init` 把"键已有行"当成"本检出已登记"（没比 `dir`）→ 同版本第二份被直接跳过，次号分配分支永远走不到；且登记时 `data` 用了**登记前**的 `ENTRIES` 缓存，写进了首份的 home。
- `sort_entries` 在**同版本多份**时排序不确定（主键相同），导致"谁先拿到裸版本号"随机 → 改为「版本倒序 + 检出目录名升序」的确定序。
- `adopt_and_entry`（`add` 的路径）数据 home 写死 `$DATA_ROOT/<版本>`，没走键 → 同版本第二份会与首份共用 home。

## 0.5.2 — 2026-09-29

### 新增

- **`rdsh retire [<目标…>] [--plan|--apply] [--force]` —— 退役**（把"删一个版本"从高风险手工操作变成逐项清点）：
  - **五类足迹**逐一清点：① 检出 ② 数据 home ③ home 内插件链（`profiles/node_modules/@deepseek-ai/*`，随 home 走）④ **指向①②的外部软链**（扫描范围明说：数据根 / 注册表 / 稳定根 / `~/.local/bin`）⑤ 日志 / 实例注册表 / `.map` 行 / 账本角色。
  - **默认只出计划**（`--apply` 才动）；①②④ **整体挪进同一个回收条目**，清单里有逐项还原命令 → `rdsh trash restore` 可整份还原。
  - **守卫**：正在运行（给停车命令）／是回退基线（`--force` 并写明"回退只能靠 fetch + 快照恢复"的后果）／退役后没有别的**可启动**版本（`--force`）——三种情况都先拒绝。
  - **收尾**：`.map` 删掉指向它的行、过期注册表注解退休、账本角色 → `retired` + 流水留墓碑（含退役原因，`--force` 放行基线也记档）、重新生成基线视图、`doctor --only links` 扫断链。
  - 无目标时列出账本里 `role=retire-candidate` 的候选。
- `tools/smoke-retire.sh`（39 项断言）+ CI 一步：验"计划不动东西""五类同一条目""不留断链""整份还原""三种守卫""真机未动"。

### 修复（冒烟抓出）

- **`grep -c` 输出 `0` 却退 1**，后面接的 `|| echo 0` 于是追加了第二个 `0` → 变量成了两行 → `$((n-m))` 算术崩溃 → **退役在中途静默中止**（足迹已挪走，但账本/流水都没写）。同类写法全项目审计并改掉。
- **`trash restore` 用 `[ -e ]` 判断软链**：断链的软链 `-e` 为假 → 永远还原不了（而退役收走的正是这种链）。改用 `-e` **或 `-L`**。
- `retire` 的"最后一版可启动版本"判据过窄：`baseline` 与 `retire-candidate` 都还能 `rdsh start`，不该只算 `current/installed`。

## 0.5.1 — 2026-09-29

### 新增

- **`scan-secrets.sh` + `rdsh scan` —— 隐私守卫**（把"担心泄漏"从记性变成机制）：
  - **error 级**：私钥头（`PRIVATE KEY`）、已知令牌形态（`sk-` / `ghp_` / `github_pat_` / `xox?-` / `AKIA…` / `AIza…` / JWT）、凭据文件名（`.credentials.yaml` 等）、会话数据路径（`sessions/` `storages/` `.anonymous-user-id` `profiles/`）。
  - **warn 级**：赋值型密钥（`PASSWORD=…`、`SECRET:` 等，大小写不敏感）、绝对家目录路径、邮箱地址、单文件超过 `--max-file-mb`（默认 5）。
  - 三种模式：`--path <目录>` / `--staged [--repo <dir>]`（**扫 git 索引**里将要提交的内容）/ `--files <文件>…`；`--json`、`--quiet`、`--strict`、`--all`。
  - **报告不回显敏感值**（只给规则 + 文件:行 + 命中长度）——否则守卫自己就是二次泄漏。
  - **零扫描报 error**（与 `doctor` 同一条纪律）；`--staged` 空索引算正常状态（rc=0）。
  - **全程只读**：不建临时文件（把待提交内容复制到 /tmp 本身就是泄漏面）。
- **`tools/smoke-scan.sh`（40 项断言）**：每条规则的正样本、**不回显敏感值**、占位/掩码不报噪声、零扫描、`--staged` 只扫索引、`--json`、**全程只读**、以及"公开仓不得有 error"。
- CI 新增 `privacy-scan` 作业（扫整个仓库，error 级阻塞）+ 隐私守卫规则冒烟步。

### 变更

- `tools/publish.sh`：`--stage` **搬运之前**先扫白名单文件，error 直接中止；`--check` 一致时额外扫整个仓库，有 error 返回 2。守卫位置「仓库优先、本机副本兜底」（首次发布时仓库里还没有它）。
- 「我的 dsh」的 `scripts/backup.sh --commit`：提交前扫**索引**内容；找不到守卫即**拒绝提交**（唯一出口是显式 `--no-scan`）。

### 修复（冒烟抓出）

- **`--path` 模式下内容规则一条都没跑**：`find` 给的是相对扫描根的路径，而 `content_of` 用当前 CWD 去 `cat` → 全部读空，只剩文件名规则生效。**表现是"扫了 24 个文件 → 干净"的假绿**（正是本工具要防的那类错误，却栽在自己身上）。修法：`real_path()` 在 path 模式补上扫描根。
- `grep -nE "-----BEGIN …"` 被 grep 当成**选项**解析 → 私钥规则永远不命中。改用 `grep -e`。
- 占位过滤器（`example` 等）把 `admin@example.org` 整行滤掉 → 邮箱规则单独一套排除，且该规则不再套用通用占位过滤。
- 赋值型密钥规则大小写敏感 → `password:` 漏报。改为 `-i`。
- 冒烟夹具**自指**：测试文件里写着完整假令牌，守卫扫到自己就报 error。改为运行期片段拼装（不给仓库加豁免名单 —— 那等于给真泄漏留后门）。

## 0.5.0 — 2026-09-29

### 新增

- **`rdsh backup` 重做**：数据 home 与状态账本的**本地**快照。
  - `--snapshot`：`rsync -a --link-dest=<上一份>` 增量 —— 未变化的文件是**硬链接**，只存变化（实测：3 份 263M 的数据 home 快照合计只占 265M，全量副本要 789M；单轮实际新增 2.1M）。
  - 每份快照带 `MANIFEST.kv`（版本/来源/模式/`link_dest`/文件数/体积/**`added_kb`（实际新增）**）。
  - `--verify` 核查**内部一致性**：文件数与清单一致、全部可读、**没有文件比 MANIFEST 还新**（定稿后被就地改动的证据）。
  - `--keep N` 保留策略：超出的快照**挪进回收站**（可还原），不 `rm`。
  - `--state` 快照状态账本（按用户裁定：state 只本地备份，不进任何仓库）；`--all` 对全部版本逐一快照；`--list` 列出快照账本。
  - 同一秒内连做两次快照不再撞目录名（自动加序号）。
- **`rdsh restore`**：三类来源 × 七种资产类型。
  - 来源：**本地快照**、**本地克隆**（`--from <目录>`）、**远端仓库**（`--from git:<URL>`，clone 到本地再恢复）。
  - 类型：`data` / `state` / `plugins` / `patches` / `shared` / `presets` / `config`；`--file` 可只恢复单个文件。
  - **隐私分界**：`data`/`state` **只认本地源**，`--from git:…` 一律拒绝并说明理由；`data` 恢复时 `.credentials.yaml` **默认跳过**（`--with-creds` 才带）。
  - **记忆三库按条目追加**（`lessons.md`/`facts.md`/`backlog.md` 是 append-only 语义）：`--merge` 只补目标缺的 `##` 块，并留 `.old-copy` 供对照。
  - 覆盖前把既有目标整体**挪进回收站**（逐项还原命令在清单里）；`--diff` 只看差异；没有 `--yes` 只预览；收尾自动调 `doctor`（`--no-doctor` 可关）。
- `tools/smoke-backup-restore.sh`（42 项断言）+ CI 一步：比 **inode** 证硬链接、比"版本目录 `du` 差"证省空间、验篡改检出、验只读/隐私/合并语义与"真机资产未动"。

### 变更

- `Rdsh.sh` 新增 `PLUGIN_ROOT`、`PATCHES_ROOT`、`MYDSH_REPO`、`SNAP_ROOT`、`STATE_SNAP_ROOT` 等旋钮；`rdsh backup <目标>` 的旧行为保留为 `--full`（并在 `snapshots/<版本>/` 下统一存放）。
- `trash_mv` 现在记录 `TRASH_LAST_DEST` 与各项新路径，供 `restore --merge` 等复用"刚被挪走的那一份"。

### 修复（都由冒烟测试抓出）

- **`${dry:+--dry-run}` 陷阱**：`dry=0` 也算"已设置" → 每次备份都变成 dry-run（什么都没写还报成功）。改为显式传 `dry|live`。
- **同一函数既报日志又返回路径**（走同一个 stdout）：`$(backup_one …)` 把日志一起吞进变量，路径也脏了。改为**返回值只走 stdout、叙述一律 stderr**。
- **`snap_files` 把 MANIFEST 自己算进文件数** → 写入前后各数一次导致 `--verify` 误报不一致。
- **只读快照会废掉增量**（实测后撤回）：`--link-dest` 的快速校验比的是全部保留属性，快照文件只读(0444)与源(0644)权限不同 → rsync 认为文件变了 → 不再硬链接。篡改改由 `--verify` 发现。
- **从快照恢复把 `MANIFEST.kv` 复制进数据 home**；以及恢复出的数据 home 只读（dsh 写不了自己的数据）。前者用 `--exclude=MANIFEST.kv`，后者用 `--chmod=Du+w,Fu+w`（仅在源是快照时）。
- `restore` 的位置参数归属：给了 `--type` 时第一个位置参数才是版本（此前被当成类型吞掉 → 解析到 `SNAP_ROOT` 层）。
- `rdsh backup --list` 不再用**表观大小**糊弄，改报"实际新增"（表观大小会把与旧快照共享的硬链接算进去）。

## 0.4.2 — 2026-09-29

### 新增

- **`rdsh du` —— rdsh 衍生物账本**（回收站 / 备份快照 / 调试沙箱 / fetch 临时 / 实例注册表陈旧项 / 启动日志的体积与份数，`--json` 可用）。
  **默认只列不删**；`--purge <类>` 才是真删，四道守卫：备份与 fetch 类**必须**给 `--older-than Nd`（备份是资产、fetch 可能正在下载）、没有 `--yes` 只预览、回收项小于 `RDSH_TRASH_KEEP_DAYS`（默认 7 天）要 `--force`、路径必须在白名单内。
  `--purge debug` **拒绝执行**并指向 `rdsh debug rm`（后者会先停实例、且只认带清单的环境）——不让新命令绕过既有安全逻辑。
- **`rdsh trash ls | restore <条目名|--last> [--force]` —— 带清单的回收站**。
  条目布局 `$TRASH_ROOT/<时间戳>-<标签>/{.rdsh-trash.kv, <被移动的东西>}`：清单记原路径、体积、原因、跨设备标记与**逐项还原命令**；同一次操作可带多个来源（如 `debug rm` 的 home + 清单文件）。
  `restore` 按清单逐项还原，**目标已存在则跳过不覆盖**（`--force` 才腾位）；还原后条目目录保留作痕迹（`restored_at` 写进清单）。
- **回收站默认改到 `$BASE/.dsh-suite/trash`（与 `BASE` 同文件系统）**：旧默认 `/tmp` 跨设备 `mv` 会退化成"复制+删除"，且 `/tmp` 可能是 tmpfs（≈内存），搬 GB 级目录有 OOM 风险。运行时检测到跨设备会**明说后果**并建议改 `TRASH_ROOT`。
- 新增 `tools/smoke-du.sh`（33 项断言）并接入 CI。

### 变更

- **原则修订（如实写进 README 与架构文档）**：原"永不 `rm`"改为"**默认永不 rm**"。唯一的真删路径是 `rdsh du --purge`（全脚本仅此一处 `rm -rf`），且带上面那四道守卫。
- `trash_mv` 统一了原先散落的回收实现（`debug rm` 此前自己拼 `/tmp/rdsh-trash-debug-*` 路径、无清单无索引）。
- `rdsh base` 多打一行回收站及其"是否同文件系统"。

### 修复

- **`ls … | wc -l` 的 pipefail 陷阱**（本批踩到）：glob 无匹配时 `ls` 退 2 → 管道失败 → `set -e` **静默退出**（rc=2、零输出）。改用 `du_count` 逐项判断存在性。
- 分类体积不再拿**父目录**充当（曾把整个 `MANAGE_ROOT` 的 6.7G 报成 "fetch 临时"的体积）。
- `du_size` 对不存在的路径返回 `0` 而不是 `-`。

## 0.4.1 — 2026-09-29

### 新增

- **`rdsh doctor`（`doctor.sh`）—— 一键只读体检，九个维度**：检出（版本/`node_modules`/`.installed` 回声/`.git/info/exclude`）、数据 home（存在/权限/体积）、**软链完整性**（断链 + 分叉；`profiles/node_modules` 那类**插件加载链**单独点名，因为断掉会让插件全部 failed to import）、插件一致性、状态账本（对象/角色合法性/路径存在性/baseline 是否真的可用/回声是否与账本一致）、运行实例（含"同一 `DSH_HOME` 双开"检测）、启动日志（权限 + `failed to import` 扫描）、磁盘与内存余量、配置解析。
  - **必报"检查了几个对象"**，总数 0 时报 error —— 拒绝"零检查却报全绿"（路线图已知风险条目）。
  - **退出码 = 最高严重度**（0/1/2），`--json` 输出可被 `json.load` 解析，供 restore/retire/migrate 程序化消费。
  - **全程只读**：冒烟测试对整个临时 BASE 做前后逐字节比对来证明这一点。
- **`rdsh state sync [<目标>|--all]`**：把账本回写成各检出的 `.installed`（刷新回声）。

### 变更

- `rdsh doctor` 走 `rdsh` 转发（与 `rdsh patch` 同一形态）；`tools/publish.sh` 白名单加 `doctor.sh`（计数改为动态）。
- doctor 的"回声陈旧"改为**比内容**（`key`/`role`）而非比流水行号 —— 后者任何单对象事件都会让其它回声落后一位，属于会天天报噪声的伪问题。
- CI 增加 `tools/smoke-doctor.sh` 一步（16 项断言）。

### 修复

- "查了但不存在"也算检查过 1 个对象（账本未播种 / 无插件权威 / 无日志目录 / 无 `ss`）—— 否则 `--only state` 在未播种的机器上会误报"零检查"。

## 0.4.0 — 2026-09-29

### 新增

- **`rdsh state` —— 状态账本（唯一权威）**。回答"谁是什么角色"，并消掉此前三份手写状态必然漂移的债：
  - **权威** `$BASE/.dsh-suite/state/versions.kv`（原子替换 `tmp`+`mv`，600；目录 700）；**流水** `state/journal.log`（**只追加**，`时间｜事件｜对象｜细节`）；**回声** 各检出里的 `.installed`（仍是"已构建"判据，但内容升级为 KEY=VALUE）；**视图** `$BACKUP_ROOT/回退基线.md`（**生成物**，不再手写）。
  - 角色：`installed` / `current` / `baseline` / `retire-candidate` / `retired`。`rdsh list` 新增角色列。
  - `rdsh state --init`：从现有检出（`.installed` 的 mtime、git remote、HEAD 短 commit）与旧 `回退基线.md` **反向推断**并**逐条打印依据**；旧手写文件 `mv` 进 `state/回退基线-历史.md` 留档（原文不改，打印还原命令）。`--dry-run` 连目录都不建。
  - `rdsh state show/role/render/journal [--init]`，以及给 `migrate.sh` 用的窄接口 `state record-migration`（只追加事件 + 两个字段，**不动角色**——角色由人或"在跑的实例"决定）。
  - 角色推断只认**有依据**的：在跑实例（`ss`+`/proc` 的检出目录 → 账本对象）判 `current`，旧基线 md 的最后一条回退动作判 `baseline`；其余留 `installed`。多个实例同时在跑时**不猜**。
- **`tools/smoke-state.sh` + CI 功能冒烟**：在临时 BASE（复制 `Rdsh.sh` 进去 + `RDSH_CONFIG` 指向临时文件）里跑 47 项断言，并在跑测试前后对**真机** state 资产做逐字节快照比对。

### 变更

- **`migrate.sh` 第 7 步不再手工追加 `回退基线.md`**（该文件已是生成物），改为调 `rdsh state record-migration` 记账再重生成视图；`Rdsh.sh` 不在或账本未播种时**只告警不致命**（迁移不该因为记账失败而失败）。
- 新增派生变量 `STATE_ROOT`（默认可覆盖，见 README 配置表）；`rdsh base` 的输出多一行状态账本。
- `.installed` 会被写进检出的 `.git/info/exclude`（本地、不进上游），避免污染 `git status`。

### 修复

- `rdsh install` / 自动安装完成后写的是**结构化回声**（含 role/commit/source），不再是空文件 `touch`；检出已就绪但账本缺记录时**自愈补登记**（只写事实，不改角色）。
- `state role` 对不存在的对象名会**报错**而不是凭空新建一行幽灵记录；非法角色被拒绝。

### 设计约束（写进代码，不是写在文档里）

- **状态只追加**：`journal.log` 永不改写；删除留墓碑。
- **不替用户定角色**：推断只写有依据的两项，且都打印依据；`state_set_role` 不创建对象。
- **两个 `set -euo pipefail` 陷阱**（本轮实测踩到）：`${#ARR[@]:-0}` 是非法替换；`while read` 读到 EOF 的非零状态在管道 + `pipefail` 下会被当成失败——后者曾让 `state --init` 静默退出。

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
