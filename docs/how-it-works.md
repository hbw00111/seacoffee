# 工作原理

本文记录 Sea Coffee 读取的每个数据来源、判断规则和安全边界。所有接口均为只读查询，不发送模型请求。

## 用量与历史

设置“用量”分为调用统计和额度趋势。调用统计对齐 CC Switch 4.0 的“使用统计”，算法照搬其源码（`usage_stats.rs`、`calculator.rs`、`components/usage`），在 `IslandCore/UsageAnalytics.swift`、`ModelPricing.swift`、`UsageFormat.swift` 里实现并有检查：

- **读取**：`UsageStats.read()` 以 SQLite 只读方式打开 `~/.cc-switch/cc-switch.db`，读取全部 `proxy_request_logs` 明细（CC Switch 保留约 30 天）、全部 `usage_daily_rollups` 按天汇总、`model_pricing` 价格表和服务商名称。只取数值、时间、模型与服务商标签，不读取提示词、错误正文或凭据。本机约 1.7 万条明细读取约 0.2 秒，之后的筛选与汇总都在内存里完成。
- **去重与合并**：会话日志行（`session_log`、`codex_session`、`gemini_session`、`opencode_session`）若在 ±600 秒内有一条 Token 相同、模型相同的成功代理请求，就不再计数。`claude-desktop` 并入 `claude`。按天汇总只计入时间范围完整覆盖的本地日期（`compute_rollup_date_bounds`），与明细相加。
- **Token**：`input_token_semantics` 归一化缓存（Codex、Gemini、Grok Build：legacy 扣 cache read，total 扣 read + write，fresh 不扣）；真实消耗 Tokens = 新增输入 + 输出 + 缓存创建 + 缓存命中；缓存命中率 = 缓存命中 ÷ (新增输入 + 缓存创建 + 缓存命中)。请求日志的“新增输入”列沿用 CC Switch 前端的算法，只扣 cache read。
- **花费**：用 CC Switch 记录的 `total_cost_usd`。记录为 $0 但有 Token 的行，按 CC Switch 的回填规则在内存里重新计价（不写回数据库）：计价模型取 `pricing_model`，否则 `model`，`model` 为占位时取 `request_model`；模型名按其规则归一化（去厂商前缀、`:后缀`、`[1m]`、日期与版本后缀、推理强度后缀等），先精确匹配，再按家族规则做前缀匹配；`Decimal` 计算，倍率只乘总额。仍找不到价格的成功请求显示“未定价”，不计入总额；失败请求、无 Token 或倍率为 0 的行是真实的 $0。
- **速度（tok/s）**：单条 = 输出 Token ÷ ((`latency_ms` − `first_token_ms`) / 1000)，要求有首字时间、输出 ≥100、生成时间 ≥100 ms；没有首字时间的会话日志行若输出 ≥200、耗时 ≥1 秒，显示“≈”估算值（输出 ÷ 总耗时）。供应商与模型表格用合格行的总和之比，按天汇总不参与。
- **时间范围**：当天（本地 0 点起）、近 24 小时、近 7 / 14 / 30 天（从 N−1 天前的本地 0 点起）、全部。≤24 小时按小时分桶（从范围起点量起），否则按本地日期。
- **分组**：供应商按（`provider_id`，应用），名称取 `providers.name`，会话来源显示为“Claude (Session)”等；模型按 `pricing_model`（为空时用 `model`）分组。表格按请求数排序，每页 20 条；成功 = 状态码 200–299。
- **热力图**：周一开头、每段 53 周，数值为每天的 Tokens / 请求 / 成本；等级按过去非零日的 25 / 50 / 75 百分位分 5 档，未来日期不参与。

“DSH 记录”页不经过 CC Switch：`DshStore` 读取 `~/.dsh/storages/session_projcache/sessions/session-<id>.json`，这是 DSH 自己写的会话投影（原始事件日志是 zstd 压缩的 JSONL，不读）。每个会话取轮次、步数、Token 总量（未命中输入 / 输出 / 缓存读取 / 缓存创建）、模型时间、工具时间、首字时间、解码时长与解码 Token；速度 = 解码 Token ÷ 解码时长，首字 = 首字总时长 ÷ 有首字记录的步数，与 DSH 自己界面上的统计同源。文件每 200 个事件或 5 秒落盘一次，数字可能晚几秒；空白会话（没有轮次也没有 Token）不列出。

`QuotaHistoryStore` 将成功额度查询的数值快照保存到应用支持目录 `SeaIsland/quota-history.json`，每服务商每 15 分钟保留最新一次，保留约 31 天，文件权限 0600。原子写入与跨进程文件锁保护独立版和 Droppy 重叠运行；历史损坏时保留原文件并提示。历史不保存密钥或对话。没有旧额度历史可回溯，首次启动后才开始记录；充值、重置、账号切换都可能改变曲线，不据此推算账单。超过 30 分钟的采样间隔和额度周期变化分段显示。

用量页打开期间每 60 秒重新读取本地数据，也可手动刷新，不额外触发额度网络查询。报告与热力图在后台生成不可变结果，筛选项在读取时算好一次。页面拆成相互独立的视图：趋势图的悬停只更新竖线和读数（悬停状态放在图表之外，柱子不重建）；热力图用一块 Canvas 画出全部格子，悬停只重画这块画布；表格的翻页、状态筛选和详情弹窗只重画表格本身。快速切换筛选会丢弃过时结果，设置窗口保留数据模型，一分钟内重新进入复用记录。

## 额度来源

各来源并行、独立刷新：一方登录、退出或查询失败不会清空另一方的数据。查询失败时保留旧值并提示，没有数据时展开面板写“额度没查到 · 原因”。刷新间隔在“外观与交互”中设置（1 / 2 / 5 / 10 / 30 分钟，默认 5 分钟，与 CC Switch 一致），任务完成时也会刷新；Claude / Grok 两次查询至少间隔 2 分钟。连续错过两次刷新（间隔 × 2 + 1 分钟，且不少于 Codex / Cline 3 分钟、Claude / Grok 5 分钟）后额度指示减淡，展开面板标注“待更新”。

### Codex API（Sub2API）

- 请求 `GET <站点>/v1/usage`，`Authorization: Bearer <API Key>`。站点地址可填写控制台地址或 OpenAI 兼容的 base URL，会被规范化为 `/v1/usage`；仅接受 HTTPS（本机地址除外）。
- 支持三种计费模式：钱包余额、Key 总额度（`quota`）、订阅窗口（`subscription` 的每日 / 每周 / 每月及 `rate_limits`）。
- 钱包百分比 = 余额 ÷ 满格基准，限制在 0–100%，金额保留真实值。
- **充值自动更新基准**：每次查询都会记下余额（按站点区分）。本次余额比上次多出半美分以上，就视为充值；若新余额与当前基准不同，基准自动改为新余额，额度回到满格，状态栏提示“检测到充值，满格基准已更新为 $…”。余额超过旧基准半美分以上时也会纠正基准，覆盖旧版升级、缺少历史记录或错过充值的情况。余额不超过基准时，消费、余额不变、第一次查询或换站点不会改变基准；充值后即使余额低于旧基准，只要比上次余额增加，仍会更新。设置页打开时会同步显示新基准，避免保存时被旧值覆盖。只对钱包模式生效，Key 限额与订阅窗口使用服务端总额度，不受影响。
- 按设置的刷新间隔查询（默认 5 分钟），任务结束后补刷一次。

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
- 不发后台请求续期：`claude auth status`、`claude doctor`、非交互 `/status` 都不访问服务器，不会续期。2026-09-28 实测一次后台 `claude -p`：刷新令牌已失效时，CLI 续期失败后会**清空自己保存的登录**，因此不用 `claude -p`。
- 每 2 分钟查询一次，遇到 429 按 `Retry-After` 退避。
- 令牌过期时的 `/usage` 兜底（参考 CodexBar 的 CLI PTY 方式，`ClaudeUsageProbe` + `IslandCore/ClaudeUsageScreen`）：
  - 在 `~/Library/Application Support/SeaIsland/ClaudeProbe` 里用 `openpty` 启动交互式 `claude --allowed-tools "" --strict-mcp-config --settings '{"disableAllHooks":true,"remoteControlAtStartup":false}'`，去掉继承的 `CLAUDE_CODE_*` 环境变量；看到输入提示后输入 `/usage` 回车，不发任何提问。文件夹信任提示只会出现在这个专用目录，出现时回车确认。
  - Claude Code 启动时会自己续期过期的令牌并写回钥匙串；Sea Coffee 随后重新读取凭据，优先用额度接口（重置时间更准确），读不到时才用屏幕结果。
  - 屏幕解析：去掉 ANSI 转义，把光标移动换成空格或换行；`Current session` → `five_hour`，`Current week (all models)` → `seven_day`，含 Sonnet / Opus 的每周行 → 对应窗口；取标题后 3 行内的 `NN% used`（或 `% left`），`Resets 3pm (Asia/Shanghai)`、`Resets Oct 21, 11am` 解析为重置时间，读不懂时视为未知。屏幕多次重绘，以最后一帧为准；读到数值后再等 2.5 秒让每周窗口加载，总超时 30 秒。Team 账号只显示当前会话窗口。
  - 结束时按 Esc、SIGTERM，2 秒后 SIGKILL；删除 `~/.claude/projects/` 下该目录对应的会话文件夹（路径中非字母数字字符替换为 `-`）。Claude Code 自己的 `history.jsonl` 会多一行 `/usage`，`~/.claude.json` 会记下该目录，Sea Coffee 不改这两个文件。
  - 成功后至少 10 分钟、失败后 1 小时内不再自动尝试；用户点击刷新时不受限制。只在 `expired` 时触发，401 被拒（登录被撤销）不触发。

### Grok

- 读取 `grok login` 写入的 `~/.grok/auth.json`（支持 `GROK_HOME`），优先 `https://auth.x.ai::` 条目。不涉及钥匙串。
- 请求 `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`，请求头 `x-xai-token-auth: xai-grok-cli`。读取 `config.creditUsagePercent`，缺失时用 `onDemandUsed / onDemandCap`；重置时间取 `currentPeriod.end`，否则 `billingPeriodEnd`（起止时间不混用两个周期）。只返回周期、没有用量时显示为未知。
- 套餐名来自 `GET /v1/settings` 的 `subscription_tier_display`，失败时不影响额度显示。
- 只读不写，Sea Coffee 自己从不刷新令牌。Grok 令牌约 6 小时过期；过期时在后台运行一次 `grok models`（列出模型后退出，不发起对话、不消耗额度、不产生会话记录），由 Grok CLI 自己续期并写回 `auth.json`，随后重新读取。每 10 分钟最多尝试一次，40 秒超时；仍失败时提示运行 `grok` 或 `grok login`。每 2 分钟查询一次。

## 任务状态

每 2 秒扫描一次，只考虑最近两天修改过的文件，每个工具最多 100 个会话；长文件只读取末尾 4 MB，之后增量读取，不完整的行不会被当作事件。启动时不提示历史上已经完成的任务。运行中超过 45 分钟没有任何事件时视为“未知”，不会被当成成功。

| 工具 | 文件 | 开始 | 完成 | 中断 / 失败 |
|---|---|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | `task_started` / `turn_started` | `task_complete` / `turn_complete` | `turn_aborted` 等 / `task_failed` 等 |
| Claude Code | `~/.claude/projects/*/*.jsonl` | 用户消息 | `stop_reason: end_turn` | `[Request interrupted by user` / `refusal` |
| Grok | `~/.grok/sessions/*/*/events.jsonl` | `turn_started` | `turn_ended outcome=completed` | `cancelled` / `error` |
| Cline | `~/.cline/data/sessions/*/session_*.json` | `starting` / `running` / `pending` / `stopping` | `completed`，或从运行回到 `idle` | `cancelled` / `failed`、`error` |
| Pi（命令行） | `~/.pi/agent/sessions/*/*.jsonl` | 用户消息，`stopReason: toolUse` | `stopReason: stop`（或 `length`） | `aborted` / `error` |
| PI-Desktop | `~/.pi-desktop/pi.sqlite` 的 `turns` 表 | `status = running` | `completed` | `aborted` / `error` |
| DSH | `~/.dsh/storages/session_projcache/sessions/session-*.json` | `turnBoundary.openTurnStartSeq` 或 `sessionStats.openStep` 存在 | 轮次结束（`turn/end`） | 无（DSH 的投影只记录边界，不记录结果） |

- Claude Code 主对话忽略子代理（`isSidechain`）和 meta 记录，也忽略本地命令写下的用户行（`<command-name>`、`<local-command-…>`、`<bash-input>` / `<bash-stdout>` 等，来自 `/context`、`/compact` 与 `!` 命令）和 `/compact` 写下的摘要（`isCompactSummary`），它们不会开始一轮回复；会调用模型的命令由随后的 assistant 行标记为运行中。子代理不单独计数；同一条消息被拆成多行时只计一次完成。后台子代理（`<会话>/subagents/*.jsonl`）仍在工作时（最后状态为运行中且 15 分钟内有活动），主对话即使已 `end_turn` 也显示运行中，完成提示推迟到子代理全部结束后再弹出一次；子代理以调用 `SubagentHandback` 交回报告视为结束（它不写 `end_turn`）。
- DSH 的投影缓存是整份重写的 JSON（`record.rows` 里每行是 `{ver, seq, val}`），只在修改时间变化时读取；`sessionStats` 的 `openStep` 与 `turnBoundary` 的 `openTurnStartSeq` 决定是否运行中，轮次结束即视为完成，投影里没有成功 / 失败 / 取消的区分。`userQuestions.questions.active` 里的 `callId` 作为等待回答的标记，回答或消失后清除。空白会话（轮次与 Token 都为 0）保持未知。
- PI-Desktop 不写 Pi 的 JSONL，而是存进自己的 SQLite 数据库。Sea Coffee 以只读方式（`mode=ro`，不用 `immutable`，以便看到最新的 WAL 数据）打开，每次只查询每个会话最新一轮的状态、起止时间、模型和项目名，不读取消息内容；数据库被占用时跳过这一轮，不等待 PI-Desktop。运行中的轮次用会话的 `updated_at` 判断是否仍有活动，长时间运行不会被误判为“未知”。
- Codex 续聊会写回原创建日期的目录，因此按修改时间而非目录日期发现文件。
- 同时记录最近一次作答的模型名，用于完成提示：Codex 取 `turn_context.payload.model`，Claude Code 取 assistant 消息的 `message.model`（忽略错误占位 `<synthetic>`），Grok 取 `turn_started.model_id`，Cline 取会话文件的 `model`，Pi 取 assistant 消息的 `model`，DSH 取 `modelSelection.lastUsed.model`（显示时去掉 `deepseek/`、`cline-pass/` 这类路由前缀）。
- Pi 可以接入多个渠道。模型前缀为 `cline-pass/` 时，完成提示会注明经由 Cline Pass，例如 `Pi · Cline Pass · glm-5.3-flash`；它消耗的额度计入同一个 Cline Pass 账号，岛上的 Cline 额度会随之变化。
- 只保留事件类型、时间、项目目录名和模型名，对话内容只在解析时经过内存，不保存、不上传。

### AI 向你提问

只认各工具明确的“向用户提问”工具调用，只记录调用编号和时间，不读取也不保存问题内容。

| 工具 | 提问标记 | 是否知道“已回答” |
|---|---|---|
| Claude Code | assistant 消息里 `tool_use` 名为 `AskUserQuestion`，取其 `id` | 是：出现同 `tool_use_id` 的 `tool_result` 即已回答；用户中断或本轮结束也视为不再等待 |
| Codex | `response_item` 里 `function_call`，名字以 `request_user_input` 开头，取其 `call_id` | 否：`request_user_input_async` 发出后立刻返回、模型继续执行（真实记录里紧接着就是 `exec`），所以只在提问那一刻提示一次 |

- 弹窗只在“新提问”出现时触发一次：启动前已存在的提问、同一次扫描内就已回答的提问、超过 5 分钟才被读到的提问都不提示；子代理（`isSidechain`）的提问忽略。
- Claude Code 的提问会话保持“运行中”，同时带“等待回答”标记（`SessionState.awaitingAnswer`）：左侧液滴变紫蓝色脉动，展开面板标题写“Claude Code 在等你回答”。运行中超过 45 分钟没有任何事件仍按上文规则转为“未知”，等待标记随之不再显示。
- Grok、Cline、Pi 没有可识别的提问标记（Grok 只有工具权限审批事件，与提问不是一回事），暂不支持。各工具的“等待审批”同样不判断。
- 只有明确的提问工具才算：AI 在回复正文里以问句结尾并结束本轮，仍按普通“完成”处理。

## 凭据存储

- 文件：`~/Library/Application Support/SeaIsland/credentials.json`，目录 `0700`、文件 `0600`；拒绝符号链接和不属于当前用户的文件，权限被放宽时自动收紧。
- 写入：在同目录的私有临时目录中以 `O_EXCL` 创建文件，`fsync` 后原子重命名，失败时保留原文件；保存后重新读取核验。
- 为什么不用钥匙串：没有 Apple Developer Team ID 时，登录钥匙串的分区列表只能按二进制 cdhash 识别应用，每次重新编译或更新都会失去访问权。文件存储与 Codex、Claude、Grok 的 CLI 凭据处于同一保护级别（同一用户下的其他进程也能读取）。
- 旧版本存于钥匙串的凭据会在首次读取时导入：后台只做不弹窗的读取；读不到时提示在设置中点击“授权读取已存凭据”。读取失败不会被当作“没有凭据”，只有成功导入或确认不存在后才标记完成，之后不会再用旧条目覆盖新值。
- 后台钥匙串访问同时使用 `LAContext.interactionNotAllowed` 与 `SecKeychainSetUserInteractionAllowed(false)`；后者是进程级开关，因此所有钥匙串操作由同一把锁串行执行并在结束后恢复原设置。
- 构建时可用 `SEACOFFEE_SIGNING_IDENTITY` 指定签名证书，或在 `~/Library/Application Support/SeaCoffee/Signing/identity.json` 中写入证书 SHA-1 指纹；配置存在但证书不可用时构建失败，未配置时使用 ad-hoc 签名。

## 界面与动效

设置页额度详情直接读取各账号真实 `UsageSnapshot`，展示全部 `quotas`，不使用刘海演示数据或紧凑窗口筛选。钱包基准明确标为比例显示基准。每 30 秒更新过期标记（阈值同上）；此定时器仅重绘，不发起网络查询。重置时间写成 CC Switch 的倒计时“2h30m后重置”（超过 24 小时写“3d12h后重置”），底部写“3 分钟前更新”，精确时间放在悬停提示里；用完的窗口写“已用完”。失败说明沿用同一卡片的连接状态，已有数据保留。

API Key 输入框的已保存摘要由 `CredentialPreview.masked` 生成，仅在编辑值为空时显示；真实前缀为 `sk-` 时保留该前缀，主体至少 16 字符才显示首尾各 4 字符，否则隐藏全部主体。固定八个星号不透露原长度。摘要不进入编辑绑定或保存参数。

- 设置导航采用 SwiftUI `matchedGeometryEffect` 连接选中底板与悬停底板；悬停只反馈位置，不切换分区。导航和接入方式控件提供显式键盘焦点，支持空格和回车激活。
- 共享控件以 `interfaceReduceMotion` 传递应用内设置，并与系统减少动态效果合并，关闭选中态弹簧、按钮缩放与成功图标弹跳。刘海额度行数变化时平滑调整容器高度，减少动态效果时取消该过渡。

- 左侧为液态融球：运行中为橙色，每个正在运行的对话是一颗绕核心公转的小球，靠近时与核心融合、远离时分开，新对话从中心长出（最多 4 颗，超过时旁边显示数字）；完成时收拢为绿色并轻跳，失败或中断为红色并轻抖，空闲为灰色缓慢呼吸。用模糊加 alpha 阈值实现融合，减少动态效果时保持静止。
- 收起时右侧：各账号的小圆环与剩余百分比，颜色与 CC Switch 一致：剩余 ≥20% 绿、<20% 橙、用完红、未知灰。最多四项时排成 2×2。
- 展开面板：顶部是任务摘要，下面是账号列表，用细线分隔、不使用独立卡片。每个账号先显示标题，再按 CC Switch 的规则列出最多两行：第一行是最短的窗口（通常是 5 小时），第二行是其余窗口里剩余最少的一个（Claude 的每周 Sonnet 只在详情里显示），每行左侧是周期与倒计时，右侧是细额度条与等宽百分比；Codex API 只显示总占比，余额放在标题右侧。面板高度按实际行数计算，窗口固定为 520 × 480 pt，内容不能超出可点击区域（由 `check-account-isolation.sh` 检查）。
- 设置窗口 800 × 700 pt，左侧分为“账号与额度”“任务监测”“外观与交互”三个分区；切换分区保留未保存的字段，底部“保存并刷新”始终可见。配色、字号与间距见 `DESIGN.md`。
- 悬停即以阻尼弹簧展开；移开不等待，以 180 ms 缓出收起，重新进入可直接反向展开。浮层不激活应用，只有鼠标位于岛区域时接收点击，透明区域穿透。
- 完成动效：岛保持顶部固定，两侧收拢、下沿延伸为与刘海等宽的黑色背景，白色轮廓向内立体翻转后描出对勾，对勾下方随之淡入完成任务的工具与模型（如 `Claude Code · claude-opus-5-5`），再展开恢复，共约 3.3 秒；减少动态效果时静态显示 1.35 秒。失败与中断使用文字提醒，多个结束事件排队展示。提问弹窗复用同一套动效与时长，只是画的是问号（紫蓝强调色）、下方写的是“工具 · 项目”（如 `Claude Code · seacoffee`），并与完成事件在同一队列里依次展示。
- 动效顺序参考了 Apple Pay 与 Face ID 的公开演示（先立体翻转、后描勾），刘海两侧合拢为本项目设计，并非逐帧复制。
- 开机自启：设置“外观与交互”中的开关直接调用系统的 `SMAppService.mainApp` 注册或移除登录项，立即生效，不经过“保存”；状态始终从系统读回，不另存一份。系统要求批准时显示“打开登录项”按钮；登录项记录的是应用当前所在位置，移动应用后需要重新打开一次开关。
- 导出静态预览：`--render-preview dist/preview.png`（岛的四种状态：运行中、完成、提问、收起）、`--render-settings /tmp/settings.png`（设置三个分区，隐藏用户站点与路径，不读取凭据）。
- 导出同一套参数的动效预览：`dist/Sea\ Coffee.app/Contents/MacOS/SeaCoffee --render-motion dist/motion-preview.gif`，加 `--question` 导出提问版本。

## 应用图标

- 设计源文件为 `docs/icon.svg`（液态一滴 · 奶白），与左侧液态融球同一视觉语言。
- `scripts/make-icon.swift` 用 CoreGraphics + CoreImage 按同一几何重画：AppKit 的 SVG 渲染不支持 SVG 里的融合滤镜，因此同样以“模糊 + alpha 阈值（×32 − 14）”生成融合轮廓，每颗液滴各自的径向渐变模糊后被轮廓裁出。修改图标时请同时更新两者。

## 已知边界

- 任务监听依赖各工具的本地文件格式，不是官方事件订阅；只有明确的结束事件才提示完成，只有明确的提问工具调用才提示提问，不推断进度，也不判断“等待审批”。DSH 的投影缓存是节流写入（每 200 个事件或 5 秒），运行状态与完成提示可能晚几秒，也不区分本轮是成功、失败还是取消。
- 多屏时优先选择带刘海的屏幕，暂不支持手动选屏；全屏与多 Spaces 下的行为可能因机器而异。
- 暂不支持组织套餐、多账号与自动更新。


## Droppy 接入

`Sources/SeaCoffee/DroppyExtension.swift` 在 `SEACOFFEE_DROPPY` 条件下编译。`SeaCoffeeDroplet` 创建同一个 `IslandModel`，将其发布到 Shelf、Live Activity 和 HUD；独立版的 AppDelegate 不进入插件构建。构建脚本把当前源文件复制到被忽略的 `.build/droppy-package`，保持一份维护源代码，再通过官方 SDK 构建脚本链接宿主 DroppyKit.framework。最终插件不携带第二份 SDK。

`SeaCoffeePreferences.shared` 在插件中使用 `com.seacoffee.SeaIsland` 配置域，避免读写 Droppy 的同名偏好；凭据继续使用 SeaIsland 的现有本地存储。账号设置在插件拥有的独立窗口中打开，关闭插件会关闭窗口、取消订阅、停止监听和刷新、清空通知队列并撤下活动。停止后的模型拒绝重新启动查询；监听 generation 失效阻止已排队回调重新触发通知。

通知通过 `noticePresented` 传给宿主；HUD 被宿主拒绝时不强占或重试，任务状态仍在 Shelf 的任务页可见。开发 harness 仅启用演示数据，不开始账号查询、会话扫描或凭据操作。

收起状态持续发布 `LiveActivityState` 并设置 `joinsPersistentActivitySet: true`；无任务也保留额度，只有停用时发布 nil。两翼使用宿主交互宽度，每侧最多两行，显示各来源的首个额度、服务商图标和圆环，左侧同时显示任务指示。未知显示破折号，首次查询显示加载环，过期值减淡并标记时钟；完整周期和错误信息留在 Shelf。模型变更会更新视图和活动辅助功能标题。刷新沿用设置的间隔（默认 5 分钟）和账号节流（Claude / Grok 最短 120 秒）。

插件回归检查：构建暂存目录后，在 `.build/droppy-package` 中设置 `SEACOFFEE_DROPPYKIT_PATH`，运行 `swift run SeaCoffeeDropletChecks`。覆盖真正空闲时常驻、查询结果更新、未知值与停用撤下。harness 设置 `SEACOFFEE_PREVIEW_IDLE=1` 可导出空闲演示预览，仍不访问真实账号。
