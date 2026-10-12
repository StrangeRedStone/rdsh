# doctor.sh —— 九维体检（附属）

> 附属脚本，**不在主脚本 `Rdsh.sh` 里**；`rdsh doctor` 只是转发到它。

- **依赖**：`bash`、`ss`（端口/实例）；对比检出时用 `git`。**全程只读**（`--apply` 除外）。
- **能力**：把全机对象分成 11 类检查 —— ①检出 ②数据 home ③软链 ④入口链 ⑤插件权威↔home ⑥状态账本 ⑦运行实例 ⑧日志 ⑨磁盘内存 ⑩配置解析。
- **提供的定义**："什么是断链 / 入口异常 / 账本不一致"；`--only` 的维度名即取自这套分类。
- **提供的证据**：分级报告（error/warn/info）+ 修复时的**可还原清单** `backup/links-fix-<ts>/links.kv`。
- **工作方式**：只读扫描 → 汇总；`--fix-links` **默认干跑**，`--apply` 才改（改前自动写清单）。
- **变量/开关**：`--only <维,…>`、`--quiet`、`--json`、`--fix-links [--apply]`。
- **示例**：`rdsh doctor`（全量）· `rdsh doctor --only links` · `rdsh doctor --fix-links` → 看分类 → `--apply`。
- **边界（实测）**：① 它读**全量追加式日志**，历史报错会一直出现在 warn 里（判"良性"要看行号是否落在本次启动块）；② 账本第 12/14 列（data/settings **回声**）**不在** `state rebind` 覆盖范围，要手工改；③ home 的 **6 条资产链**（`AGENTS.md`/`skills`/`lessons.md`/`facts.md`/`backlog.md`/`.agent-presets`）**不在**修复范围（`plugins/setup.sh` 只管插件链）。
