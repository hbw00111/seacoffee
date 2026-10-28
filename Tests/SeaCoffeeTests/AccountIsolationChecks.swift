import Foundation
import Combine
import IslandCore

@main enum AccountIsolationChecks {
    @MainActor static func main() {
        let suite = "SeaCoffeeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cline", forKey: "source")
        let model = IslandModel(defaults: defaults)
        precondition(model.source == .sub2api, "Legacy Cline selection must retain an API lane")
        let api = UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额", remaining: 42, limit: 100)], balance: 42)
        let cline = UsageSnapshot(quotas: [Quota(id: "five_hour", label: "5 小时", remaining: 71, limit: 100, monetary: false)], fetchedAt: .distantPast)
        model.snapshot = api
        model.refreshing = true
        model.serviceMessage = "API 正在刷新"
        model.clineAccount.onUsage?(cline)
        model.clineAccount.onStatus?("Cline 已连接")
        precondition(model.snapshot == api && model.clineSnapshot == cline)
        precondition(model.refreshing && model.serviceMessage == "API 正在刷新")
        precondition(model.clineIsStale && !model.isStale)
        model.clineAccount.onStatus?("Cline 请求失败")
        precondition(model.clineSnapshot == cline && model.snapshot == api)
        model.source = .official
        model.account.onUsage?(api)
        model.account.onStatus?("Codex 已连接")
        precondition(model.clineSnapshot == cline && model.clineMessage == "Cline 请求失败")
        precondition(!model.refreshing && model.serviceMessage == "Codex 已连接")
        model.clineAccount.onLogout?()
        precondition(model.clineSnapshot == nil && model.snapshot == api)
        model.clineAccount.onUsage?(cline)
        model.snapshot = nil
        precondition(model.clineSnapshot == cline)
        model.demo = true
        precondition(model.displayedSnapshot != nil && model.displayedClineSnapshot != nil)
        model.expanded = true
        precondition(model.islandHeight < 480)
        var notifications = 0
        model.noticePresented = { _, _ in notifications += 1 }
        model.demo = false
        var finished = SessionState(id: "droplet-lifecycle-fixture")
        finished.state = .completed
        model.showNotice(finished)
        precondition(notifications == 1, "Host receives the completed task once")
        model.showNotice(finished, kind: .question) // Queued behind completion.
        model.stop()
        precondition(model.notice == nil && model.completion == nil && !model.refreshing)
        model.showNotice(finished)
        model.refresh()
        model.authorizeCredentials()
        precondition(notifications == 1 && !model.refreshing && !model.authorizingCredentials,
                     "A disabled droplet must not emit notices or restart account requests")
        let monitoring = IslandModel(defaults: defaults)
        var publications = 0
        let observation = monitoring.objectWillChange.sink { publications += 1 }
        var active = SessionState(id: "unchanged-poll")
        active.state = .running
        let clock = Date(timeIntervalSince1970: 1_800_000_020)
        monitoring.updateMonitoredSessions([active], message: nil, now: clock)
        precondition(publications == 1)
        for _ in 0..<60 { monitoring.updateMonitoredSessions([active], message: nil, now: clock) }
        precondition(publications == 1, "Unchanged monitor polls must not invalidate the settings or island")
        active.project = "changed-project"
        monitoring.updateMonitoredSessions([active], message: "monitor warning", now: clock)
        precondition(publications == 3 && monitoring.sessions.first?.project == "changed-project")
        monitoring.updateMonitoredSessions([], message: nil, now: clock)
        precondition(publications == 5 && monitoring.sessions.isEmpty && monitoring.monitorMessage == nil)
        monitoring.updateMonitoredSessions([], message: nil, now: clock.addingTimeInterval(60))
        precondition(publications == 6, "Quota countdowns must still advance while tasks are idle")
        monitoring.snapshot = UsageSnapshot(quotas: [], fetchedAt: clock)
        monitoring.updateMonitoredSessions([], message: nil, now: clock.addingTimeInterval(650))
        let beforeStale = publications
        monitoring.updateMonitoredSessions([], message: nil, now: clock.addingTimeInterval(661))
        precondition(publications == beforeStale + 1, "Quota staleness must publish within the same clock minute")
        monitoring.updateMonitoredSessions([], message: nil, now: clock.addingTimeInterval(662))
        precondition(publications == beforeStale + 1)
        observation.cancel()
        print("PASS monitor publications: unchanged polls stay quiet; session and error changes propagate")
        print("PASS droplet lifecycle: notice delivery, queued notice cleanup, stopped refresh guard")
        print("PASS migration, independent snapshots/status/staleness, Cline logout, Codex clearing, dual demo and panel bounds")
    }
}
