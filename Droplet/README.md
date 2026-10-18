# Sea Coffee for Droppy

宿主为 Droppy 16.0.1+ / DroppyKit 1.20.1，macOS 14+。支持 Apple Silicon 和 Intel。

## 构建与安装

在仓库根目录执行 `bash scripts/build-droplet.sh`。脚本固定下载 SDK v1.20.1，可用 `SEACOFFEE_DROPPYKIT_PATH` 指向现成的同版 SDK。最终产物为 `dist/SeaCoffeeDroplet.droplet`。

通过 Droppy → Droplet Store → Local droplets 的 Choose 导入，确认后启用；Shelf → Widgets 中选择 Sea Coffee。本地构建每次启动宿主均需确认。已经加载过的版本更新后要重启宿主。账号与监听设置从卡片齿轮或插件详情页打开。

独立应用与插件共享配置域、凭据和官方账号登录目录。正常使用时只运行一个，避免重复轮询及 Cline OAuth 轮换冲突。插件没有独立浮窗或自启项目，随 Droppy 加载。

## 构建结构

`Package.swift` 是暂存包模板，不在本目录直接构建。脚本复制当前的 IslandCore 和 SeaCoffee 源代码至 `.build/droppy-package`，排除独立应用入口和动画导出程序，以 `SEACOFFEE_DROPPY` 编译扩展。原应用仍用根目录 Package.swift 构建。

仅安装 Command Line Tools 时，Apple 未提供 SwiftUIMacros。`prepare-droppykit.py` 在 `.build/droppykit-clt` 中把 SDK 的三个 Bool ContainerValues `@Entry` 声明显式展开；原 SDK 与宿主不变。插件仍通过官方 SDK 脚本 resiliently 链接，并通过导入符号、框架路径和 minAPI 检查。没有向插件嵌入 SDK 副本。

## 验证

- `swift run IslandChecks`：会话状态机与额度解析。
- `bash scripts/check-account-isolation.sh`：账号隔离、通知传递、停用后停止刷新和通知。
- `bash scripts/build-app.sh`：独立应用回归及 `dist/preview.png`。
- 构建脚本运行官方 bundle 校验，包含 manifest、图标、双架构和 ABI/API 链接检查。
- 在暂存包中用准备好的 SDK `Scripts/run-harness.sh SeaCoffeeHarness -- --shots <目录> --report <报告路径>` 生成模拟界面与协议报告；需设置 `SEACOFFEE_DROPPYKIT_PATH`。Harness 只使用演示数据。

## 界面与边界

Shelf 中提供额度/任务两个页面，未知或未连接状态不伪装成零额度。账号余额、多个额度周期、重置时间和过期状态保留。原有完整账号连接界面在插件自己的窗口中打开，退出应用与开机自启控件不编译进插件设置。

刘海处复用原来的活动液滴；任务完成、提问、失败/中断通过宿主 HUD 的形状与动画显示。原独立版的整个合拢外壳动效不搬入宿主。内置音乐、会议、计时器优先占位；HUD 被拒绝不会重试抢占，当前会话状态保留在任务列表中。

本地安装不等于商店发布。开发时不要把真实凭据、账号截图或个人站点配置放入产物或提交。

## 收起刘海额度（0.1.1）

启用后，空闲也会常驻各账号的首个额度圆环与百分比。刘海两侧各最多两行，左侧保留任务指示；未知显示 —，过期值显示时钟并减淡。更详细的额度周期、余额及连接错误见 Shelf。音乐等宿主内置活动仍可优先占位。

额度每 60 秒轮询，Claude / Grok 的查询最小间隔为 120 秒，任务完成会额外触发刷新。harness 可设置 `SEACOFFEE_PREVIEW_IDLE=1` 检查无任务演示；暂存包支持 `swift run SeaCoffeeDropletChecks` 验证空闲、数据更新和停用生命周期。
