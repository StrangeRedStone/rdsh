# plugins.d —— rdsh 的外部能力目录

放这里的**可执行文件**就是 rdsh 的一个外部能力（插件）。

- 自报家门：`<文件> --manifest` 输出 `iface=1` + 若干 6 字段能力行（`id|子命令|参数|风险|默认参数|简介`）
- 自检：`rdsh selfcheck`
- 完整格式与约定：仓库里的 `docs/外部能力.md`（部署目录不随附 docs）
- 参考实现：`session-archive.sh`（会话历史档案库）、`rdsh-migrate.sh`（迁移前门）、`rdsh-dvd.py`（通用 DVD±R/RW 数据刻录/rdsh 数据备份）

## 迁移提供者（特化脚本）的约定

`rdsh-migrate.sh` 只做迁移流程；版本差异交给 `$MANAGE_ROOT/` 下的提供者脚本：

- 通用版：`$MANAGE_ROOT/migrate.sh`（原名原位，应急可直接跑）
- 特化版：`$MANAGE_ROOT/migrate-<from>-to-<to>[-<id>].sh`（**与通用版同目录**，一次性，用完可删）
- 特化版文件头必须有一行：
  `# rdsh-migrate: from=<ver> to=<ver> id=<id> items=<csv> summary=<一句话>`
- 不新建 registry；前门扫描该目录 + 文件头识别。详见 skill `migrate-specialize`。
