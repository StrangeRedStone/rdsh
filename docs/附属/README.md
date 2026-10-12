# 附属（rdsh 的"非主体"部分）

> **主体是 `Rdsh.sh`**（见仓库根 [README](../../README.md)）。本目录收的是主脚本**没有实现**、只负责转发或另行调用的东西。
> 每篇的写法固定在八个维度：**依赖 · 能力 · 提供的定义 · 提供的证据 · 工作方式 · 变量 · 命令 · 示例 · 边界（注释要点）**。

| 附属 | 一句话 |
|---|---|
| [doctor.sh.md](doctor.sh.md) | 九维体检 + 断链修复 |
| [migrate.sh.md](migrate.sh.md) | 跨版本迁移（动数据，最需要备份） |
| [bootstrap.sh.md](bootstrap.sh.md) | 自举安装（新机器） |
| [plugin-sync.sh.md](plugin-sync.sh.md) | 插件权威 ↔ home 副本 |
| [patch-manager.sh.md](patch-manager.sh.md) | 上游补丁集 |
| [rdsh-restart.sh.md](rdsh-restart.sh.md) | 重启 + 飞轮续转 |
| [publish.sh.md](publish.sh.md) | 维护者：发布到仓库 |
| [`../外部能力.md`](../外部能力.md) | 外部能力协议（`plugins.d/`） |
| [`../应急启动.md`](../应急启动.md) | rdsh 坏了时的应急卡 |

**为什么放在同一个仓库**（2026-10-12 定）：`tools/publish.sh` 是**白名单单仓库**流程，拆仓库要复制一套发布/守卫/CI，维护面翻倍。等到附属多到需要独立发版节奏，再从这里整体拆出去——那时这组文档已经自成一体，拆的成本很低。
