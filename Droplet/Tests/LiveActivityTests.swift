import Foundation
import Combine
import IslandCore
import DroppyKit
import DroppyKitHarness
@testable import SeaCoffeeDroplet

@main
struct LiveActivityChecks {
    @MainActor
    static func main() async throws {
        let droplet = SeaCoffeeDroplet()
        let session = HarnessSession(droplet: droplet, manifest: nil, manifestProblem: nil)
        var latest: LiveActivityState?
        let subscription = droplet.liveActivityState.sink { latest = $0 }
        defer { subscription.cancel(); session.deactivate() }
        session.activate()
        precondition(session.activationError == nil)
        // The harness never starts real accounts or monitors. Exit its demo
        // fixture to exercise a genuinely idle model with no notice/session.
        droplet.model.demo = false
        droplet.model.sessions = []
        droplet.model.notice = nil
        droplet.model.snapshot = UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额基准", remaining: 68, limit: 100)])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(!droplet.model.isRunning)
        precondition(latest?.joinsPersistentActivitySet == true)
        precondition(latest?.accessibilityTitle.contains("68%") == true)

        droplet.model.snapshot = UsageSnapshot(quotas: [Quota(id: "wallet", label: "余额基准", remaining: 19, limit: 100)])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(latest?.accessibilityTitle.contains("19%") == true)
        precondition(latest?.accessibilityTitle.contains("68%") != true)

        droplet.model.snapshot = nil
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(latest?.accessibilityTitle.contains("Codex") == true)
        precondition(latest?.accessibilityTitle.contains("未知") == true)
        precondition(latest != nil)

        session.deactivate()
        precondition(latest == nil)
        droplet.model.snapshot = UsageSnapshot(quotas: [])
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(latest == nil)
        print("PASS persistent idle quotas, refreshed values, unknown values, deactivation")
    }
}
