import SwiftUI
import IslandCore

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @State private var site: String
    @State private var baseline: String
    @State private var key = ""
    @State private var deleteKey = false
    @State private var sessionPath: String
    @State private var binary: String
    @State private var reducedMotion: Bool
    @State private var hoverEnabled: Bool
    @State private var result = ""
    @State private var saved = false
    @State private var saving = false
    @State private var hasSavedKey: Bool?
    @State private var keyResult = ""
    @State private var keyError = false

    init(model: IslandModel) {
        self.model = model
        _site = State(initialValue: model.site)
        _baseline = State(initialValue: IslandModel.baselineText(model.baseline))
        _sessionPath = State(initialValue: model.sessionPath)
        _binary = State(initialValue: UserDefaults.standard.string(forKey: "codexBinary") ?? "")
        _reducedMotion = State(initialValue: model.reducedMotion)
        _hoverEnabled = State(initialValue: model.hoverEnabled)
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            SettingsBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    codexSection
                    GlassSection(title: "Cline Pass · 独立连接", icon: ServiceStyle.cline.icon, tint: ServiceStyle.cline.tint) {
                        ClineAccountSettings(account: model.clineAccount)
                        GlassDivider()
                        statusRow {
                            Text(model.clineMessage).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    GlassSection(title: "Claude · 读取 Claude Code 登录", icon: ServiceStyle.claude.icon, tint: ServiceStyle.claude.tint) {
                        ClaudeAccountSettings(account: model.claudeAccount)
                        GlassDivider()
                        statusRow {
                            Text(model.claudeMessage).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    GlassSection(title: "Grok · 读取 Grok CLI 登录", icon: ServiceStyle.grok.icon, tint: ServiceStyle.grok.tint) {
                        GrokAccountSettings(account: model.grokAccount)
                        GlassDivider()
                        statusRow {
                            Text(model.grokMessage).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    GlassSection(title: "凭据存储", symbol: "key.fill", tint: Color(red: 1, green: 0.79, blue: 0.26)) {
                        HStack(alignment: .center, spacing: 14) {
                            caption("API Key 与 Cline 登录保存在仅当前用户可读的本地文件，重新编译或更新后无需重新授权。旧版本存在钥匙串里的凭据，点击右侧按钮授权一次即可导入；Claude Code 的登录属于其他应用，更新后也在这里重新授权。")
                            Spacer(minLength: 0)
                            Button("授权读取已存凭据") { model.authorizeCredentials() }
                            .buttonStyle(GlassButtonStyle(loading: model.authorizingCredentials))
                            .disabled(model.authorizingCredentials || model.clineAccount.busy || model.claudeAccount.busy)
                        }
                    }
                    GlassSection(title: "任务状态", symbol: "waveform.path", tint: ActivityAppearance.running.tint) {
                        SettingRow("Codex 会话目录") { GlassTextField(placeholder: "~/.codex/sessions", text: $sessionPath, monospaced: true) }
                        caption("在本机监听各工具的运行、完成和中断状态，只读取事件类型、时间和项目目录名，不保存或上传对话内容。")
                        HStack(spacing: 14) {
                            ForEach(Agent.allCases, id: \.self) { agent in
                                let style = ServiceStyle(agent: agent)
                                Toggle(isOn: Binding(get: { model.watchedAgents.contains(agent) },
                                                     set: { model.setWatched(agent, $0) })) {
                                    HStack(spacing: 5) {
                                        style.icon.resizable().aspectRatio(contentMode: .fit).frame(width: 12, height: 12)
                                            .foregroundStyle(style.tint)
                                        Text(agent.name).font(.system(size: 12))
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                            Spacer(minLength: 0)
                        }
                        caption("Claude Code：~/.claude/projects　Grok：~/.grok/sessions　Cline：~/.cline/data/sessions　Pi：~/.pi/agent/sessions　PI-Desktop：~/.pi-desktop/pi.sqlite（只读）")
                        GlassDivider()
                        HStack {
                            Text("当前识别到 \(model.running.count) 个运行中任务").font(.system(size: 12.5))
                            Spacer()
                            Button(model.demo ? "结束预览" : "预览完成动画") { model.preview() }
                                .buttonStyle(GlassButtonStyle())
                        }
                    }
                    GlassSection(title: "外观与交互", symbol: "sparkles", tint: Color(red: 0.78, green: 0.62, blue: 1)) {
                        SettingRow("悬停时展开") { HStack { Spacer(); Toggle("悬停时展开", isOn: $hoverEnabled).labelsHidden() } }
                        GlassDivider()
                        SettingRow("减少动态效果") { HStack { Spacer(); Toggle("减少动态效果", isOn: $reducedMotion).labelsHidden() } }
                        GlassDivider()
                        caption("额度圆环：50% 及以上为绿，20%–49% 为黄，低于 20% 为红。左侧橙色运行、红色报错、绿色完成，数字为运行中的对话数。")
                        caption("完成时两侧合拢为与刘海等宽的黑色背景，对勾立体翻转后收回。减少动态效果时改为静态对勾；额度每分钟刷新。")
                    }
                }
                .toggleStyle(.switch).tint(Palette.mint)
                .padding(.horizontal, 26)
                .padding(.top, 46)
                .padding(.bottom, 92)
                .disabled(saving)
            }
            .scrollIndicators(.never)
            // Content fades out under the traffic lights instead of colliding with them.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 40)
                    Color.black
                }
            }
            actionBar
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
        .frame(width: 620, height: 700)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await checkStoredKey() }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkle").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.mint.opacity(0.9), Palette.blue.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(GlassSheen(strength: 2.5).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous)))
                        .shadow(color: Palette.mint.opacity(0.35), radius: 14, y: 5)
                }
                .overlay(GlassRim(shape: RoundedRectangle(cornerRadius: 15, style: .continuous)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Sea Coffee").font(.system(size: 22, weight: .semibold))
                Text("AI 任务状态与剩余额度").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Text("PREVIEW 0.1").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.07)))
                .overlay(GlassRim(shape: Capsule(), intensity: 0.7))
        }
        .padding(.leading, 4)
    }
    private var codexSection: some View {
        GlassSection(title: "Codex 账号与额度", icon: ServiceStyle.codex.icon, tint: ServiceStyle.codex.tint) {
            SettingRow("接入方式") {
                GlassSegmented(options: Provider.allCases, selection: Binding(get: { model.source }, set: { model.select($0) })) { $0.title }
            }
            GlassDivider()
            if model.source == .sub2api {
                SettingRow("站点地址") { GlassTextField(placeholder: "https://你的-sub2api-站点", text: $site).textContentType(.URL) }
                SettingRow("API Key") {
                    HStack(spacing: 8) {
                        GlassTextField(placeholder: hasSavedKey == true ? "输入可替换已有密钥" : "sk-…", text: $key, secure: true)
                        Button("粘贴", action: pasteKey).buttonStyle(GlassButtonStyle())
                            .help("从剪贴板填入 API Key")
                    }
                    .disabled(deleteKey)
                    .onChange(of: key) { _, value in
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            keyResult = ""; keyError = false; result = ""; saved = false
                        }
                    }
                }
                SettingRow("") {
                    HStack(spacing: 7) {
                        if saving {
                            CometSpinner(size: 11, tint: .white.opacity(0.7))
                        } else {
                            Image(systemName: keyStatusIcon)
                        }
                        Text(keyStatusText)
                    }
                    .font(.system(size: 11)).foregroundStyle(keyStatusColor)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(keyStatusText)
                }
                SettingRow("满格基准") {
                    HStack(spacing: 8) {
                        GlassTextField(placeholder: "100", text: $baseline).frame(width: 120)
                            // A detected top-up rewrites the baseline; show it so saving does not revert it.
                            .onChange(of: model.baselineRevision) { _, _ in baseline = IslandModel.baselineText(model.baseline) }
                        Text("USD").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        Spacer(minLength: 0)
                    }
                }
                if hasSavedKey == true {
                    SettingRow("移除已存密钥") {
                        HStack { Spacer(); Toggle("移除已保存的 API Key", isOn: $deleteKey).labelsHidden() }
                    }
                    .disabled(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .onChange(of: deleteKey) { _, _ in result = ""; saved = false }
                }
                caption("余额来自服务商。圆环按余额 ÷ 满格基准计算；套餐和 Key 配额优先使用服务端总额度。")
            } else {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用 ChatGPT 账号登录").font(.system(size: 12.5, weight: .medium))
                        caption("登录将在浏览器完成。独立保存官方登录状态，不改动你现有的 Codex 中转配置。")
                    }
                    Spacer(minLength: 0)
                    Button("连接官方账号") {
                        model.account.binaryPath = binary
                        model.account.connect()
                    }
                    .buttonStyle(GlassButtonStyle(prominent: Palette.mint))
                }
                SettingRow("Codex CLI 路径") { GlassTextField(placeholder: "留空自动查找", text: $binary, monospaced: true) }
            }
            GlassDivider()
            statusRow {
                HStack(spacing: 6) {
                    if model.refreshing { CometSpinner(size: 11, tint: Palette.mint) }
                    Text(model.refreshing ? "正在查询余额…" : model.serviceMessage)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }
    }
    private var actionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                if saving { CometSpinner(size: 12, tint: .white.opacity(0.7)) }
                else if !result.isEmpty { Image(systemName: saved ? "checkmark.circle.fill" : "exclamationmark.circle") }
                Text(result.isEmpty ? (model.source == .sub2api ? "输入密钥后，点击保存并刷新" : "账号登录会自动保存；其他设置请点击保存") : result)
            }
            .font(.system(size: 11.5)).foregroundStyle(saving ? Color.white.opacity(0.55) : saved ? Palette.mint : result.isEmpty ? .white.opacity(0.55) : .red)
            .lineLimit(2)
            Spacer()
            Button("保存并刷新", action: save)
                .buttonStyle(GlassButtonStyle(prominent: Palette.mint, loading: saving, succeeded: saved))
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
        }
        .padding(.leading, 18).padding(.trailing, 9)
        .frame(height: 50)
        .background {
            OuterShadow(shape: Capsule(), opacity: 0.4, radius: 18, y: 8)
            // Blurs the scrolling settings underneath, not the desktop.
            GlassSurface(shape: Capsule(), tintOpacity: 0.18, blending: .withinWindow)
        }
    }
    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("连接状态").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 16)
            content().font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
    }
    private var draftKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            keyError = true; keyResult = "剪贴板中没有文本，请先复制 API Key"; return
        }
        key = text
        keyError = false; keyResult = ""; saved = false; result = ""
    }
    private var keyStatusText: String {
        if saving { return "正在保存…" }
        if !draftKey.isEmpty { return keyError ? keyResult : "已输入 API Key · 尚未保存" }
        if deleteKey { return "待移除 · 点击保存后生效" }
        if !keyResult.isEmpty { return keyResult }
        if hasSavedKey == true { return "已保存到本机 · 留空将继续使用已有密钥" }
        if hasSavedKey == false { return "尚未保存 API Key" }
        return "正在检查已保存的密钥…"
    }
    private var keyStatusColor: Color {
        if keyError { return .red }
        if !draftKey.isEmpty || deleteKey { return .orange }
        return hasSavedKey == true ? Palette.mint : .secondary
    }
    private var keyStatusIcon: String {
        if keyError { return "exclamationmark.circle.fill" }
        if !draftKey.isEmpty || deleteKey { return "pencil.circle" }
        return hasSavedKey == true ? "checkmark.shield.fill" : "key"
    }
    private func checkStoredKey() async {
        do {
            let present = try await Task.detached { try SecureStore.containsKey() }.value
            hasSavedKey = present
        } catch {
            if draftKey.isEmpty && !saving { keyError = true; keyResult = "无法确认已有密钥，请点击“授权读取已存凭据”" }
        }
    }
    private func save() {
        guard !saving else { return }
        do {
            var amount = model.baseline
            if model.source == .sub2api {
                _ = try UsageDecoder.endpoint(site)
                guard let parsed = Double(baseline), parsed.isFinite, parsed > 0 else { throw TelemetryError.invalidBaseline }
                amount = parsed
            }
            let updatingKey = model.source == .sub2api
            let submittedKey = updatingKey ? draftKey : ""
            let removing = updatingKey && deleteKey
            saving = true; saved = false; result = "正在保存…"; keyError = false
            Task { @MainActor in
                do {
                    let present: Bool? = try await Task.detached(priority: .userInitiated) {
                        guard updatingKey else { return nil }
                        if removing { try SecureStore.writeAndVerify("") }
                        else if !submittedKey.isEmpty { try SecureStore.writeAndVerify(submittedKey) }
                        return try SecureStore.containsKey()
                    }.value
                    let defaults = UserDefaults.standard
                    if updatingKey {
                        defaults.set(site.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "site")
                        defaults.set(amount, forKey: "baseline")
                    }
                    defaults.set(sessionPath, forKey: "sessionPath")
                    defaults.set(binary, forKey: "codexBinary")
                    defaults.set(reducedMotion, forKey: "reducedMotion")
                    defaults.set(hoverEnabled, forKey: "hoverEnabled")
                    if let present {
                        hasSavedKey = present
                        key = ""; deleteKey = false
                        keyResult = removing ? "API Key 已移除" : present ? "API Key 已保存到本机" : "尚未保存 API Key"
                    }
                    saved = true; saving = false
                    result = removing ? "密钥已移除，设置已保存" : !submittedKey.isEmpty ? "API Key 保存成功，已确认写入本机凭据文件" : "设置已保存"
                    model.reloadSettings()
                } catch {
                    saving = false; saved = false; keyError = updatingKey
                    keyResult = "保存失败：\(error.localizedDescription)"
                    result = keyResult
                }
            }
        } catch { saved = false; result = error.localizedDescription }
    }
}


private struct ClineAccountSettings: View {
    @ObservedObject var account: ClineAccount
    @State private var apiKey = ""
    private enum Action { case key, login }
    /// The button the user pressed; background refreshes also set `busy` but must not spin a button.
    @State private var pending: Action?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("API Key").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).frame(width: 60, alignment: .leading)
                GlassTextField(placeholder: account.hasAPIKey ? "已保存 · 输入新 Key 可替换" : "在 app.cline.bot 生成，粘贴到这里",
                               text: $apiKey, secure: true, monospaced: true)
                Button("保存") { pending = .key; account.setAPIKey(apiKey); apiKey = "" }
                    .buttonStyle(GlassButtonStyle(prominent: apiKey.isEmpty && pending != .key ? nil : Palette.blue,
                                                  loading: pending == .key && account.busy, succeeded: account.lastSucceeded))
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || account.busy)
                Button("移除") { account.setAPIKey("") }.buttonStyle(GlassButtonStyle())
                    .disabled(!account.hasAPIKey || account.busy)
            }
            Text("推荐：与 CodexBar 相同，用 API Key 直接查询 Cline Pass 配额，不需要浏览器登录。填写后优先使用 Key；也可以改用下方的账号登录。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            GlassDivider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("使用 Cline 账号登录 Cline Pass").font(.system(size: 12.5, weight: .medium))
                    if let email = account.email {
                        Text(email).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if account.connected {
                    Label("已连接", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.mint)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Palette.mint.opacity(0.12)))
                        .overlay(GlassRim(shape: Capsule(), intensity: 0.5))
                }
            }
            Text("在浏览器确认设备码后完成登录。登录凭据保存在仅当前用户可读的本地文件，自动刷新套餐配额。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            if let code = account.userCode {
                HStack(spacing: 10) {
                    Text("设备码").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Text(code).font(.system(size: 17, weight: .semibold, design: .monospaced)).tracking(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        .buttonStyle(GlassButtonStyle(compact: true))
                    if let url = account.verificationURL {
                        Link("重新打开登录页面", destination: url).font(.system(size: 11)).foregroundStyle(Palette.blue)
                    }
                }
                .padding(.horizontal, 12).frame(height: 44)
                .glassCard(radius: 12, tint: Palette.blue)
            }
            HStack(spacing: 8) {
                Button(account.connected ? "重新登录" : "连接 Cline 账号") { pending = .login; account.connect() }
                    .buttonStyle(GlassButtonStyle(prominent: account.connected ? nil : Palette.blue,
                                                  loading: pending == .login && account.busy, succeeded: account.lastSucceeded))
                    .disabled(account.busy)
                if account.loggingIn {
                    Button("取消登录") { account.stop() }.buttonStyle(GlassButtonStyle())
                } else {
                    Button("退出账号") { account.logout() }.buttonStyle(GlassButtonStyle())
                        .disabled(account.busy || !account.connected)
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://app.cline.bot/dashboard/subscription?personal=true")!) {
                    Label("管理 Cline Pass", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.blue)
            }
            Text("显示 Cline Pass 套餐配额；本机任务状态仍来自 Codex。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .onChange(of: account.busy) { _, busy in if !busy { pending = nil } }
    }
}

private struct ClaudeAccountSettings: View {
    @ObservedObject var account: ClaudeAccount
    @State private var pending = false
    private let accent = ServiceStyle.claude.tint
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示 Claude 订阅的 5 小时与每周额度").font(.system(size: 12.5, weight: .medium))
                    if let plan = account.plan {
                        Text(plan).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    }
                }
                Spacer(minLength: 0)
                if account.enabled {
                    Label("已启用", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.mint)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Palette.mint.opacity(0.12)))
                        .overlay(GlassRim(shape: Capsule(), intensity: 0.5))
                }
            }
            Text("复用本机 Claude Code 的登录，不需要 API Key。通过系统自带的 security 工具读取“Claude Code-credentials”（Claude Code 也用它写入），不弹窗，重新编译或更新后也不需要再授权；仅当该方式失败时才请求钥匙串授权。只读不写，不会影响 Claude Code 的登录；令牌仅保存在内存，每 2 分钟查询一次。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(account.enabled ? "重新读取" : "连接 Claude Code") { pending = true; account.connect() }
                    .buttonStyle(GlassButtonStyle(prominent: account.enabled ? nil : accent,
                                                  loading: pending && account.busy, succeeded: account.lastSucceeded))
                    .disabled(account.busy)
                Button("停止读取") { account.disconnect() }.buttonStyle(GlassButtonStyle())
                    .disabled(!account.enabled)
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                    Label("查看 Claude 用量", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(accent)
            }
        }
        .onChange(of: account.busy) { _, busy in if !busy { pending = false } }
    }
}

private struct GrokAccountSettings: View {
    @ObservedObject var account: GrokAccount
    @State private var pending = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示 SuperGrok 本期额度").font(.system(size: 12.5, weight: .medium))
                    if let detail = [account.plan, account.email].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if account.enabled {
                    Label("已启用", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.mint)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Palette.mint.opacity(0.12)))
                        .overlay(GlassRim(shape: Capsule(), intensity: 0.5))
                }
            }
            Text("复用 grok login 写入的 ~/.grok/auth.json，不需要 API Key，也不会弹出钥匙串授权。只读不写；Grok 令牌有效期较短，过期时在终端运行一次 grok 即可续期。每 2 分钟查询一次。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(account.enabled ? "立即刷新" : "连接 Grok") { pending = true; account.connect() }
                    .buttonStyle(GlassButtonStyle(prominent: account.enabled ? nil : ServiceStyle.grok.tint,
                                                  loading: pending && account.busy, succeeded: account.lastSucceeded))
                    .disabled(account.busy)
                Button("停止读取") { account.disconnect() }.buttonStyle(GlassButtonStyle())
                    .disabled(!account.enabled)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: account.busy) { _, busy in if !busy { pending = false } }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Window background: live blur of the desktop with soft colour pools for the glass to refract.
private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            BackdropBlur(material: .hudWindow)
            Color.black.opacity(0.28)
            Circle().fill(Palette.mint.opacity(0.20)).frame(width: 420).blur(radius: 120).offset(x: -250, y: -300)
            Circle().fill(Palette.blue.opacity(0.18)).frame(width: 460).blur(radius: 130).offset(x: 260, y: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct GlassSection<Content: View>: View {
    let title: String
    var symbol: String = ""
    /// A service mark; takes precedence over `symbol`.
    var icon: Image? = nil
    var tint: Color = Palette.mint
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if let icon { icon.resizable().aspectRatio(contentMode: .fit).frame(width: 12, height: 12) }
                    else { Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)) }
                }
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.15)))
                    .overlay(GlassRim(shape: Circle(), intensity: 0.6))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 20)
        }
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 118, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
