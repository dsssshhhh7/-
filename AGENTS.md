# Codex 多端协作发行仓库

本仓库只维护 `team-codex` 插件、安装器、验证脚本和用户文档，不放业务代码。

修改规则：

- 保持最小实现，不把同机协作冒充跨机器协作。
- 消息只有“共享账本写入成功 + Codex 原生任务消息发送成功”时才能声称已唤醒送达。
- 自动创建业务端任务必须使用真实 Codex `projectId` 和 `target.type=project`，禁止回退到 `projectless`。
- 更新本地插件时按 Codex cachebuster 流程修改 manifest，再执行 `install.ps1`；复制文件不等于安装成功。
- 交付前至少运行插件校验、Skill 校验、`scripts/verify-install.ps1` 和 `git diff --check`。
- 不提交 `~/codex-team/` 中的个人地址簿、消息、会话 ID 或结案数据。

