

---

## 从 README 迁入的原文（逐字保留）

## 装到新机器（自举安装，0.8.0 起）

新机器上还**没有** rdsh 时，用它自己的入口：

```bash
# 1) 取到本体（离线可用 --from <已 clone 的目录|tarball>）
bash bootstrap.sh --base "$BASE"

# 2) 顺手装一个 dsh（可选）
bash bootstrap.sh --with-dsh latest

# 想先看计划：bash bootstrap.sh --dry-run
```

七步：**依赖自检**（缺谁点名并给安装命令）→ **取本体**（clone 默认 SSH、失败自动试 HTTPS；目标已是 git 检出则 `pull --ff-only`，幂等）→ **建目录**（`.dsh-suite/{data,shared,backup,logs,state,run,debug,plugins,patches,trash}`）→ **写配置**（`~/.config/rdsh/config`，**只补缺键、绝不覆盖已有值**，显式写全套根以对齐 `.dsh-suite/` 布局）→ **落入口**（`<检出>/rdsh` + `~/.local/bin/rdsh`；**已存在的一律不动**，要替换得显式 `--force`，入口没落成会以退出码 4 报出）→ **可选装 dsh** → **验收**（`rdsh base` / `doctor` / `bridge --spec`）。日志落 `<BASE>/.dsh-suite/logs/bootstrap-<ts>.log`。

之后自更新用 `rdsh selfupdate`：**先备份回滚点**（`dsh-scripts-<ts>/` + `MD5SUMS`）→ **先校验**（语法 + 隐私守卫 + 冒烟，都在源目录里跑、不碰本机）→ **原子替换**（临时名 + `mv`，运行中的脚本靠 inode 续命）→ **失败自动回滚**。校验不过**一个字节都不装**。
