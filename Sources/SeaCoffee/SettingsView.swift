import SwiftUI
import IslandCore

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @StateObject private var usageData = UsageDashboardModel()
    @Environment(\.glassSnapshot) private var snapshot
    @AppStorage("interfaceTheme", store: SeaCoffeePreferences.shared) private var theme = InterfaceTheme.light.rawValue
    @State private var previewAppearance: InterfaceTheme?
    @State private var section: SettingsSection = .accounts
    @State private var site: String
    @State private var baseline: String
    @State private var key = ""
    @State private var clineKey = ""
    @State private var deleteKey = false
    @State private var sessionPath: String
    @State private var binary: String
    @State private var reducedMotion: Bool
    @State private var refreshMinutes: Int
    @State private var hoverEnabled: Bool
    @State private var result = ""
    @State private var saved = false
    @State private var saving = false
    @State private var savedKeyPreview: String?
    @State private var hasSavedKey: Bool?
    @State private var keyResult = ""
    @State private var keyError = false

    init(model: IslandModel, previewSection: SettingsSection? = nil, previewTheme: InterfaceTheme? = nil, previewUsage: UsageDashboardModel? = nil) {
        _usageData = StateObject(wrappedValue: previewUsage ?? UsageDashboardModel())
        _previewAppearance = State(initialValue: previewTheme)
        _section = State(initialValue: previewSection ?? .accounts)
        _hasSavedKey = State(initialValue: previewSection == nil ? nil : false)
        self.model = model
        _site = State(initialValue: previewSection == nil ? model.site : "")
        _baseline = State(initialValue: previewSection == nil ? IslandModel.baselineText(model.baseline) : "100")
        _sessionPath = State(initialValue: previewSection == nil ? model.sessionPath : "~/.codex/sessions")
        _binary = State(initialValue: previewSection == nil ? SeaCoffeePreferences.shared.string(forKey: "codexBinary") ?? "" : "")
        _reducedMotion = State(initialValue: model.reducedMotion)
        _refreshMinutes = State(initialValue: model.refreshMinutes)
        _hoverEnabled = State(initialValue: model.hoverEnabled)
    }
    private var selectedTheme: InterfaceTheme { previewAppearance ?? InterfaceTheme(rawValue: theme) ?? .light }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.border.opacity(0.65)).frame(width: 0.5)
            VStack(spacing: 0) {
                header.padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 24)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if section == .accounts {
                                accountOverview { id in
                                    withAnimation(model.reduceMotion ? nil : InterfaceMotion.selection) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                }
                                accountsContent
                            }
                            if section == .usage { UsageDashboard(data: usageData, recordingError: model.usageHistoryError) }
                            if section == .activity { activityContent }
                            if section == .appearance { appearanceContent }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.top, 2).padding(.bottom, 28)
                        .disabled(saving)
                        .transition(model.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
                    }
                    .scrollIndicators(.automatic)
                    .id(section)
                }
                if section != .usage { actionBar }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: InterfaceLayout.settingsWidth, height: InterfaceLayout.settingsHeight)
        .background(Palette.canvas)
        .ignoresSafeArea()
        .foregroundStyle(Palette.text)
        .toggleStyle(.switch).tint(Palette.accent)
        .preferredColorScheme(selectedTheme.colorScheme)
        .environment(\.interfaceReduceMotion, model.reduceMotion || reducedMotion)
        .task { if !snapshot { await checkStoredKey() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sea Coffee").font(.system(size: 17, weight: .medium, design: .serif))
                    Text("任务与额度").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
            }.padding(.horizontal, 10).padding(.bottom, 36)
            Text("工作空间").font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.bottom, 10)
            GlassNavigation(options: SettingsSection.allCases, selection: $section,
                            title: { $0.rawValue }, symbol: { $0.symbol })
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("只读本机任务记录", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                Text("任务与额度，一眼看清。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 12).padding(.bottom, 18)
            GlassDivider().padding(.horizontal, 10).padding(.bottom, 12)
            #if !SEACOFFEE_DROPPY
            Button { NSApplication.shared.terminate(nil) } label: {
                HStack {
                    Label("退出应用", systemImage: "power")
                    Spacer()
                    Text("⌘Q").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle(ghost: true))
            .keyboardShortcut("q", modifiers: .command)
            .help("退出应用并关闭顶部状态岛")
            .accessibilityLabel("退出 Sea Coffee")
            #else
            Label("运行于 Droppy", systemImage: "rectangle.topthird.inset.filled")
                .font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.horizontal, 12)
            #endif
        }
        .padding(.horizontal, 14).padding(.top, 56).padding(.bottom, 20)
        .frame(width: InterfaceLayout.sidebarWidth)
        .background(Palette.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.rawValue).font(.system(size: 28, weight: .regular, design: .serif)).tracking(-0.5)
                Text(section.subtitle).font(.system(size: 12)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 12)
            Image(systemName: section.symbol).font(.system(size: 20, weight: .light))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
        }
    }

    private func accountOverview(jump: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账号概览").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("选择账号，查看连接与额度").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 10) {
                accountShortcut("codex", title: "Codex", style: .codex, usage: model.snapshot, jump: jump)
                accountShortcut("cline", title: "Cline", style: .cline, usage: model.clineSnapshot, jump: jump)
                accountShortcut("claude", title: "Claude", style: .claude, usage: model.claudeSnapshot, jump: jump)
                accountShortcut("grok", title: "Grok", style: .grok, usage: model.grokSnapshot, jump: jump)
            }
        }
    }

    private func accountShortcut(_ id: String, title: String, style: ServiceStyle,
                                 usage: UsageSnapshot?, jump: @escaping (String) -> Void) -> some View {
        let stale = usage.map { Date().timeIntervalSince($0.fetchedAt) > model.staleAfter(id == "claude" || id == "grok" ? 300 : 180) } ?? false
        return Button { jump(id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    style.icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).foregroundStyle(style.tint)
                    Text(title).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(usage?.quotas.first.map { "\($0.percent)%" } ?? "—")
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
                Text(usage?.quotas.first == nil ? "暂无额度数据" : stale ? "数据待更新" : "\(usage?.quotas.first?.label ?? "额度") · 剩余")
                    .font(.system(size: 10)).foregroundStyle(stale ? Palette.warning : Palette.dim).lineLimit(1)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 12)
        }
        .buttonStyle(.plain)
        .help("查看 \(title) 的连接与额度详情")
        .accessibilityLabel("\(title)，\(usage?.quotas.first.map { "剩余 \($0.percent)%" } ?? "暂无额度数据")，查看详情")
    }

    private var accountsContent: some View {
        Group {
            codexSection.id("codex")
            GlassSection(title: "Cline Pass", subtitle: "通过 API Key 或账号连接", icon: ServiceStyle.cline.icon, tint: ServiceStyle.cline.tint) {
                ClineAccountSettings(account: model.clineAccount, apiKey: $clineKey)
                GlassDivider()
                statusRow { Text(model.clineMessage).multilineTextAlignment(.trailing).textSelection(.enabled) }
                SettingsUsageDetails(usage: model.clineSnapshot, loading: model.clineAccount.busy, staleAfter: model.staleAfter(180))
            }.id("cline")
            GlassSection(title: "Claude", subtitle: "使用本机 Claude Code 登录", icon: ServiceStyle.claude.icon, tint: ServiceStyle.claude.tint) {
                ClaudeAccountSettings(account: model.claudeAccount)
                GlassDivider()
                statusRow { Text(model.claudeMessage).multilineTextAlignment(.trailing).textSelection(.enabled) }
                SettingsUsageDetails(usage: model.claudeSnapshot, loading: model.claudeAccount.busy, staleAfter: model.staleAfter(300))
            }.id("claude")
            GlassSection(title: "Grok", subtitle: "使用本机 Grok CLI 登录", icon: ServiceStyle.grok.icon, tint: ServiceStyle.grok.tint) {
                GrokAccountSettings(account: model.grokAccount)
                GlassDivider()
                statusRow { Text(model.grokMessage).multilineTextAlignment(.trailing).textSelection(.enabled) }
                SettingsUsageDetails(usage: model.grokSnapshot, loading: model.grokAccount.busy, staleAfter: model.staleAfter(300))
            }.id("grok")
            GlassSection(title: "凭据与隐私", subtitle: "登录信息仅保留在本机", symbol: "key", tint: Palette.dim) {
                caption("API Key 与 Cline 登录保存在仅当前用户可读的本地文件。更新应用无需重新连接；旧版本凭据可在这里授权导入。")
                Button("授权读取已存凭据") { model.authorizeCredentials() }
                    .buttonStyle(GlassButtonStyle(loading: model.authorizingCredentials))
                    .disabled(model.authorizingCredentials || model.clineAccount.busy || model.claudeAccount.busy)
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.path").font(.system(size: 22)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(model.running.count) 个任务正在运行").font(.system(size: 17, weight: .medium))
                    Text("正在关注 \(model.watchedAgents.count) 个工具").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                Spacer()
                Button(model.demo ? "结束预览" : "预览完成动画") { model.preview() }
                    .buttonStyle(GlassButtonStyle())
            }.padding(20).glassCard()
            GlassSection(title: "关注的工具", subtitle: "开关立即生效", symbol: "square.stack.3d.up", tint: Palette.accent) {
                ForEach(Agent.allCases, id: \.self) { agent in
                    let style = ServiceStyle(agent: agent)
                    HStack(spacing: 12) {
                        style.icon.resizable().aspectRatio(contentMode: .fit).frame(width: 19, height: 19)
                            .foregroundStyle(style.tint).frame(width: 30, height: 30)
                            .background(style.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(.system(size: 13, weight: .medium))
                            Text(agentPath(agent)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.dim)
                        }
                        Spacer()
                        Toggle("监听 \(agent.name)", isOn: Binding(get: { model.watchedAgents.contains(agent) },
                                                                 set: { model.setWatched(agent, $0) })).labelsHidden()
                    }.padding(.vertical, 3)
                    if agent != Agent.allCases.last { GlassDivider() }
                }
            }
            GlassSection(title: "监测位置", symbol: "folder", tint: Palette.dim) {
                SettingRow("Codex 会话目录") { GlassTextField(placeholder: "~/.codex/sessions", text: $sessionPath, monospaced: true) }
                caption("只读取事件类型、时间、项目目录名和模型名，不保存或上传对话内容。Pi 同时支持 PI-Desktop 的本机记录。")
            }
        }
    }

    private func agentPath(_ agent: Agent) -> String {
        switch agent {
        case .codex: return "自定义会话目录"
        case .claude: return "~/.claude/projects"
        case .grok: return "~/.grok/sessions"
        case .cline: return "~/.cline/data/sessions"
        case .pi: return "~/.pi/agent/sessions · PI-Desktop"
        case .dsh: return "~/.dsh/storages/session_projcache/sessions"
        }
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            GlassSection(title: "界面主题", subtitle: "为你的工作空间选择底色", symbol: "circle.lefthalf.filled", tint: Palette.accent) {
                HStack(spacing: 12) {
                    ForEach(InterfaceTheme.allCases) { appearance in
                        themeOption(appearance)
                    }
                }
                caption("主题切换立即生效。刘海区域始终保持深色，与屏幕边缘自然融合。")
            }
            GlassSection(title: "交互偏好", symbol: "slider.horizontal.3", tint: Palette.dim) {
                #if !SEACOFFEE_DROPPY
                SettingRow("悬停时展开") { HStack { Spacer(); Toggle("悬停时展开", isOn: $hoverEnabled).labelsHidden() } }
                GlassDivider()
                #endif
                SettingRow("减少动态效果") { HStack { Spacer(); Toggle("减少动态效果", isOn: $reducedMotion).labelsHidden() } }
                caption("减少位移、弹跳和翻转，保留清晰的状态反馈。系统的减少动态效果设置同样有效。")
                GlassDivider()
                SettingRow("额度刷新间隔") {
                    HStack {
                        Spacer()
                        Picker("额度刷新间隔", selection: $refreshMinutes) {
                            ForEach(IslandModel.refreshChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                caption("与 CC Switch 一致默认 5 分钟；任务完成时也会刷新。Claude 与 Grok 两次查询至少间隔 2 分钟。")
                #if !SEACOFFEE_DROPPY
                GlassDivider()
                SettingRow("开机自启") { LaunchAtLoginToggle(launch: model.launchAtLogin) }
                #endif
            }
            GlassSection(title: "读懂状态", symbol: "info.circle", tint: Palette.dim) {
                HStack(spacing: 18) {
                    statusLegend("充足 ≥20%", color: Palette.mint)
                    statusLegend("偏低 <20%", color: Palette.low)
                    statusLegend("已用完", color: Palette.danger)
                }
                caption("运行中为橙色，等待你回答为紫色，完成为绿色，失败为红色；未知额度显示为破折号。")
                #if SEACOFFEE_DROPPY
                caption("完成、提问和失败通过 Droppy HUD 提示。音乐或会议占用刘海时，仍可在任务卡片查看。")
                #else
                caption("任务完成时，刘海会显示对勾；需要你回答时显示问号。各账号独立刷新额度。")
                #endif
            }
        }
    }

    private func themeOption(_ appearance: InterfaceTheme) -> some View {
        let selected = selectedTheme == appearance
        return Button {
            if snapshot { previewAppearance = appearance } else { theme = appearance.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThemeSwatch(theme: appearance).frame(height: 64)
                HStack {
                    Text(appearance.title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Palette.accent : Palette.muted)
                }
            }
            .padding(10)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Palette.accent : Palette.border, lineWidth: selected ? 1.5 : 0.65))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearance.title)主题")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func statusLegend(_ title: String, color: Color) -> some View {
        Label { Text(title) } icon: { Circle().fill(color).frame(width: 6, height: 6) }
            .font(.system(size: 11)).foregroundStyle(Palette.dim)
    }

    private var codexSection: some View {
        GlassSection(title: "Codex", subtitle: "官方订阅或 API 额度", icon: ServiceStyle.codex.icon, tint: ServiceStyle.codex.tint) {
            SettingRow("接入方式") {
                GlassSegmented(options: Provider.allCases, selection: Binding(get: { model.source }, set: { model.select($0) })) { $0.title }
            }
            GlassDivider()
            if model.source == .sub2api {
                SettingRow("站点地址") { GlassTextField(placeholder: "https://你的-sub2api-站点", text: $site).textContentType(.URL) }
                SettingRow("API Key") {
                    HStack(spacing: 8) {
                        GlassTextField(placeholder: hasSavedKey == true ? "输入可替换已有密钥" : "sk-…", text: $key, secure: true, savedValuePreview: deleteKey ? nil : savedKeyPreview)
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
                            CometSpinner(size: 11, tint: Palette.dim)
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
                        Text("USD").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
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
                caption("余额来自服务商。额度指示按余额 ÷ 满格基准计算；套餐和 Key 配额优先使用服务端总额度。")
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
                    .buttonStyle(GlassButtonStyle(prominent: Palette.accentFill))
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
            GlassDivider()
            SettingsUsageDetails(usage: model.snapshot, loading: model.refreshing, staleAfter: model.staleAfter(180))
        }
    }
    private var actionBar: some View {
        VStack(spacing: 0) {
            GlassDivider()
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    if saving { CometSpinner(size: 12, tint: Palette.dim) }
                    else { Image(systemName: result.isEmpty ? "slider.horizontal.3" : saved ? "checkmark.circle.fill" : "exclamationmark.circle") }
                    Text(result.isEmpty ? "连接信息与交互偏好修改后需保存" : result)
                }
                .font(.system(size: 11)).foregroundStyle(saving ? Palette.dim : saved ? Palette.mint : result.isEmpty ? Palette.dim : Palette.danger)
                .lineLimit(2)
                Spacer(minLength: 8)
                Button("保存并刷新", action: save)
                    .buttonStyle(GlassButtonStyle(prominent: Palette.accentFill, loading: saving, succeeded: saved))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }.background(Palette.canvas)
    }
    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("连接状态").font(.system(size: 12.5)).foregroundStyle(Palette.dim)
            Spacer(minLength: 16)
            content().font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
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
        if hasSavedKey == true { return "已保存到本机 · 输入新 Key 可替换" }
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
            let preview = try await Task.detached { CredentialPreview.masked(try SecureStore.read()) }.value
            savedKeyPreview = preview
            hasSavedKey = preview != nil
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
                    let defaults = SeaCoffeePreferences.shared
                    if updatingKey {
                        defaults.set(site.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "site")
                        defaults.set(amount, forKey: "baseline")
                    }
                    defaults.set(sessionPath, forKey: "sessionPath")
                    defaults.set(binary, forKey: "codexBinary")
                    defaults.set(reducedMotion, forKey: "reducedMotion")
                    defaults.set(refreshMinutes, forKey: "quotaRefreshMinutes")
                    defaults.set(hoverEnabled, forKey: "hoverEnabled")
                    if let present {
                        hasSavedKey = present
                        if !present { savedKeyPreview = nil }
                        else if !submittedKey.isEmpty { savedKeyPreview = CredentialPreview.masked(submittedKey) }
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
    @Binding var apiKey: String
    private enum Action { case key, login }
    /// The button the user pressed; background refreshes also set `busy` but must not spin a button.
    @State private var pending: Action?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("API Key").font(.system(size: 12.5)).foregroundStyle(Palette.dim).frame(width: 60, alignment: .leading)
                GlassTextField(placeholder: account.hasAPIKey ? "已保存 · 输入新 Key 可替换" : "在 app.cline.bot 生成，粘贴到这里",
                               text: $apiKey, secure: true, monospaced: true, savedValuePreview: account.apiKeyPreview)
                Button("保存") { pending = .key; account.setAPIKey(apiKey); apiKey = "" }
                    .buttonStyle(GlassButtonStyle(prominent: apiKey.isEmpty && pending != .key ? nil : Palette.accentFill,
                                                  loading: pending == .key && account.busy, succeeded: account.lastSucceeded))
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || account.busy)
                Button("移除") { account.setAPIKey("") }.buttonStyle(GlassButtonStyle())
                    .disabled(!account.hasAPIKey || account.busy)
            }
            Text("推荐使用 API Key 查询 Cline Pass 配额。填入后优先使用 Key，也可以通过下方的账号登录连接。")
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
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

                }
            }
            Text("在浏览器确认设备码后完成登录。登录凭据保存在仅当前用户可读的本地文件，自动刷新套餐配额。")
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            if let code = account.userCode {
                HStack(spacing: 10) {
                    Text("设备码").font(.system(size: 11)).foregroundStyle(Palette.dim)
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
                    .buttonStyle(GlassButtonStyle(prominent: account.connected ? nil : Palette.accentFill,
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
            Text("显示 Cline Pass 套餐配额。任务监测可在左侧单独管理。")
                .font(.system(size: 11)).foregroundStyle(Palette.dim)
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

                }
            }
            Text("先在 Claude Code 中登录，再连接到这里。登录信息只读，令牌仅保存在内存，不会更改原有账号。按设置的间隔更新额度（最短 2 分钟）；必要时系统会请求读取钥匙串。令牌过期时保留上次额度，不会在后台启动 Claude Code；点击“重新读取”才会打开一次 Claude Code 续期。")
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(account.enabled ? "重新读取" : "连接 Claude Code") { pending = true; account.connect() }
                    .buttonStyle(GlassButtonStyle(prominent: account.enabled ? nil : Palette.accentFill,
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
                        Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if account.enabled {
                    Label("已启用", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.mint)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Palette.mint.opacity(0.12)))

                }
            }
            Text("先运行 grok login，再连接到这里。复用本机登录，按设置的间隔更新额度（最短 2 分钟）。登录过期时由 Grok CLI 自动续期，不发起对话或消耗额度。")
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(account.enabled ? "立即刷新" : "连接 Grok") { pending = true; account.connect() }
                    .buttonStyle(GlassButtonStyle(prominent: account.enabled ? nil : Palette.accentFill,
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

private struct ThemeSwatch: View {
    let theme: InterfaceTheme
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                swatch(dark: theme == .dark).frame(width: theme == .system ? geometry.size.width / 2 : geometry.size.width)
                if theme == .system { swatch(dark: true) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
    private func swatch(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(Palette.accentFill).frame(width: 7, height: 7).padding(.bottom, 5)
                RoundedRectangle(cornerRadius: 2).fill(Palette.accentFill.opacity(0.3)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25)).frame(height: 4)
                Spacer(minLength: 0)
            }.padding(8).frame(width: 36).background(dark ? Color(white: 0.08) : Color(red: 0.92, green: 0.91, blue: 0.88))
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color(white: 0.65) : Color(white: 0.45)).frame(width: 32, height: 4)
                RoundedRectangle(cornerRadius: 4).fill(dark ? Color(white: 0.19) : .white).frame(height: 24)
                Spacer(minLength: 0)
            }.padding(9).frame(maxWidth: .infinity).background(dark ? Color(white: 0.12) : Color(red: 0.98, green: 0.97, blue: 0.95))
        }
    }
}

private struct GlassSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String = ""
    var icon: Image? = nil
    var tint: Color = Palette.accent
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let icon { icon.resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18) }
                    else { Image(systemName: symbol).font(.system(size: 17, weight: .regular)) }
                }
                .foregroundStyle(tint).frame(width: 32, height: 32)
                .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.dim) }
                }
                Spacer(minLength: 0)
            }.padding(18)
            GlassDivider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.glassCard(radius: 16)
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
            Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.dim)
                .frame(width: 118, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts = "账号与额度", usage = "用量", activity = "任务监测", appearance = "外观与交互"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .accounts: return "person.crop.circle"; case .usage: return "list.bullet.rectangle"; case .activity: return "waveform.path"; case .appearance: return "slider.horizontal.3" }
    }
    var subtitle: String {
        switch self {
        case .accounts: return "连接你的 AI 服务，集中查看剩余额度。"
        case .usage: return "统一查看各工具的使用记录与额度变化。"
        case .activity: return "选择需要关注的工具，掌握每次任务的进展。"
        case .appearance: return "让状态岛按照你的习惯工作。"
        }
    }
}

/// Full account details use the real snapshot, never the island's animation-demo data.
struct SettingsUsageDetails: View {
    let usage: UsageSnapshot?
    let loading: Bool
    var staleAfter: TimeInterval = 180

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("额度详情").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if loading {
                        HStack(spacing: 5) {
                            CometSpinner(size: 11, tint: Palette.accent)
                            Text("更新中").font(.system(size: 10))
                        }.foregroundStyle(Palette.dim)
                    } else if let usage, context.date.timeIntervalSince(usage.fetchedAt) > staleAfter {
                        Label("数据待更新", systemImage: "clock")
                            .font(.system(size: 10)).foregroundStyle(Palette.warning)
                    }
                }
                if let usage {
                    if let balance = usage.balance {
                        HStack(alignment: .firstTextBaseline) {
                            Text("钱包余额").font(.system(size: 12)).foregroundStyle(Palette.dim)
                            Spacer()
                            Text(money(balance)).font(.system(size: 22, weight: .semibold))
                                .monospacedDigit()
                            Text("USD").font(.system(size: 10)).foregroundStyle(Palette.dim)
                        }
                    }
                    ForEach(usage.quotas) { quota in
                        quotaDetail(quota, now: context.date)
                    }
                    Text(UsageFormat.updatedText(usage.fetchedAt, now: context.date))
                        .font(.system(size: 10)).foregroundStyle(Palette.dim)
                        .help("上次成功查询 · " + usage.fetchedAt.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text(loading ? "正在获取额度…" : "暂无额度数据 · 连接账号或刷新后显示")
                        .font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.canvas))
        }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func quotaDetail(_ quota: Quota, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.id == "wallet" ? "相对满格基准" : quota.label == "7 天" ? "每周" : quota.label)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Text(QuotaLevel(fraction: quota.fraction) == .low ? "已用完" : "剩余 \(quota.percent)%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(QuotaRing.tint(for: quota.fraction))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.subtle)
                    Capsule().fill(QuotaRing.tint(for: quota.fraction))
                        .frame(width: geometry.size.width * quota.fraction)
                }
            }.frame(height: 4).accessibilityHidden(true)
            if quota.monetary {
                Text(quota.id == "wallet"
                     ? "满格基准 \(money(quota.limit)) · 用于余额比例显示"
                     : "剩余 \(money(quota.remaining)) / 总额 \(money(quota.limit))")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim).monospacedDigit()
            }
            if let reset = quota.resetsAt {
                Text(UsageFormat.resetText(reset, now: now) ?? "已到重置时间 · 等待刷新")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim)
                    .help(reset.formatted(date: .abbreviated, time: .shortened) + " 重置")
            } else if quota.id != "wallet" {
                Text("未提供重置时间").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
