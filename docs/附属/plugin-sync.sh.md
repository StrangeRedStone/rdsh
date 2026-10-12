# plugin-sync.sh —— 插件一致性（附属）

> 附属脚本；比对**权威副本**（`$BASE/.dsh-suite/plugins/`）与各版本 home 副本（`$DSH_HOME/plugins/`）。

- **依赖**：`bash`、`diff`/`cmp`。
- **能力**：`--check` 只比差异 · `--sync <版本>` 权威 → home · `--adopt <版本>` home → 权威。
- **提供的定义**："什么算不一致"（代码不同 / home 缺 / 版本旧）。
- **提供的证据**：每次同步写 `backup/plugin-sync-<ts>/`。
- **工作方式**：**保留目标独有文件**（不覆盖），`--adopt` 有方向守卫。
- **边界（实测）**："旧 home 缺较新才有的插件"属**良性**——回退用的旧 home 不需要补，报告里会写明，别当故障。
