# 工作原理

本文记录 Sea Coffee 读取的每个数据来源、判断规则和安全边界。所有接口均为只读查询，不发送模型请求。

## 额度来源

各来源并行、独立刷新：一方登录、退出或查询失败不会清空另一方的数据。查询失败时保留旧值并提示；数据超过一定时间未更新时圆环减淡（Codex / Cline 3 分钟，Claude / Grok 5 分钟）。

### Codex API（Sub2API）

- 请求 `GET <站点>/v1/usage`，`Authorization: Bearer <API Key>`。站点地址可填写控制台地址或 OpenAI 兼容的 base URL，会被规范化为 `/v1/usage`；仅接受 HTTPS（本机地址除外）。
- 支持三种计费模式：钱包余额、Key 总额度（`quota`）、订阅窗口（`subscription` 的每日 / 每周 / 每月及 `rate_limits`）。
- 钱包百分比 = 余额 ÷ 手动设定的满格基准，限制在 0–100%，金额保留真实值。
- 每 60 秒刷新，任务结束后补刷一次。

### Codex 官方

- 启动已安装的 `codex app-server`，通过 JSON-RPC 调用 `account/login/start`（浏览器登录）和 `account/rateLimits/read`。
- 使用独立的 `CODEX_HOME=~/Library/Application Support/SeaIsland/OfficialAccount`，并移除 `OPENAI_API_KEY` 等环境变量，不影响现有 Codex 登录或中转配置。凭据由 Codex CLI 管理。

### Cline Pass

- 额度接口：`GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`，响应 `{success, data: {limits: [{type, percentUsed, resetsAt}]}}`，窗口为 `five_hour`、`weekly`、`monthly`。
- **API Key（推荐）**：`Authorization: Bearer <key>`，与 CodexBar 的做法相同。填写 Key 后优先使用。
- **设备码登录**：WorkOS device authorization → `POST /api/v1/auth/register`，之后用 `/api/v1/auth/refresh` 轮换令牌；请求头为 `Bearer workos:<accessToken>`（与 [Cline SDK](https://github.com/cline/cline) 的 `getAuthToken()` 一致，直接发送原始 JWT 会返回 401）。登录页域名限定为 `cline.bot` / `workos.com`。
- 轮换后的刷新令牌若暂时无法写入，会留在内存中并在下次读取前重试，避免重复使用已作废的旧令牌。
- 不会把按量付费的钱包余额当作 Cline Pass 配额。

### Claude

- 复用本机 Claude Code 的 OAuth 登录：先读 `~/.claude/.credentials.json`，再通过 `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` 读取钥匙串。
  - Claude Code 用 `security` 工具写入该项，因此项的访问列表信任它（`apple-tool:` 分区），读取不弹窗，也不受 Sea Coffee 重新编译影响。
  - 仅当上述方式失败时，才回退到钥匙串 API，并且只在用户点击时允许系统弹窗。
- 请求 `GET https://api.anthropic.com/api/oauth/usage`，请求头 `anthropic-beta: oauth-2025-04-20`。映射 `five_hour`、`seven_day`、`seven_day_sonnet`、`seven_day_opus`；没有 `utilization` 的窗口视为未知。
- 需要 `user:profile` 权限；`claude setup-token` 生成的令牌不可用。
- 只读不写、从不刷新令牌（刷新会轮换 Claude Code 的刷新令牌，导致其登录失效），令牌仅保存在内存。过期时提示在终端运行一次 `claude` 续期。
- 每 2 分钟查询一次，遇到 429 按 `Retry-After` 退避。

### Grok

- 读取 `grok login` 写入的 `~/.grok/auth.json`（支持 `GROK_HOME`），优先 `https://auth.x.ai::` 条目。不涉及钥匙串。
- 请求 `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`，请求头 `x-xai-token-auth: xai-grok-cli`。读取 `config.creditUsagePercent`，缺失时用 `onDemandUsed / onDemandCap`；重置时间取 `currentPeriod.end`，否则 `billingPeriodEnd`（起止时间不混用两个周期）。只返回周期、没有用量时显示为未知。
- 套餐名来自 `GET /v1/settings` 的 `subscription_tier_display`，失败时不影响额度显示。
- 只读不写、不刷新令牌；Grok 令牌有效期较短，过期时提示运行一次 `grok` 续期。每 2 分钟查询一次。

## 任务状态

每 2 秒扫描一次，只考虑最近两天修改过的文件，每个工具最多 100 个会话；长文件只读取末尾 4 MB，之后增量读取，不完整的行不会被当作事件。启动时不提示历史上已经完成的任务。运行中超过 45 分钟没有任何事件时视为“未知”，不会被当成成功。

| 工具 | 文件 | 开始 | 完成 | 中断 / 失败 |
|---|---|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | `task_started` / `turn_started` | `task_complete` / `turn_complete` | `turn_aborted` 等 / `task_failed` 等 |
| Claude Code | `~/.claude/projects/*/*.jsonl` | 用户消息 | `stop_reason: end_turn` | `[Request interrupted by user` / `refusal` |
| Grok | `~/.grok/sessions/*/*/events.jsonl` | `turn_started` | `turn_ended outcome=completed` | `cancelled` / `error` |
| Cline | `~/.cline/data/sessions/*/session_*.json` | `starting` / `running` / `pending` / `stopping` | `completed`，或从运行回到 `idle` | `cancelled` / `failed`、`error` |

- Claude Code 忽略子代理（`isSidechain`）和 meta 记录，子代理目录中的文件也不单独计数；同一条消息被拆成多行时只计一次完成。
- Codex 续聊会写回原创建日期的目录，因此按修改时间而非目录日期发现文件。
- 只保留事件类型、时间和项目目录名，对话内容只在解析时经过内存，不保存、不上传。

## 凭据存储

- 文件：`~/Library/Application Support/SeaIsland/credentials.json`，目录 `0700`、文件 `0600`；拒绝符号链接和不属于当前用户的文件，权限被放宽时自动收紧。
- 写入：在同目录的私有临时目录中以 `O_EXCL` 创建文件，`fsync` 后原子重命名，失败时保留原文件；保存后重新读取核验。
- 为什么不用钥匙串：没有 Apple Developer Team ID 时，登录钥匙串的分区列表只能按二进制 cdhash 识别应用，每次重新编译或更新都会失去访问权。文件存储与 Codex、Claude、Grok 的 CLI 凭据处于同一保护级别（同一用户下的其他进程也能读取）。
- 旧版本存于钥匙串的凭据会在首次读取时导入：后台只做不弹窗的读取；读不到时提示在设置中点击“授权读取已存凭据”。读取失败不会被当作“没有凭据”，只有成功导入或确认不存在后才标记完成，之后不会再用旧条目覆盖新值。
- 后台钥匙串访问同时使用 `LAContext.interactionNotAllowed` 与 `SecKeychainSetUserInteractionAllowed(false)`；后者是进程级开关，因此所有钥匙串操作由同一把锁串行执行并在结束后恢复原设置。
- 构建时可用 `SEACOFFEE_SIGNING_IDENTITY` 指定签名证书，或在 `~/Library/Application Support/SeaCoffee/Signing/identity.json` 中写入证书 SHA-1 指纹；配置存在但证书不可用时构建失败，未配置时使用 ad-hoc 签名。

## 界面与动效

- 左侧：运行中橙色、完成绿色、失败或中断红色、空闲灰色；数字为正在运行的唯一对话数。
- 右侧：各额度的剩余百分比，≥50% 绿、20–49% 黄、<20% 红、未知灰。最多四项时排成 2×2。
- 悬停即以阻尼弹簧展开；移开不等待，以 180 ms 缓出收起，重新进入可直接反向展开。浮层不激活应用，只有鼠标位于岛区域时接收点击，透明区域穿透。
- 完成动效：岛保持顶部固定，两侧收拢、下沿延伸为与刘海等宽的黑色背景，白色轮廓向内立体翻转后描出对勾，再展开恢复，共约 3.3 秒；减少动态效果时静态显示 1.35 秒。失败与中断使用文字提醒，多个结束事件排队展示。
- 动效顺序参考了 Apple Pay 与 Face ID 的公开演示（先立体翻转、后描勾），刘海两侧合拢为本项目设计，并非逐帧复制。
- 导出同一套参数的动效预览：`dist/Sea\ Coffee.app/Contents/MacOS/SeaCoffee --render-motion dist/motion-preview.gif`。

## 已知边界

- 任务监听依赖各工具的本地文件格式，不是官方事件订阅；只有明确的结束事件才提示完成，不推断进度，也不判断“等待审批”。
- 多屏时优先选择带刘海的屏幕，暂不支持手动选屏；全屏与多 Spaces 下的行为可能因机器而异。
- 暂不支持组织套餐、多账号、开机自启与自动更新。
