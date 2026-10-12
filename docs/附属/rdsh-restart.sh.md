# rdsh-restart.sh —— 重启 + 飞轮续转（附属）

> 附属脚本；`rdsh restart` 与 `reboot` 插件都走它。**必须由 `systemd-run --user` 拉起**（否则重启会把自己的父进程杀掉）。

- **能力**：延迟重启（默认 3 秒，可调）+ **飞轮**：重启前把"重启后继续做什么"写进台账 `$DSH_HOME/wake/<会话>.json`，新进程 boot 后由 `reboot` 插件消费 → `agents.resume()` → `followup()`。
- **提供的定义**：唤醒台账的格式（`version/sessionId/prompt/reason/createdAt/maxAttempts/attempts/createdBy`）。
- **提供的证据**：`$BASE/.dsh-suite/logs/restart-*.log` + `$DSH_HOME/wake.log.md`（审计，只追加）。
- **兜底**：台账在重启后仍未被消费 → 用 `dsh --profile headless --session-id` 跨进程接手；**投递后判定单元结果**，失败就在重启日志里明说并**保留台账**（2026-10-12 修，此前是静默失败）。
- **边界**：一次性 headless runner **不认由 agent preset 组成的会话**（实测报 `which the one-shot runner does not compose`）——这类会话只能"在 Web 里手动继续"。
