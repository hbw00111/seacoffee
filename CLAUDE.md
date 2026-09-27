# Sea Coffee 工作规则

Sea Coffee 是 macOS 刘海上的 AI 状态岛：显示 Codex、Claude Code、Grok、Cline、Pi 的任务是否在运行，以及各家额度与余额。项目介绍、当前进度与待办见 `docs/progress.md`，实现细节见 `docs/how-it-works.md`。

## 每次改动都要同步

代码或行为有任何改动，完成后按顺序做：

1. **运行检查**：`swift run IslandChecks`、`bash scripts/check-account-isolation.sh`；动到凭据存储时再加 `bash scripts/check-credentials.sh`。改了界面就 `bash scripts/build-app.sh` 并看一眼 `dist/preview.png`。
2. **更新文档**：在同一次提交里更新 `docs/progress.md` 中受影响的部分（当前状态、已完成、进行中、待办、已知问题）和顶部的“最后更新”日期；行为或接口变了，同步 `docs/how-it-works.md`；用户能看到的功能变了，同步 `README.md` 与 `README.en.md`。
3. **提交并推送**：提交信息写清楚改了什么、为什么；推送到 GitHub（`origin main`），并确认 CI 通过。
4. **推送前检查**：仓库是公开的，确认改动里没有 API Key、令牌、个人邮箱或本机路径。

## 约定

- 只提交自己这次的改动。工作区里别人未提交的改动不要一并提交，也不要回滚；先告诉用户。
- 零第三方运行时依赖：动效、加载、图标、SQLite 读取都用系统框架。
- 复用其他工具的登录只读不写，不刷新它们的令牌。
- 未知数据显示为未知，不伪装成 0% 或 100%。
- 隐私：只保留事件类型、时间、项目目录名与模型名，不保存对话内容。
- 与界面无关的逻辑放在 `Sources/IslandCore` 并补检查（注册到 `Tests/IslandCoreTests/Checks.swift`）；界面与账号接入放在 `Sources/SeaCoffee`。
- 改界面前先读 `DESIGN.md`（如果存在）。
