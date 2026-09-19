# Changelog

本文件记录 rdsh 的显著变更。日期为实测/提交日期。

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
