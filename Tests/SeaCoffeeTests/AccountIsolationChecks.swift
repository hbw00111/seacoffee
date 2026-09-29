import Foundation
import IslandCore

@main enum AccountIsolationChecks {
    @MainActor static func main() {
        let suite = "SeaCoffeeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cline", forKey: "source")
        let model = IslandModel(defaults: defaults)
        precondition(model.source == .sub2api, "Legacy Cline selection must retain an API lane")
        let api = UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额", remaining: 42, limit: 100)], balance: 42, source: "API")
        let cline = UsageSnapshot(quotas: [Quota(id: "five_hour", label: "5 小时", remaining: 71, limit: 100, monetary: false)], source: "Cline Pass", fetchedAt: .distantPast)
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
        print("PASS migration, independent snapshots/status/staleness, Cline logout, Codex clearing, dual demo and panel bounds")
    }
}
