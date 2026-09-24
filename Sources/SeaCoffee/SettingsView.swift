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
        _baseline = State(initialValue: String(format: "%.0f", model.baseline))
        _sessionPath = State(initialValue: model.sessionPath)
        _binary = State(initialValue: UserDefaults.standard.string(forKey: "codexBinary") ?? "")
        _reducedMotion = State(initialValue: model.reducedMotion)
        _hoverEnabled = State(initialValue: model.hoverEnabled)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle").font(.system(size: 25)).foregroundStyle(Palette.mint)
                    .frame(width: 48, height: 48).background(Palette.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sea Coffee").font(.system(size: 21, weight: .semibold))
                    Text("AI 任务状态与剩余额度").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("PREVIEW 0.1").font(.system(size: 9, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
            }.padding(24)
            Divider().opacity(0.5)
            Form {
                Section {
                    Picker("Codex 接入方式", selection: Binding(get: { model.source }, set: { model.select($0) })) {
                        ForEach(Provider.allCases) { Text($0.title).tag($0) }
                    }
                    if model.source == .sub2api {
                        TextField("站点地址", text: $site).textContentType(.URL)
                        HStack {
                            SecureField(hasSavedKey == true ? "API Key（输入可替换已有密钥）" : "API Key", text: $key)
                            Button("粘贴", action: pasteKey)
                                .help("从剪贴板填入 API Key")
                        }
                            .disabled(deleteKey)
                            .onChange(of: key) { _, value in
                                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    keyResult = ""; keyError = false; result = ""; saved = false
                                }
                            }
                        HStack(spacing: 7) {
                            if saving {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: keyStatusIcon)
                            }
                            Text(keyStatusText)
                        }
                        .font(.caption).foregroundStyle(keyStatusColor)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(keyStatusText)
                        TextField("钱包满格基准（USD）", text: $baseline)
                        if hasSavedKey == true {
                            Toggle("移除已保存的 API Key", isOn: $deleteKey)
                                .disabled(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .onChange(of: deleteKey) { _, _ in result = ""; saved = false }
                        }
                        Text("余额来自服务商。圆环按余额 ÷ 满格基准计算；套餐和 Key 配额优先使用服务端总额度。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("使用 ChatGPT 账号登录")
                                Text("登录将在浏览器完成。独立保存官方登录状态，不改动你现有的 Codex 中转配置。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("连接官方账号") {
                                model.account.binaryPath = binary
                                model.account.connect()
                            }
                        }
                        TextField("Codex CLI 路径（留空自动查找）", text: $binary)
                    }
                    LabeledContent("连接状态") {
                        HStack(spacing: 6) {
                            if model.refreshing { ProgressView().controlSize(.mini) }
                            Text(model.refreshing ? "正在查询余额…" : model.serviceMessage)
                                .multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Label("Codex 账号与额度", systemImage: "circle.dotted.circle") }

                Section {
                    ClineAccountSettings(account: model.clineAccount)
                    LabeledContent("连接状态") {
                        Text(model.clineMessage).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                } header: { Label("Cline Pass · 独立连接", systemImage: "circle.dotted.circle") }

                Section {
                    Button(model.authorizingCredentials ? "等待系统授权…" : "授权读取已存凭据") {
                        model.authorizeCredentials()
                    }.disabled(model.authorizingCredentials || model.clineAccount.busy)
                    Text("后台刷新不弹密码框。授权后，本次运行会复用凭据；如系统提供“始终允许”，可用它保存此次授权。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("钥匙串访问", systemImage: "key") }

                Section {
                    TextField("Codex 会话目录", text: $sessionPath)
                    Text("在本机监听 Codex 的运行、完成和中断状态，不上传对话内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("当前识别到 \(model.running.count) 个运行中任务")
                        Spacer()
                        Button(model.demo ? "结束预览" : "预览完成动画") { model.preview() }
                    }
                } header: { Label("任务状态", systemImage: "waveform.path") }

                Section {
                    Toggle("悬停时展开", isOn: $hoverEnabled)
                    Toggle("减少动态效果", isOn: $reducedMotion)
                    Text("额度圆环：50% 及以上为绿，20%–49% 为黄，低于 20% 为红。左侧橙色运行、红色报错、绿色完成，数字为运行中的对话数。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("完成时两侧合拢为与刘海等宽的黑色背景，对勾立体翻转后收回。减少动态效果时改为静态对勾；额度每分钟刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("外观与交互", systemImage: "sparkles") }
            }.formStyle(.grouped).disabled(saving)
            Divider().opacity(0.5)
            HStack {
                HStack(spacing: 7) {
                    if saving { ProgressView().controlSize(.small) }
                    else if !result.isEmpty { Image(systemName: saved ? "checkmark.circle.fill" : "exclamationmark.circle") }
                    Text(result.isEmpty ? (model.source == .sub2api ? "输入密钥后，点击保存并刷新" : "账号登录会自动保存；其他设置请点击保存") : result)
                }
                .font(.caption).foregroundStyle(saving ? Color.secondary : saved ? Palette.mint : result.isEmpty ? .secondary : .red)
                .lineLimit(2)
                Spacer()
                Button(saving ? "正在保存…" : "保存并刷新", action: save).buttonStyle(.borderedProminent).tint(Palette.mint)
                    .foregroundStyle(.black).keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }.padding(20)
        }
        .frame(width: 620, height: 680)
        .preferredColorScheme(.dark)
        .task { await checkStoredKey() }
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
        if saving { return "正在保存到钥匙串…" }
        if !draftKey.isEmpty { return keyError ? keyResult : "已输入 API Key · 尚未保存" }
        if deleteKey { return "待移除 · 点击保存后生效" }
        if !keyResult.isEmpty { return keyResult }
        if hasSavedKey == true { return "已保存到钥匙串 · 留空将继续使用已有密钥" }
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
            if draftKey.isEmpty && !saving { keyError = true; keyResult = "无法确认已有密钥，请检查钥匙串访问权限" }
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
                        keyResult = removing ? "API Key 已移除" : present ? "API Key 已保存到钥匙串" : "尚未保存 API Key"
                    }
                    saved = true; saving = false
                    result = removing ? "密钥已移除，设置已保存" : !submittedKey.isEmpty ? "API Key 保存成功，已确认写入钥匙串" : "设置已保存"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使用 Cline 账号登录 Cline Pass")
            Text("在浏览器确认设备码后完成登录。登录凭据保存在 macOS 钥匙串，自动刷新套餐配额。")
                .font(.caption).foregroundStyle(.secondary)
            if let email = account.email { Text(email).font(.caption).textSelection(.enabled) }
            if let code = account.userCode {
                HStack {
                    Text("设备码：")
                    Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                }
                if let url = account.verificationURL { Link("重新打开登录页面", destination: url) }
            }
            HStack {
                if account.busy { ProgressView().controlSize(.small) }
                Button(account.connected ? "重新登录" : "连接 Cline 账号") { account.connect() }
                    .disabled(account.busy)
                if account.loggingIn {
                    Button("取消登录") { account.stop() }
                } else {
                    Button("退出账号") { account.logout() }.disabled(account.busy || !account.connected)
                }
                Link("管理 Cline Pass", destination: URL(string: "https://app.cline.bot/dashboard/subscription?personal=true")!)
            }
            Text("显示 Cline Pass 套餐配额；本机任务状态仍来自 Codex。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
