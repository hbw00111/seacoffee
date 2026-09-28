<img src="docs/icon.png" width="96" alt="Sea Coffee 图标">

# Sea Coffee

[English](README.en.md) | 简体中文

一个住在 MacBook 刘海里的 AI 状态岛：一眼看到 Codex、Claude Code、Grok、Cline、Pi 的任务是否在跑，以及各家订阅和余额还剩多少。

原生 SwiftUI + AppKit，无 Electron，无第三方运行时依赖。

![Sea Coffee 收起、展开与完成状态](docs/preview.jpg)

## 功能

- **任务状态**：本地监听 Codex、Claude Code、Grok、Cline、Pi（含 PI-Desktop）的会话记录，显示运行中的对话数；任务完成时在刘海处播放对勾动效，并注明是哪个工具、哪个模型完成的（如 `Claude Code · claude-opus-5-5`）；失败或中断时文字提醒。
- **额度与余额**，每家独立刷新、互不影响：

  | 来源 | 显示内容 | 接入方式 |
  |---|---|---|
  | Codex API（Sub2API 中转） | 钱包余额、Key 限额、订阅窗口 | 站点地址 + API Key |
  | Codex 官方 | 5 小时 / 每周额度 | 通过 `codex app-server` 浏览器登录 |
  | Cline Pass | 5 小时 / 每周 / 每月 | API Key，或设备码登录 |
  | Claude | 5 小时 / 每周 / Sonnet、Opus 每周 | 复用本机 Claude Code 登录 |
  | Grok | SuperGrok 本期额度 | 复用 `grok login` 的登录 |

- **隐私优先**：只读取事件类型、时间、项目目录名和模型名，不保存、不上传对话内容；复用其他工具的登录时只读不写。
- 额度圆环：≥50% 绿、20–49% 黄、<20% 红，未知为灰，不把未知伪装成 0 或 100%。
- 遵循系统“减少动态效果”；无刘海屏显示为顶部胶囊。

## 安装

需要 macOS 14+ 和 Swift 6 工具链（安装 Xcode Command Line Tools 即可）。

```bash
git clone https://github.com/hbw00111/seacoffee.git
cd seacoffee
bash scripts/build-app.sh
open "dist/Sea Coffee.app"
```

构建产物位于 `dist/Sea Coffee.app`，可拖到“应用程序”文件夹。应用常驻菜单栏、不显示 Dock 图标；菜单栏的星芒图标提供设置、预览动画和退出。

> 本项目未经 Apple 公证。首次打开若提示无法验证开发者，请在 Finder 中右键应用选择“打开”。

## 使用

打开 **设置**，按需连接各个来源：

- **Codex API**：填写 Sub2API 站点地址、API Key 和钱包满格基准，点击“保存并刷新”。仅调用 `GET /v1/usage`，不发送模型请求。之后每次充值，基准会自动更新为充值后的余额。
- **Codex 官方**：切换接入方式后点击“连接官方账号”。使用独立的 Codex 主目录，不影响你现有的 Codex 登录。
- **Cline Pass**：推荐在 [app.cline.bot](https://app.cline.bot) 生成 API Key 粘贴保存；也可以用设备码在浏览器登录。
- **Claude**：先在终端运行 `claude` 并登录，然后点击“连接 Claude Code”。
- **Grok**：先运行 `grok login`，然后点击“连接 Grok”。
- **任务状态**：默认监听全部五个工具，可逐个关闭。通过 Pi 使用 Cline Pass 时，完成提示会注明渠道，额度也计入 Cline 圆环。

需要开机自动运行时，在设置“外观与交互”中打开“开机自启”（立即生效）。

悬停顶部即展开，移开即收起；菜单栏“固定展开”可保持展开，“预览动画”可查看效果而不影响真实数据。

## 安全与隐私

- 自己保存的凭据（Sub2API Key、Cline 登录或 Key）存放在 `~/Library/Application Support/SeaIsland/credentials.json`，权限 `0600`，原子写入。选择文件而非钥匙串，是因为未使用 Apple Developer ID 签名时，钥匙串授权会绑定到每次构建的二进制哈希，重新编译后全部失效。
- Claude、Grok 的令牌只读、仅保存在内存，从不刷新或写回，不会影响原工具的登录。
- 所有请求拒绝跟随重定向，凭据不写入日志或 UserDefaults。
- Claude、Grok、Cline 的额度接口是各家官网或 CLI 使用的接口，并非公开稳定 API，格式变化时会保留旧值并提示，而不是显示错误数字。

详细的数据来源、协议和实现说明见 [docs/how-it-works.md](docs/how-it-works.md)，当前进度、待办与已知问题见 [docs/progress.md](docs/progress.md)。

## 开发

```bash
swift run IslandChecks                   # 解析、状态机、凭据文件等核心检查
bash scripts/check-account-isolation.sh  # 各来源的额度与状态互不覆盖
bash scripts/check-credentials.sh        # 凭据存储与旧钥匙串导入（使用独立测试条目）
```

- `Sources/IslandCore`：与界面无关的逻辑，包括各家额度解析、会话事件状态机、凭据文件。
- `Sources/SeaCoffee`：界面、浮层、网络请求和各账号接入。
- 检查程序不依赖完整 Xcode，也不会访问网络或你的真实凭据。

欢迎提交 Issue 和 Pull Request，参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 致谢

- [CodexBar](https://github.com/steipete/CodexBar)（MIT）：各服务商额度接口的调研，以及内嵌的服务图标（`ProviderIcon-*.svg`）。
- [NotchAI](https://github.com/Winnie-Wong2026/NotchAI)：AppKit 浮层与本地监测思路。
- [Sub2API](https://github.com/Wei-Shaw/sub2api)、[Codex App Server](https://developers.openai.com/codex/app-server)、[Cline SDK](https://github.com/cline/cline)：接口字段与登录协议。

Codex、Claude、Cline、Grok 的名称和标志归 OpenAI、Anthropic、Cline、xAI 所有，本项目与它们没有任何隶属关系，标志仅用于标识对应的额度来源。

## 许可证

[MIT](LICENSE)
