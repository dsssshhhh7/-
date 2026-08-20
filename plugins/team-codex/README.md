# Codex 多端协作

这是 `plugins/team` Claude 插件的 Codex 适配版。用户侧保留两种用法：

```text
代号叫 安卓
传给 服务端：这个字段现在下发的是什么？
```

以及：

```text
/team join 外勤-定位上报改造
把字段结论同步给服务端和 iOS
/team close 外勤-定位上报改造
```

## 实现对应关系

| 能力 | Claude 版 | Codex 版 |
|---|---|---|
| 点对点传话 | 文件信箱 + watcher | 文件账本 + Codex 原生任务消息 |
| 空闲窗口自动醒来 | Monitor 事件 | `send_message_to_thread` |
| 在线状态 | watcher 心跳 | Codex `list_threads` |
| 窗口代号可见 | 状态栏 | 任务标题 `【代号】` 前缀 |
| 讨论组/共识/流水/回执/结案 | `cc*` 账本 | 复用并做 Codex 身份适配 |

账本默认位于 `~/codex-team/`，与 Claude 的 `~/claude-team/` 分开，避免两个运行时互相误判在线状态。

## 安装

便携仓库的 marketplace 位于 `.agents/plugins/marketplace.json`。推荐从仓库根目录运行 `install.ps1`，安装器会把插件注册为 `team-codex@personal`。安装或升级后必须新建 Codex 任务；已经打开的任务不会热加载新 Skill。

安装后可以直接说自然语言，也可以显式选择 `team-codex:team` Skill。

## 自动创建各端任务

`/team join` 只让当前任务入组，不会自动创建其他端。用户明确要求总控自动创建时，总控必须先从 Codex 项目列表取得对应 `projectId`，再以 `project` 类型创建任务。禁止回退为 `projectless`，否则任务只会落在“最近”而没有正确的工程文件上下文。

代号使用“需求号-端”，例如 `RM316-Java`、`RM316-PHP`、`RM316-安卓`；组名使用需求号 `RM316`。创建后必须复核任务的 `projectId`。Git 项目默认使用隔离 worktree；用户明确要求直接使用项目目录时才使用 local 环境。

## 依赖

- Codex desktop 或提供任务管理工具的 Codex 环境
- Git Bash（Windows）或系统 Bash（macOS/Linux）
- 核心收发不依赖 `jq`；装了它可兼容少量 Claude 遗留诊断命令

## 不伪装的边界

- 当前仅同一台机器；没有中心服务，所以不宣称跨机器。
- 对方正在执行长工具调用时，消息会排队，不能承诺硬性 5 秒。
- Codex Hook 不能在空闲时开启新 turn，真正唤醒只走原生任务消息。
- Codex 没有 Claude Code 的可编程状态栏，改用任务标题显示代号。

## 开发验证

仓库根目录提供 `scripts/verify-install.ps1`，用于核对 Personal marketplace 中的真实 `installed`、`enabled` 和版本状态。开发者仍应使用 Codex 的 plugin/skill validator 校验源码结构。

账本回归使用临时 `TEAM_ROOT`，不得污染真实的 `~/codex-team/`。
