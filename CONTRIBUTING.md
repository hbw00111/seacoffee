# 参与贡献

感谢你愿意改进 Sea Coffee！

## 开始之前

- 需要 macOS 14+ 与 Swift 6 工具链（Xcode Command Line Tools 即可）。
- 较大的改动（新增服务商、调整凭据处理、改变界面结构）请先开 Issue 讨论。

## 提交前

```bash
swift build
swift run IslandChecks
bash scripts/check-account-isolation.sh
bash scripts/check-credentials.sh   # 修改凭据存储时必跑，会创建并清理一个独立的测试钥匙串条目
```

## 约定

- 与界面无关的解析和状态逻辑放在 `Sources/IslandCore`，并在 `Tests/IslandCoreTests` 中补充检查，注册到 `Checks.swift`。
- 保持零第三方运行时依赖。
- 隐私边界：不保存、不上传对话内容；复用其他工具的登录时只读不写，不刷新它们的令牌。
- 未知数据显示为未知，不伪装成 0% 或 100%。
- 请勿在 Issue、测试或提交中包含真实的 API Key、令牌或账号信息。

## 新增服务商

1. 在 `IslandCore` 中新增协议文件，负责凭据解析与响应解码，并附带基于真实响应结构（去除敏感值）的检查。
2. 在 `SeaCoffee` 中新增账号类，负责读取凭据与定时请求，所有请求禁止跟随重定向。
3. 在 `IslandModel.planLanes`、设置页和 `ServiceStyle` 中接入，并更新 `docs/how-it-works.md`。
