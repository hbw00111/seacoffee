# Sea Coffee

一个原生 macOS AI 状态岛。SwiftUI + AppKit，无 Electron，无第三方运行时依赖。

## 运行

需要 macOS 14+、Swift 6 工具链（Xcode Command Line Tools 即可）。

```sh
swift run IslandChecks
bash scripts/build-app.sh
open "dist/Sea Coffee.app"
```

也可以使用 `swift run SeaCoffee`。应用常驻菜单栏，不显示 Dock 图标；菜单栏的星芒图标提供设置、预览和退出入口。构建产物位于 `dist/Sea Coffee.app`，可手动拖到 Applications。

## 使用

- 悬停顶部胶囊立即展开；移开立即开始收起，约 180ms 完成。菜单栏“固定展开”可保持展开。
- 菜单栏“预览动画”预览 5 秒运行和约 3 秒完成动效，运行阶段标为“演示”，完成阶段使用同一动效。真实数据不受影响。
- 设置中已预填 `https://coderteam.icu`。输入服务商的 API Key 和钱包满格基准，点击“保存并刷新”。仅向指定站点调用 `GET /v1/usage`，不发送模型请求；密钥存入 macOS Keychain，拒绝跟随重定向。
- 钱包百分比 = 余额 / 手动设定的基准，限制在 0–100%；金额保留真实值。套餐、Key 限额使用服务端总额度。未知数据不伪装成 0 或 100%。
- Codex 官方账号：切换 Codex 接入方式，点击“连接官方账号”。通过已安装的 `codex app-server` 在浏览器登录，读取官方额度。应用使用独立的 `~/Library/Application Support/SeaIsland/OfficialAccount`，不覆盖现有 Codex 登录或中转配置。官方凭据由 Codex CLI 管理。
- Cline Pass：在设置独立的“Cline Pass”区域点击“连接 Cline 账号”，在浏览器核对设备码并授权。使用 Cline 官方 SDK 同款 OAuth 设备授权流程，不需要 API Key 或安装 Cline CLI。独立保存访问令牌和刷新令牌到 macOS Keychain，支持取消登录和移除本应用的登录凭据。每分钟读取个人套餐的 5 小时、每周、每月剩余百分比；不会把按量钱包余额当作 Cline Pass 配额。
- 本机 Codex：默认递归扫描 `~/.codex/sessions`，按文件修改时间监听最近两天活跃、最多 100 个会话的 JSONL 增量；旧日期目录中的续聊同样纳入监听。开始、完成、失败、中断分别处理；启动时不弹历史完成提示。超过 45 分钟无事件的运行状态视为未知，不视为成功。仅保留项目目录名、事件状态与时间，不持久化或上传对话正文。
- 额度每 60 秒刷新，任务结束补刷。查询失败保留旧值并提示；三分钟以上的数据将减淡圆环。

## 动效

悬停即触发阻尼弹簧展开；移开不等待，以 180ms 缓出动画收起，鼠标重新进入时可直接反向展开。数值圆环缓动。完成时同一块黑色岛保持顶部固定，两侧收拢、下边缘延伸，形成与刘海底部相接、与刘海等宽的黑色背景；内部对勾仍使用原有 72pt 容器和 38pt 绘制尺寸；不再平移到刘海下方，也不留空隙：白色轮廓向里立体翻转，随后描出白色对勾，再展开恢复原岛，共约 3.3 秒；减少动态效果时静态显示 1.35 秒。失败与中断仍使用文字提醒，多个结束事件排队展示。遵循系统“减少动态效果”，也可在设置中主动开启。浮层不激活应用；仅鼠标位于当前岛区域时接收点击，透明区域穿透。

## 第一版边界

- 已实现 Codex 和 Cline 官方登录入口与查询协议。Cline 已完成浏览器登录，并用钥匙串中保存的实际凭据验证账户与套餐配额接口返回 200；Codex 官方真实额度仍需本人登录后验证。
- 本地任务监听依赖 Codex JSONL 格式，不是官方桌面端全局事件订阅。只有明确结束事件才提示完成，不推断任务进度百分比，也暂不判断等待审批。
- 无刘海屏显示顶部胶囊；多屏优先选刘海屏，暂不支持手动选屏。全屏与多 Spaces 行为需在目标机器上进一步验证。
- Cline Pass 仅接入账号和个人套餐额度；任务状态仍只监听 Codex。暂不包含 Cline 任务监控、组织套餐、多账号列表、开机自启与自动更新。
- 本机已配置固定自签证书，未进行 Apple Developer ID 签名或公证；其他机器未配置签名身份时仍使用 ad-hoc 签名。

## 结构

`IslandCore`：额度解析、URL 校验、会话事件状态；`SeaCoffee`：原生界面、浮层、网络、钥匙串、Codex 登录与监听。`Tests` 使用无需完整 Xcode 的独立检查程序，包含不同计费模式及任务生命周期验证。

## 参考

实现为本项目原创。架构与平台接入参考了以下资料，未直接复制其实现代码：

- [NotchAI](https://github.com/Winnie-Wong2026/NotchAI)：AppKit 浮层与本地监测思路。
- [CodexBar Sub2API](https://github.com/steipete/CodexBar/blob/main/docs/sub2api.md)：三种计费模式。
- [Sub2API 路由与响应源码](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/handler/gateway_handler.go)：接口字段。
- [Codex App Server](https://developers.openai.com/codex/app-server)：登录及额度协议。
- [Apple NSScreen](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)：刘海安全区域。

## 状态颜色与动效参考

左侧运行橙色、完成绿色、失败或中断红色，空闲灰色；旁边数字为监听范围内正在运行的唯一对话数，完成、失败和未知状态不计入。右侧额度按显示的剩余百分比独立着色：≥50% 绿色、20%–49% 黄色、<20% 红色，未知为灰色。

完成动效核对了 [Apple Support 的付款演示](https://www.youtube.com/watch?v=cxchWpM_I-0) 131–132 秒片段，按 1/30 秒连续提取 30 帧：131.33 秒开始出现短笔画，约 131.57 秒对勾完成，没有 3D 翻转。另核对 [Face ID 动效参考](https://www.youtube.com/watch?v=PkBNSIeu5BU) 3–4 秒片段：约 3.08–3.42 秒两条轮廓在空间翻转，3.50–3.67 秒描出对勾。后者为第三方参考视频，不宣称是官方原始素材。实现采用这种先立体翻转、后描勾的顺序；绿色方框和刘海两侧合拢为 Sea Coffee 定制，不是苹果动效的逐帧复制。

钥匙串读取在后台等待，macOS 授权提示不会阻塞浮层或动画；原有 Keychain 标识和已存凭据保持不变。

可用 `dist/Sea\ Coffee.app/Contents/MacOS/SeaCoffee --render-motion dist/motion-preview.gif` 导出使用同一套绘制和时间参数的动效预览。


## Cline Pass 接入依据

登录和刷新协议核对自 [Cline 官方 SDK](https://github.com/cline/cline/blob/844c30d7ea3e01df3c036729d8c78a2678275aee/sdk/packages/core/src/auth/cline.ts)，生产环境及公开客户端标识核对自 [环境配置](https://github.com/cline/cline/blob/844c30d7ea3e01df3c036729d8c78a2678275aee/sdk/packages/shared/src/runtime/cline-environment.ts)。采用 WorkOS device authorization → Cline `/api/v1/auth/register`，后续使用 `/api/v1/auth/refresh` 刷新。登录不需要客户端密钥。

配额协议核对自 2026-09-22 的 [Cline 订阅页面](https://app.cline.bot/dashboard/subscription?personal=true)公开前端：`GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`，响应为 `{success, data: {limits: [{type, percentUsed, resetsAt}]}}`，窗口类型为 `five_hour`、`weekly`、`monthly`。该接口是官网使用的接口，未确认有独立的公开稳定性承诺；格式不匹配、未订阅或查询失败时显示错误，不虚构满额数据。所有令牌请求禁止重定向，凭据不写入日志或 UserDefaults。


Codex 与 Cline Pass 现在并行连接、独立刷新。设置中上方是 Codex API（Sub2API）或 Codex 官方账号，下方始终显示 Cline Pass 登录区域。登录、退出 Cline 或切换 Codex 接入方式不会清空另一方的额度。收起时右侧 `API`（官方账号为 `CX`）和 `CL` 两行分别显示剩余比例；展开后分别显示余额和套餐窗口。旧版选中 Cline 的配置会自动恢复 Codex API 接入，同时继续读取原有 Cline 登录凭据。

`bash scripts/check-account-isolation.sh` 验证两路额度、状态、过期标记和退出行为互不覆盖，不访问网络或钥匙串。


Cline 的账户与配额请求使用 `Authorization: Bearer workos:<accessToken>`，与官方 SDK 的 `getAuthToken()` 一致；直接发送原始 JWT 会返回 401。已用实际账号验证 `/api/v1/users/me` 与 `/api/v1/users/me/plan/usage-limits` 均返回 200。401、403 与未保存凭据分别提示，避免将接口权限错误误报为未登录。


## 钥匙串授权

自动刷新只执行不弹窗的钥匙串操作。读取成功后，Sub2API Key 和 Cline 凭据仅在当前进程内缓存；保存、替换、退出账号会更新或清除缓存。保存后的核验始终直接读取钥匙串，不能以缓存冒充保存成功。Cline 后台刷新令牌时若无法保存，新令牌暂留在内存等待授权，避免重复使用已轮换的旧令牌。

需要授权时，在设置中点击“授权读取已存凭据”，由 macOS 显示授权窗口。拒绝或取消后，后台刷新不会反复弹窗；受影响的额度查询可能暂停，原有凭据不会被删除。手动保存、登录和退出账号仍可能需要系统授权。

构建支持 `SEACOFFEE_SIGNING_IDENTITY` 指定固定签名证书。本机已创建 `Sea Coffee Local Development` 自签证书，有效期至 2036-09-19，私钥保存在登录钥匙串且不可导出，仅授权 `/usr/bin/codesign` 使用。证书只在当前用户的代码签名策略下受信任。构建默认读取 `~/Library/Application Support/SeaCoffee/Signing/identity.json` 中的证书指纹；配置存在但证书不可用时构建失败，不会悄悄退回临时签名。未配置的其他机器仍默认 ad-hoc。首次从旧的临时签名迁移到本地证书时，旧凭据可能需要重新授权；之后保持同一证书和 Bundle ID。不会为了省去提示而放宽钥匙串访问控制或将凭据写入明文文件。

运行 `bash scripts/check-credentials.sh` 可在独立临时钥匙串条目上检查缓存、真实读取核验、替换和删除，不接触用户凭据。

本地签名已用两个内容不同、身份相同的测试程序核验：两次构建的 designated requirement 相同，新版本在禁止授权弹窗的条件下成功读取旧版本创建的独立测试凭据，随后清理测试条目。此结果不代表已经替用户授权旧的生产凭据，也不代表 Apple 公证。

后台钥匙串访问同时使用 `LAContext.interactionNotAllowed` 与旧登录钥匙串的 `SecKeychainSetUserInteractionAllowed(false)`。旧接口开关是进程级的，因此本应用所有钥匙串操作（含存在性检查）由同一锁串行执行，结束后恢复之前的设置。只有用户主动保存、登录、退出或点击授权时允许系统交互。测试额外覆盖不同程序身份创建的受限条目，确认连续无权限读取会立即返回而不等待授权。
