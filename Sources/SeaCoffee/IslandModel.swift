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
    /// The latest query failed; with nothing to show, the panel says 额度没查到.
    var failed = false
    var primary: Quota? { snapshot?.quotas.first }
}

/// Keep the same window selection and sizing in the view and panel geometry.
enum QuotaPresentation {
    /// CC Switch's two rows: the shortest window, then whichever other window has the least left.
    /// Sonnet's weekly limit stays in the details.
    static func windows(_ snapshot: UsageSnapshot?, totalOnly: Bool = false) -> [Quota] {
        let all = snapshot?.quotas ?? []
        guard let first = all.first else { return [] }
        if totalOnly { return [first] }
        let tightest = all.dropFirst().filter { $0.id != "claude-seven_day_sonnet" }.min { $0.fraction < $1.fraction }
        return [first] + (tightest.map { [$0] } ?? [])
    }
    static func height(_ count: Int) -> CGFloat { 34 + CGFloat(max(1, count)) * 20 }
}

struct CompletionPresentation: Identifiable {
    let id = UUID()
    let startedAt = Date()
    let isDemo: Bool
    var kind: NoticeKind = .finished
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
    @Published var usageHistoryError: String?
    private let usageHistory = QuotaHistoryStore()
    private var recordsUsageHistory = false
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
    private var monitorClock: (minute: Int, stale: [Bool])?
    @Published var refreshing = false
    @Published var demo = false
    @Published var demoRunning = true
    @Published var notice: SessionState?
    @Published var completion: CompletionPresentation?
    @Published var reducedMotion: Bool
    /// Scheduled quota refresh, in minutes (CC Switch defaults to 5). Task completions refresh too.
    @Published var refreshMinutes: Int
    static let refreshChoices = [1, 2, 5, 10, 30]
    @Published var hoverEnabled: Bool
    /// Agents whose local session files are followed; all by default.
    @Published private(set) var watchedAgents: Set<Agent>
    /// Agents that did not exist when `watchedAgents` was first saved.
    private static let addedAgents: [Agent] = [.dsh]
    var openSettings: (() -> Void)?
    var geometryChanged: (() -> Void)?
    /// The host owns notification presentation when embedded as a Droppy extension.
    var noticePresented: ((SessionState, NoticeKind) -> Void)?
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
    private var authorizationTask: Task<Void, Never>?
    private var stopped = false
    private var generation = UUID()
    private var noticeQueue: [(session: SessionState, kind: NoticeKind)] = []
    private var accountObservers: [AnyCancellable] = []

    var site: String { SeaCoffeePreferences.shared.string(forKey: "site") ?? "" }
    var baseline: Double { let n = SeaCoffeePreferences.shared.double(forKey: "baseline"); return n > 0 ? n : 100 }
    /// Bumped when a top-up moves the baseline, so an open Settings window shows the new amount.
    @Published private(set) var baselineRevision = 0
    /// Up to two decimals, without trailing zeros, in a form `Double(_:)` parses back.
    static func baselineText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
    var sessionPath: String { SeaCoffeePreferences.shared.string(forKey: "sessionPath") ?? "~/.codex/sessions" }
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
    var animation: Animation { reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.48, dampingFraction: 0.86) }
    var openingAnimation: Animation { reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.9) }
    var closingAnimation: Animation { .easeOut(duration: reduceMotion ? 0.1 : 0.18) }
    var islandAnimation: Animation { expanded ? openingAnimation : closingAnimation }
    var reduceMotion: Bool { reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var running: [SessionState] { sessions.filter { $0.state == .running } }
    /// The most recently active conversation stopped on a question for the user.
    var asking: SessionState? { demo ? nil : sessions.first { $0.state == .running && $0.awaitingAnswer } }
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
        if asking != nil { return .asking }
        if isRunning { return .running }
        switch sessions.max(by: { $0.updatedAt < $1.updatedAt })?.state {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        default: return .idle
        }
    }
    var displayedSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额基准", remaining: 68.4, limit: 100)], balance: 68.4) : snapshot
    }
    var displayedClineSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [
            Quota(id: "five_hour", label: "5 小时", remaining: 72, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(10800)),
            Quota(id: "weekly", label: "每周", remaining: 61, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(259200)),
            Quota(id: "monthly", label: "每月", remaining: 48, limit: 100, monetary: false)
        ]) : clineSnapshot
    }
    var displayedClaudeSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [
            Quota(id: "claude-five_hour", label: "5 小时", remaining: 58, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(7200)),
            Quota(id: "claude-seven_day", label: "每周", remaining: 83, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(345600))
        ]) : claudeSnapshot
    }
    var showsClaude: Bool { demo || claudeAccount.enabled || claudeSnapshot != nil }
    // Claude polls every two minutes, so allow one missed refresh before dimming.
    var claudeIsStale: Bool { quotaIsStale(claudeSnapshot, floor: 300) }
    var displayedGrokSnapshot: UsageSnapshot? {
        demo ? UsageSnapshot(quotas: [Quota(id: "grok-credits", label: "每周", remaining: 90, limit: 100, monetary: false, resetsAt: Date().addingTimeInterval(172800))]) : grokSnapshot
    }
    var showsGrok: Bool { demo || grokAccount.enabled || grokSnapshot != nil }
    var grokIsStale: Bool { quotaIsStale(grokSnapshot, floor: 300) }
    var planLanes: [PlanLane] {
        var lanes = [PlanLane(id: "CL", title: "Cline Pass", snapshot: displayedClineSnapshot, stale: clineIsStale, message: clineMessage,
                              loading: clineAccount.busy && clineSnapshot == nil, failed: clineAccount.lastSucceeded == false)]
        if showsClaude {
            lanes.append(PlanLane(id: "CC", title: "Claude", snapshot: displayedClaudeSnapshot, stale: claudeIsStale, message: claudeMessage,
                                  loading: claudeAccount.busy && claudeSnapshot == nil, failed: claudeAccount.lastSucceeded == false))
        }
        if showsGrok {
            lanes.append(PlanLane(id: "GK", title: "Grok", snapshot: displayedGrokSnapshot, stale: grokIsStale, message: grokMessage,
                                  loading: grokAccount.busy && grokSnapshot == nil, failed: grokAccount.lastSucceeded == false))
        }
        return lanes
    }
    var clineIsStale: Bool { quotaIsStale(clineSnapshot, floor: 180) }
    var primary: Quota? { displayedSnapshot?.quotas.first }
    var isStale: Bool { quotaIsStale(snapshot, floor: 180) }
    private func quotaIsStale(_ usage: UsageSnapshot?, floor: TimeInterval, now: Date = Date()) -> Bool {
        !demo && usage.map { now.timeIntervalSince($0.fetchedAt) > staleAfter(floor) } == true
    }
    /// A quota is stale after missing two scheduled refreshes, never sooner than the account's own floor.
    func staleAfter(_ floor: TimeInterval) -> TimeInterval { max(floor, Double(refreshMinutes) * 120 + 60) }
    /// "Claude Code · claude-opus-5-5" under the completion check.
    var completionCaption: CompletionCaption? {
        let question = completion?.kind == .question
        if demo || completion?.isDemo == true {
            return question ? CompletionCaption(style: .claude, text: "Claude Code · seacoffee")
                            : CompletionCaption(style: .codex, text: "Codex · gpt-6-sol")
        }
        guard let notice else { return nil }
        // Who is asking, and in which project: several conversations may be open at once.
        if question {
            let text = [notice.agent.name, notice.project == notice.agent.name ? nil : notice.project].compactMap { $0 }.joined(separator: " · ")
            return CompletionCaption(style: ServiceStyle(agent: notice.agent), text: text)
        }
        guard notice.state == .completed else { return nil }
        let text = [notice.agent.name, notice.channelName, notice.modelName].compactMap { $0 }.joined(separator: " · ")
        return CompletionCaption(style: ServiceStyle(agent: notice.agent), text: text)
    }
    /// The agent the status row talks about: the finished task, else a running one, else the latest.
    var focusAgent: Agent {
        notice?.agent ?? asking?.agent ?? running.first?.agent ?? sessions.max(by: { $0.updatedAt < $1.updatedAt })?.agent ?? .codex
    }
    private var runningAgentNames: String {
        let agents = Agent.allCases.filter { agent in running.contains { $0.agent == agent } }
        return agents.count > 2 ? "\(agents[0].name) 等 \(agents.count) 个工具" : agents.map(\.name).joined(separator: " · ")
    }
    var statusTitle: String {
        if demo { return demoRunning ? "Codex 正在运行" : "Codex 本轮已完成" }
        if let notice {
            if completion?.kind == .question { return "\(notice.agent.name) 向你提问" }
            switch notice.state {
            case .completed: return "\(notice.agent.name) 本轮已完成"
            case .failed: return "\(notice.agent.name) 遇到了问题"
            default: return "\(notice.agent.name) 任务已中断"
            }
        }
        if let asking { return "\(asking.agent.name) 在等你回答" }
        if isRunning { return "\(runningAgentNames) 正在运行" }
        return uncertain ? "任务状态待确认" : "暂无运行中的任务"
    }
    var statusDetail: String {
        if demo { return demoRunning ? "seacoffee · 正在打磨界面" : "seacoffee · 本轮回复已结束" }
        if let notice {
            let origin = [notice.project, notice.channelName, notice.modelName].compactMap { $0 }.joined(separator: " · ")
            return canOpen(notice.agent) ? "\(origin) · 点击右侧按钮打开 \(notice.agent.name)" : origin
        }
        if let asking { return "\(asking.project) · 回答后会继续运行" }
        if let first = running.first { return "\(first.project) · \(activeConversationCount) 个对话运行中" }
        if uncertain { return "较长时间未收到事件 · 请查看对应工具" }
        return monitorMessage ?? "本地监听已开启 · 等待下一次任务"
    }
    func setWatched(_ agent: Agent, _ on: Bool) {
        if on { watchedAgents.insert(agent) } else { watchedAgents.remove(agent) }
        SeaCoffeePreferences.shared.set(Agent.allCases.filter(watchedAgents.contains).map(\.rawValue), forKey: "watchedAgents")
        startMonitor()
    }

    init(defaults: UserDefaults = SeaCoffeePreferences.shared) {
        source = Provider(rawValue: defaults.string(forKey: "source") ?? "") ?? .sub2api
        reducedMotion = defaults.bool(forKey: "reducedMotion")
        refreshMinutes = Self.refreshChoices.contains(defaults.integer(forKey: "quotaRefreshMinutes")) ? defaults.integer(forKey: "quotaRefreshMinutes") : 5
        hoverEnabled = defaults.object(forKey: "hoverEnabled") as? Bool ?? true
        let storedAgents = defaults.stringArray(forKey: "watchedAgents")
        watchedAgents = storedAgents.map { Set($0.compactMap(Agent.init(rawValue:))) } ?? Set(Agent.allCases)
        // A saved list predates agents added later; turn those on once instead of leaving them off.
        if defaults.integer(forKey: "watchedAgentsVersion") < 1 {
            if storedAgents != nil { watchedAgents.formUnion(Self.addedAgents) }
            defaults.set(1, forKey: "watchedAgentsVersion")
        }
        account.binaryPath = defaults.string(forKey: "codexBinary") ?? ""
        clineAccount.onStatus = { [weak self] text in
            self?.clineMessage = text
        }
        clineAccount.onUsage = { [weak self] usage in
            guard let self else { return }
            withAnimation(self.animation) { self.clineSnapshot = usage }
            self.recordUsage(usage, provider: "Cline Pass")
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
            self.recordUsage(usage, provider: "Claude")
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
            self.recordUsage(usage, provider: "Grok")
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
            self.recordUsage(usage, provider: "Codex 官方")
            self.refreshing = false
        }
    }
    private func recordUsage(_ usage: UsageSnapshot, provider: String) {
        guard recordsUsageHistory, !stopped else { return }
        Task {
            do {
                try await usageHistory.record(provider: provider, usage: usage)
                usageHistoryError = nil
            } catch { usageHistoryError = "额度历史保存失败，原有记录已保留；当前额度查询不受影响。" }
        }
    }
    func start() {
        recordsUsageHistory = true
        stopped = false
        refreshTimer?.invalidate()
        startMonitor(); refresh()
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(refreshMinutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() {
        recordsUsageHistory = false
        stopped = true
        authorizationTask?.cancel()
        generation = UUID() // Ignore monitor deliveries already queued on the main actor.
        noticeQueue.removeAll()
        monitor?.stop(); refreshTimer?.invalidate(); account.stop(); clineAccount.stop(); claudeAccount.stop(); grokAccount.stop()
        collapseTask?.cancel(); noticeTask?.cancel(); demoTask?.cancel(); refreshTask?.cancel()
        refreshTimer = nil; monitor = nil
        notice = nil; completion = nil; refreshing = false; demo = false
    }
    /// Keep unchanged polls quiet, retaining minute countdowns and exact stale-state transitions.
    func updateMonitoredSessions(_ sessions: [SessionState], message: String?, now: Date = Date()) {
        let clock = (minute: Int(now.timeIntervalSince1970 / 60), stale: [
            quotaIsStale(snapshot, floor: 180, now: now), quotaIsStale(clineSnapshot, floor: 180, now: now),
            quotaIsStale(claudeSnapshot, floor: 300, now: now), quotaIsStale(grokSnapshot, floor: 300, now: now)
        ])
        let clockChanged = monitorClock.map { $0.minute != clock.minute || $0.stale != clock.stale } ?? false
        monitorClock = clock
        let sessionsChanged = self.sessions != sessions, messageChanged = monitorMessage != message
        if sessionsChanged { self.sessions = sessions }
        if messageChanged { monitorMessage = message }
        if clockChanged && !sessionsChanged && !messageChanged { objectWillChange.send() }
    }
    func startMonitor() {
        guard !stopped else { return }
        monitor?.stop()
        let token = UUID(); generation = token
        monitor = SessionMonitor(sources: SessionSource.defaults(codexPath: sessionPath, enabled: watchedAgents)) { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.updateMonitoredSessions(update.sessions, message: update.message)
                for asked in update.asked { self.showNotice(asked, kind: .question) }
                for finished in update.finished { self.showNotice(finished) }
                if !update.finished.isEmpty { self.refresh() }
            }
        }
        monitor?.start()
    }
    func refresh() {
        guard !stopped else { return }
        // Independent lanes: an API request or Keychain prompt must not block the other services.
        clineAccount.refresh()
        claudeAccount.refresh()
        grokAccount.refresh()
        refreshCodex()
    }
    private func refreshCodex() {
        guard !stopped, !refreshing else { return }
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
                    let defaults = SeaCoffeePreferences.shared
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
                recordUsage(usage, provider: "Codex API")
            } catch {
                guard !Task.isCancelled else { return }
                serviceMessage = "\(error.localizedDescription)\(snapshot == nil ? "" : " · 保留上次数据")"
            }
            refreshing = false
        }
    }
    @Published var authorizingCredentials = false
    func authorizeCredentials() {
        guard !stopped, !authorizingCredentials else { return }
        authorizingCredentials = true
        authorizationTask = Task {
            defer { authorizingCredentials = false }
            do {
                if source == .sub2api {
                    _ = try await Task.detached { try SecureStore.read(allowInteraction: true) }.value
                    refreshCodex()
                }
            } catch { serviceMessage = error.localizedDescription }
            guard !Task.isCancelled, !stopped else { return }
            clineAccount.refresh(allowInteraction: true)
            claudeAccount.refresh(allowInteraction: true)
        }
    }

    func select(_ provider: Provider) {
        guard source != provider else { return }
        refreshTask?.cancel(); refreshing = false; account.stop()
        source = provider; snapshot = nil; serviceMessage = "正在连接…"
        SeaCoffeePreferences.shared.set(provider.rawValue, forKey: "source")
        refreshCodex()
    }
    func reloadSettings() {
        refreshTask?.cancel(); refreshing = false; snapshot = nil
        reducedMotion = SeaCoffeePreferences.shared.bool(forKey: "reducedMotion")
        hoverEnabled = SeaCoffeePreferences.shared.object(forKey: "hoverEnabled") as? Bool ?? true
        let minutes = SeaCoffeePreferences.shared.integer(forKey: "quotaRefreshMinutes")
        if Self.refreshChoices.contains(minutes), minutes != refreshMinutes {
            refreshMinutes = minutes
            if refreshTimer != nil { scheduleRefresh() }
        }
        account.stop(); account.binaryPath = SeaCoffeePreferences.shared.string(forKey: "codexBinary") ?? ""
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
    func showNotice(_ session: SessionState, kind: NoticeKind = .finished) {
        guard !stopped else { return }
        if demo { stopPreview() }
        if notice != nil {
            // A question and a finish of one conversation are different notices.
            func key(_ session: SessionState) -> String { kind == .question ? session.question?.id ?? "" : session.transitionID }
            if !noticeQueue.contains(where: { $0.session.id == session.id && $0.kind == kind && key($0.session) == key(session) }) {
                noticeQueue.append((session, kind))
            }
            return
        }
        presentNotice(session, kind: kind)
    }
    private func presentNotice(_ session: SessionState, kind: NoticeKind = .finished, isDemo: Bool = false) {
        noticeTask?.cancel()
        notice = session
        // A finish and a question share the badge; failures and interruptions are text in the open island.
        let badge = kind == .question || session.state == .completed
        if badge {
            let presentation = CompletionPresentation(isDemo: isDemo, kind: kind,
                initialWidth: islandWidth, initialHeight: islandHeight, wasExpanded: expanded)
            // The frame clock owns the whole morph, including returning to the island.
            completion = presentation
            expanded = false
        } else { setExpanded(true) }
        noticePresented?(session, kind)
        let duration = badge ? (reduceMotion ? CompletionMotion.reducedDuration : CompletionMotion.duration) : 5
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
        if !noticeQueue.isEmpty { let next = noticeQueue.removeFirst(); presentNotice(next.session, kind: next.kind) }
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
    /// A sample question popup, for seeing the design without waiting for an agent to ask.
    func previewQuestion() {
        guard notice == nil, !demo else { return }
        var session = SessionState(id: "preview-question", agent: .claude)
        session.project = "seacoffee"
        presentNotice(session, kind: .question, isDemo: true)
    }
    private func appURL(for agent: Agent) -> URL? {
        let candidates: [String]
        switch agent {
        case .codex: candidates = ["com.openai.codex", "com.openai.Codex", "com.bigpizzav3.codexplusplus", "com.codexhost.app"]
        case .claude: candidates = ["com.anthropic.claudefordesktop"]
        case .pi: candidates = ["net.aiuo.pi-desktop"]
        // Grok, Cline and DSH run in a terminal; there is no app to bring forward.
        case .grok, .cline, .dsh: candidates = []
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
