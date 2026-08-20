# Changelog

## 1.0.3 - 2026-08-18

- 自动创建各端任务时强制绑定真实 Codex 项目并复核 `projectId`，禁止回退到 `projectless`。
- 明确 `/team join` 只处理当前任务，以及多需求并行时使用“需求号-端”的唯一代号。
- 修复用户安装脚本只复制文件、未执行 `codex plugin add` 的问题；现在会核对真实安装状态并完成 Personal marketplace 安装。

## 1.0.2 - 2026-08-18

- 修正 Codex 注销代号后仍提示 watcher 下班的遗留文案。

## 1.0.1 - 2026-08-18

- 增加 `ai_dev_full` SessionStart 自动安装/更新入口和幂等用户安装脚本。
- 消除 Codex 命令输出中“watcher 已在线”“账本写入即送达”等误导性表述。
- 移除核心收发对 `jq` 的依赖，并补充真实安装后的自然语言触发验收。

## 1.0.0 - 2026-08-18

- 复用 Claude team 的组、共识、流水、回执、补课和结案账本。
- 使用 `CODEX_THREAD_ID` 作为任务身份，数据独立放在 `~/codex-team/`。
- 用 Codex 原生任务消息替代 watcher，实现 idle 任务唤醒和双向传话。
- 用任务标题前缀替代 Claude 状态栏代号。
- 增加 Codex SessionStart hook、路由 JSON 桥和真假送达门槛。
