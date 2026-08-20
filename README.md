# Codex 多端协作便携版

这是一个可独立安装的 Codex 多任务协作插件。它让同一台电脑上的多个 Codex 项目任务按代号传话、自动唤醒、加入讨论组、补课、记录共识和生成结案文档。

已在 Windows Codex Desktop 中完成真实验证：

- Java、PHP、Android 任务绑定各自真实 Codex 项目；
- 新项目任务自动发现已安装插件；
- Java → PHP 原生唤醒、一次回复和双向回执闭环；
- 讨论组账本、成员、共识、流水、补课、回执和结案脚本回归。

## 新电脑安装

前提：已安装 Codex Desktop、Git 和 PowerShell 7 (`pwsh`)。

```powershell
git clone https://github.com/dsssshhhh7/-.git codex-team
cd codex-team
pwsh -NoProfile -File .\install.ps1
```

看到“Codex 协作插件已更新”后，关闭旧任务并新建一个 Codex 任务。随后验证：

```powershell
pwsh -NoProfile -File .\scripts\verify-install.ps1
```

预期结果包含：

```text
installed = true
enabled   = true
```

也可以直接把本仓库作为 Codex 项目打开。首次信任项目 Hook 后，它会在任务启动时调用同一安装器。插件更新不会热加载到旧任务，仍需新建任务。

## 最快上手

在 Java 项目任务中：

```text
代号叫 RM316-Java。当前任务只处理 RM316，负责 Java+React。
```

在 Android 项目任务中：

```text
代号叫 RM316-安卓。当前任务只处理 RM316，负责 Android。
```

然后直接传话：

```text
传给 RM316-安卓：请确认 RM316 的字段处理方式并回复一次。
```

点对点传话不需要建组，也不要求输入 `/team`。显式写法 `/team say ...` 与自然语言等价。

多端讨论时，在各端任务分别加入同一个需求组：

```text
/team join RM316
```

完整操作模板和两种建组流程见 [多端协同使用说明](docs/多端协同.md)，精简命令见 [使用手册](docs/使用手册.md)。新电脑安装、更新和数据迁移见 [安装与迁移](docs/安装与迁移.md)，底层机制与限制见 [架构与真实边界](docs/架构与真实边界.md)。

## 目录

```text
.
├── .agents/plugins/marketplace.json   仓库 marketplace 源清单
├── .codex/hooks.json                  打开本仓库时自动安装/更新
├── plugins/team-codex/                完整插件源码
├── scripts/verify-install.ps1         只读安装验收
├── install.ps1                        新电脑安装入口
├── update.ps1                         快进更新并重装
└── docs/                              完整文档
```

## 必须知道的边界

- 当前共享账本位于 `~/codex-team/`，只支持同一台机器上的 Codex 任务互通。
- 把本仓库安装到另一台电脑后，那台电脑可以独立使用；两台电脑之间不会自动互通。
- Codex 用原生任务消息唤醒，不使用 Claude watcher。任务正在执行长操作时，消息会排队，不能承诺固定 5 秒。
- Codex 没有 Claude Code 的可编程状态栏，代号显示在任务标题 `【代号】` 中。
- `/team join` 只让当前任务入组；只有用户明确要求时，总控才会创建其他项目任务。
