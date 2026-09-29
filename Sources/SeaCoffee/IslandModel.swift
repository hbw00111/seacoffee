import AppKit
import Combine
import SwiftUI
import IslandCore

enum Provider: String, CaseIterable, Identifiable {
    case sub2api, official
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sub2api: return "Codex API"
        case .official: return "Codex 官方"
        }
    }
}

/// One subscription shown in the island: Cline Pass, and Claude / Grok once enabled.
struct PlanLane: Identifiable {
    let id: String
    let title: String
    let snapshot: UsageSnapshot?
    let stale: Bool
    let message: String
    /// A first fetch is in flight with nothing to show yet.
    var loading = false
    var primary: Quota? { snapshot?.quotas.first }
}

/// Keep the same window selection and sizing in the view and panel geometry.
enum QuotaPresentation {
    static func windows(_ snapshot: UsageSnapshot?, totalOnly: Bool = false) -> [Quota] {
        let all = snapshot?.quotas ?? []
        if totalOnly { return Array(all.prefix(1)) }
        let selected = all.filter { ["5 小时", "每周", "7 天"].contains($0.label) }
        return selected.isEmpty ? Array(all.prefix(1)) : Array(selected.prefix(2))
    }
    static func height(_ count: Int) -> CGFloat { 34 + CGFloat(max(1, count)) * 20 }
}

struct CompletionPresentation: Identifiable {
    let id = UUID()
    let startedAt = Date()
    let isDemo: Bool
    var initialWidth: CGFloat = 291
    var initialHeight: CGFloat = 32
    var wasExpanded = false
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var hovered = false
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = false
    @Published var source: Provider
    @Published var snapshot: UsageSnapshot?
    @Published var clineSnapshot: UsageSnapshot?
    @Published var clineMessage = "请连接 Cline 账号"
    @Published var claudeSnapshot: UsageSnapshot?
    @Published var claudeMessage = "请在设置中连接 Claude Code"
    @Published var grokSnapshot: UsageSnapshot?
    @Published var grokMessage = "请在设置中连接 Grok"
    @Published var serviceMessage = "在设置中添加 API Key，即可查看真实余额"
    @Published var monitorMessage: String?
    @Published var sessions: [SessionState] = []
    @Published var refreshing = false
    @Published var demo = false
    @Published var demoRunning = true
    @Published var notice: SessionState?
    @Published var completion: CompletionPresentation?
    @Published var reducedMotion: Bool
    @Published var hoverEnabled: Bool
    /// Agents whose local session files are followed; all by default.
    @Published private(set) var watchedAgents: Set<Agent>
    var openSettings: (() -> Void)?
    var geometryChanged: (() -> Void)?
    let account = OfficialAccount()
    let clineAccount = ClineAccount()
    let claudeAccount = ClaudeAccount()
    let grokAccount = GrokAccount()
    let launchAtLogin = LaunchAtLogin()
    private var monitor: SessionMonitor?
    private var refreshTimer: Timer?
    private var collapseTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var noticeQueue: [SessionState] = []
    private var accountObservers: [AnyCancellable] = []

    var site: String { UserDefaults.standard.string(forKey: "site") ?? "" }
    var baseline: Double { let n = UserDefaults.standard.double(forKey: "baseline"); return n > 0 ? n : 100 }
    /// Bumped when a top-up moves the baseline, so an open Settings window shows the new amount.
    @Published private(set) var baselineRevision = 0
    /// Up to two decimals, without trailing zeros, in a form `Double(_:)` parses back.
    static func baselineText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
    var sessionPath: String { UserDefaults.standard.string(forKey: "sessionPath") ?? "~/.codex/sessions" }
    // Four quotas fold into a 2×2 grid, which needs a wider right wing.
    var compactWidth: CGFloat { max(290, notchWidth + (planLanes.count >= 3 ? 250 : 180)) }
    var headerHeight: CGFloat { hasNotch ? max(24, notchHeight) : 32 }
    var completionWidth: CGFloat { hasNotch ? notchWidth : 180 }
    var islandWidth: CGFloat { completion != nil ? completionWidth : expanded ? max(360, compactWidth) : compactWidth }
    var islandHeight: CGFloat { completion != nil ? (hasNotch ? headerHeight : 0) + 72 + (completionCaption == nil ? 0 : CompletionCaption.height) : expanded ? headerHeight + detailHeight : headerHeight }
    var detailHeight: CGFloat {
        122 + QuotaPresentation.height(QuotaPresentation.windows(displayedSnapshot, totalOnly: source == .sub2api).count)
            + planLanes.reduce(0) { $0 + QuotaPresentation.height(QuotaPresentation.windows($1.snapshot).count) + 0.5 }
    }
    var surfaceTopInset: CGFloat { 0 }
    var animation: Animation { reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.48, dampingFraction: 0.86) }
    var openingAnimation: Animation { reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.9) }
    var closingAnimation: Animation { .easeOut(duration: reduceMotion ? 0.1 : 0.18) }
    var islandAnimation: Animation { expanded ? openingAnimation : closingAnimation }
    var reduceMotion: Bool { reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var running: [SessionState] { sessions.filter { $0.state == .running } }
    var uncertain: Bool { sessions.contains { $0.state == .unknown && !$0.transitionID.isEmpty } }
    var activeConversationCount: Int { demo ? (demoRunning ? 3 : 0) : Set(running.map(\.id)).count }
    var isRunning: Bool { activeConversationCount > 0 }
    var activityAppearance: ActivityAppearance {
        if let notice {
            switch notice.state {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .interrupted
            default: break
            }
        }
        if demo && !demoRunning { return .completed }
        if isRunning { return .running }
        switch sessions.max(by: { $0.updatedAt < $1.updatedAt })?.state {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        default: return .idle
        }
    }
    var displayedSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额基准", remaining: 68.4, limit: 100)], balance: 68.4, source: "演示数据") : snapshot
    }
    var displayedClineSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [
            Quota(id: "five_hour", label: "5 小时", remaining: 72, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(10800)),
            Quota(id: "weekly", label: "每周", remaining: 61, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(259200)),
            Quota(id: "monthly", label: "每月", remaining: 48, limit: 100, monetary: false)
        ], source: "Cline Pass") : clineSnapshot
    }
    var displayedClaudeSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [
            Quota(id: "claude-five_hour", label: "5 小时", remaining: 58, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(7200)),
            Quota(id: "claude-seven_day", label: "每周", remaining: 83, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(345600))
        ], source: "Claude") : claudeSnapshot
    }
    var showsClaude: Bool { demo || claudeAccount.enabled || claudeSnapshot != nil }
    // Claude polls every two minutes, so allow one missed refresh before dimming.
    var claudeIsStale: Bool { !demo && claudeSnapshot.map { Date().timeIntervalSince($0.fetchedAt) > 300 } == true }
    var displayedGrokSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [Quota(id: "grok-credits", label: "每周", remaining: 90, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(172800))],
                             source: "Grok") : grokSnapshot
    }
    var showsGrok: Bool { demo || grokAccount.enabled || grokSnapshot != nil }
    var grokIsStale: Bool { !demo && grokSnapshot.map { Date().timeIntervalSince($0.fetchedAt) > 300 } == true }
    var planLanes: [PlanLane] {
        var lanes = [PlanLane(id: "CL", title: "Cline Pass", snapshot: displayedClineSnapshot, stale: clineIsStale, message: clineMessage,
                              loading: clineAccount.busy && clineSnapshot == nil)]
        if showsClaude {
            lanes.append(PlanLane(id: "CC", title: "Claude", snapshot: displayedClaudeSnapshot, stale: claudeIsStale, message: claudeMessage,
                                  loading: claudeAccount.busy && claudeSnapshot == nil))
        }
        if showsGrok {
            lanes.append(PlanLane(id: "GK", title: "Grok", snapshot: displayedGrokSnapshot, stale: grokIsStale, message: grokMessage,
                                  loading: grokAccount.busy && grokSnapshot == nil))
        }
        return lanes
    }
    var clineIsStale: Bool { !demo && clineSnapshot.map { Date().timeIntervalSince($0.fetchedAt) > 180 } == true }
    var primary: Quota? { displayedSnapshot?.quotas.first }
    var isStale: Bool { !demo && snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 180 } == true }
    /// "Claude Code · claude-opus-5-5" under the completion check.
    var completionCaption: CompletionCaption? {
        if demo { return CompletionCaption(style: .codex, text: "Codex · gpt-6-sol") }
        guard let notice, notice.state == .completed else { return nil }
        let text = [notice.agent.name, notice.channelName, notice.modelName].compactMap { $0 }.joined(separator: " · ")
        return CompletionCaption(style: ServiceStyle(agent: notice.agent), text: text)
    }
    /// The agent the status row talks about: the finished task, else a running one, else the latest.
    var focusAgent: Agent {
        notice?.agent ?? running.first?.agent ?? sessions.max(by: { $0.updatedAt < $1.updatedAt })?.agent ?? .codex
    }
    private var runningAgentNames: String {
        let agents = Agent.allCases.filter { agent in running.contains { $0.agent == agent } }
        return agents.count > 2 ? "\(agents[0].name) 等 \(agents.count) 个工具" : agents.map(\.name).joined(separator: " · ")
    }
    var statusTitle: String {
        if demo { return demoRunning ? "Codex 正在运行" : "Codex 本轮已完成" }
        if let notice {
            switch notice.state {
            case .completed: return "\(notice.agent.name) 本轮已完成"
            case .failed: return "\(notice.agent.name) 遇到了问题"
            default: return "\(notice.agent.name) 任务已中断"
            }
        }
        if isRunning { return "\(runningAgentNames) 正在运行" }
        return uncertain ? "任务状态待确认" : "暂无运行中的任务"
    }
    var statusDetail: String {
        if demo { return demoRunning ? "seacoffee · 正在打磨界面" : "seacoffee · 本轮回复已结束" }
        if let notice {
            let origin = [notice.project, notice.channelName, notice.modelName].compactMap { $0 }.joined(separator: " · ")
            return canOpen(notice.agent) ? "\(origin) · 点击右侧按钮打开 \(notice.agent.name)" : origin
        }
        if let first = running.first { return "\(first.project) · \(activeConversationCount) 个对话运行中" }
        if uncertain { return "较长时间未收到事件 · 请查看对应工具" }
        return monitorMessage ?? "本地监听已开启 · 等待下一次任务"
    }
    func setWatched(_ agent: Agent, _ on: Bool) {
        if on { watchedAgents.insert(agent) } else { watchedAgents.remove(agent) }
        UserDefaults.standard.set(Agent.allCases.filter(watchedAgents.contains).map(\.rawValue), forKey: "watchedAgents")
        startMonitor()
    }

    init(defaults: UserDefaults = .standard) {
        source = Provider(rawValue: defaults.string(forKey: "source") ?? "") ?? .sub2api
        reducedMotion = defaults.bool(forKey: "reducedMotion")
        hoverEnabled = defaults.object(forKey: "hoverEnabled") as? Bool ?? true
        watchedAgents = defaults.stringArray(forKey: "watchedAgents").map { Set($0.compactMap(Agent.init(rawValue:))) } ?? Set(Agent.allCases)
        account.binaryPath = defaults.string(forKey: "codexBinary") ?? ""
        clineAccount.onStatus = { [weak self] text in
            self?.clineMessage = text
        }
        clineAccount.onUsage = { [weak self] usage in
            guard let self else { return }
            withAnimation(self.animation) { self.clineSnapshot = usage }
        }
        clineAccount.onLogout = { [weak self] in
            self?.clineSnapshot = nil
        }
        // Account busy flags drive the island's loading placeholders.
        for publisher in [clineAccount.objectWillChange, claudeAccount.objectWillChange, grokAccount.objectWillChange] {
            accountObservers.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        claudeAccount.onStatus = { [weak self] text in
            self?.claudeMessage = text
        }
        claudeAccount.onUsage = { [weak self] usage in
            guard let self else { return }
            withAnimation(self.animation) { self.claudeSnapshot = usage }
        }
        claudeAccount.onDisconnect = { [weak self] in
            self?.claudeSnapshot = nil
        }
        grokAccount.onStatus = { [weak self] text in
            self?.grokMessage = text
        }
        grokAccount.onUsage = { [weak self] usage in
            guard let self else { return }
            withAnimation(self.animation) { self.grokSnapshot = usage }
        }
        grokAccount.onDisconnect = { [weak self] in
            self?.grokSnapshot = nil
        }
        account.onStatus = { [weak self] text in
            guard self?.source == .official else { return }
            self?.serviceMessage = text; self?.refreshing = false
        }
        account.onUsage = { [weak self] usage in
            guard let self, self.source == .official else { return }
            withAnimation(self.animation) { self.snapshot = usage }
            self.refreshing = false
        }
    }
    func start() {
        startMonitor(); refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() {
        monitor?.stop(); refreshTimer?.invalidate(); account.stop(); clineAccount.stop(); claudeAccount.stop(); grokAccount.stop()
        collapseTask?.cancel(); noticeTask?.cancel(); demoTask?.cancel(); refreshTask?.cancel()
    }
    func startMonitor() {
        monitor?.stop()
        let token = UUID(); generation = token
        monitor = SessionMonitor(sources: SessionSource.defaults(codexPath: sessionPath, enabled: watchedAgents)) { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.sessions = update.sessions; self.monitorMessage = update.message
                for finished in update.finished { self.showNotice(finished) }
                if !update.finished.isEmpty { self.refresh() }
            }
        }
        monitor?.start()
    }
    func refresh() {
        // Independent lanes: an API request or Keychain prompt must not block the other services.
        clineAccount.refresh()
        claudeAccount.refresh()
        grokAccount.refresh()
        refreshCodex()
    }
    private func refreshCodex() {
        guard !refreshing else { return }
        if source == .official { refreshing = true; account.refresh(); return }
        refreshing = true
        let site = site, baseline = baseline
        refreshTask = Task {
            do {
                // A legacy Keychain import may wait for macOS authorization. Never block the island's UI thread.
                let stored = try await Task.detached(priority: .userInitiated) { try SecureStore.read() }.value
                guard !Task.isCancelled, source == .sub2api else { return }
                guard let key = stored, !key.isEmpty else {
                    serviceMessage = "在设置中添加 API Key，即可查看真实余额"
                    refreshing = false
                    return
                }
                var usage = try await BalanceClient.fetch(site: site, key: key, baseline: baseline)
                guard !Task.isCancelled, source == .sub2api else { return }
                serviceMessage = "已连接 · \(URL(string: site)?.host ?? "Sub2API")"
                if usage.hasWallet, let balance = usage.balance {
                    let defaults = UserDefaults.standard
                    // Only a balance seen on the same site counts as "last time".
                    let previous = defaults.string(forKey: "walletLastSite") == site ? defaults.object(forKey: "walletLastBalance") as? Double : nil
                    if let rebased = WalletTopUp.rebasedBaseline(previousBalance: previous, currentBalance: balance, baseline: baseline) {
                        defaults.set(rebased, forKey: "baseline")
                        usage = usage.rebasingWallet(to: rebased)
                        baselineRevision += 1
                        serviceMessage = "检测到充值，满格基准已更新为 $\(Self.baselineText(rebased))"
                    }
                    defaults.set(balance, forKey: "walletLastBalance")
                    defaults.set(site, forKey: "walletLastSite")
                }
                withAnimation(animation) { snapshot = usage }
            } catch {
                guard !Task.isCancelled else { return }
                serviceMessage = "\(error.localizedDescription)\(snapshot == nil ? "" : " · 保留上次数据")"
            }
            refreshing = false
        }
    }
    @Published var authorizingCredentials = false
    func authorizeCredentials() {
        guard !authorizingCredentials else { return }
        authorizingCredentials = true
        Task {
            defer { authorizingCredentials = false }
            do {
                if source == .sub2api {
                    _ = try await Task.detached { try SecureStore.read(allowInteraction: true) }.value
                    refreshCodex()
                }
            } catch { serviceMessage = error.localizedDescription }
            clineAccount.refresh(allowInteraction: true)
            claudeAccount.refresh(allowInteraction: true)
        }
    }

    func select(_ provider: Provider) {
        guard source != provider else { return }
        refreshTask?.cancel(); refreshing = false; account.stop()
        source = provider; snapshot = nil; serviceMessage = "正在连接…"
        UserDefaults.standard.set(provider.rawValue, forKey: "source")
        refreshCodex()
    }
    func reloadSettings() {
        refreshTask?.cancel(); refreshing = false; snapshot = nil
        reducedMotion = UserDefaults.standard.bool(forKey: "reducedMotion")
        hoverEnabled = UserDefaults.standard.object(forKey: "hoverEnabled") as? Bool ?? true
        account.stop(); account.binaryPath = UserDefaults.standard.string(forKey: "codexBinary") ?? ""
        startMonitor(); refresh(); geometryChanged?()
    }
    func setExpanded(_ value: Bool) {
        withAnimation(value ? openingAnimation : closingAnimation) { expanded = value }
    }
    func hover(_ inside: Bool) {
        guard hovered != inside else { return }
        hovered = inside; collapseTask?.cancel()
        // Geometry changes during the morph must not dismiss its own animation.
        guard completion == nil else { return }
        if inside && hoverEnabled {
            setExpanded(true)
        } else if !inside && !pinned {
            // Leaving dismisses even a completion card the user has already hovered.
            setExpanded(false)
        }
    }
    func scheduleCollapse(after delay: Double = 0) {
        collapseTask?.cancel()
        collapseTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, !pinned, !hovered, notice == nil, !demo else { return }
            setExpanded(false)
        }
    }
    func togglePin() { pinned.toggle(); if !pinned { scheduleCollapse() } }
    func showNotice(_ session: SessionState) {
        if demo { stopPreview() }
        if notice != nil {
            if !noticeQueue.contains(where: { $0.id == session.id && $0.transitionID == session.transitionID }) {
                noticeQueue.append(session)
            }
            return
        }
        presentNotice(session)
    }
    private func presentNotice(_ session: SessionState, isDemo: Bool = false) {
        noticeTask?.cancel()
        notice = session
        if session.state == .completed {
            let presentation = CompletionPresentation(isDemo: isDemo,
                initialWidth: islandWidth, initialHeight: islandHeight, wasExpanded: expanded)
            // The frame clock owns the whole morph, including returning to the island.
            completion = presentation
            expanded = false
        } else { setExpanded(true) }
        let duration = session.state == .completed ? (reduceMotion ? CompletionMotion.reducedDuration : CompletionMotion.duration) : 5
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            finishNotice()
        }
    }
    private func finishNotice() {
        let wasDemo = completion?.isDemo == true
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.9)) {
            completion = nil; notice = nil
            if wasDemo { demo = false }
            expanded = pinned || (hovered && hoverEnabled)
        }
        if !noticeQueue.isEmpty { presentNotice(noticeQueue.removeFirst()) }
        else { scheduleCollapse() }
    }
    private func stopPreview() {
        demoTask?.cancel(); demo = false
        if completion?.isDemo == true {
            noticeTask?.cancel()
            finishNotice()
        }
    }
    func preview() {
        demoTask?.cancel()
        if demo { stopPreview(); scheduleCollapse(); return }
        guard notice == nil else { return }
        withAnimation(animation) { demo = true; demoRunning = true }
        setExpanded(true)
        demoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(animation) { demoRunning = false }
            var session = SessionState(id: "preview")
            session.project = "seacoffee"; session.state = .completed
            presentNotice(session, isDemo: true)
        }
    }
    private func appURL(for agent: Agent) -> URL? {
        let candidates: [String]
        switch agent {
        case .codex: candidates = ["com.openai.codex", "com.openai.Codex", "com.bigpizzav3.codexplusplus", "com.codexhost.app"]
        case .claude: candidates = ["com.anthropic.claudefordesktop"]
        case .pi: candidates = ["net.aiuo.pi-desktop"]
        // Grok and Cline run in a terminal; there is no app to bring forward.
        case .grok, .cline: candidates = []
        }
        return candidates.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
    func canOpen(_ agent: Agent) -> Bool { appURL(for: agent) != nil }
    func openAgent() {
        let agent = focusAgent
        if let url = appURL(for: agent) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            serviceMessage = "未找到 \(agent.name) 桌面应用，请从 Dock 或终端打开"
        }
    }
}
