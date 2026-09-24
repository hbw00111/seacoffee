import Foundation
import IslandCore

final class TelemetryTests {
    func testWalletUsesExplicitBaselineAndRetainsActualAmount() throws {
        let value = try decode(#"{"mode":"unrestricted","isValid":true,"balance":68.4,"remaining":68.4}"#)
        expectEqual(value.balance, 68.4)
        expectEqual(value.quotas.first?.percent, 68)
        expectEqual(value.quotas.first?.id, "wallet")
    }
    func testRechargeClampsRingButNotBalance() throws {
        let value = try decode(#"{"balance":150}"#)
        expectEqual(value.balance, 150)
        expectEqual(value.quotas.first?.percent, 100)
    }
    func testZeroBalanceIsValidAndNegativeBalanceIsNotNegativeProgress() throws {
        expectEqual(try decode(#"{"balance":0}"#).quotas.first?.percent, 0)
        expectEqual(try decode(#"{"balance":-2}"#).quotas.first?.percent, 0)
    }
    func testKeyLimitsAreNotConfusedWithWallet() throws {
        let value = try decode(#"{"mode":"quota_limited","quota":{"limit":200,"used":150,"remaining":50},"rate_limits":[{"window":"5h","limit":20,"used":4,"remaining":16}]}"#)
        expectNil(value.balance)
        expectEqual(value.quotas.map(\.percent), [25, 80])
        expectEqual(value.quotas.map(\.id), ["key", "window-0"])
    }
    func testSubscriptionPreservesSeparateWindows() throws {
        let value = try decode(#"{"subscription":{"daily_limit_usd":10,"daily_usage_usd":2,"weekly_limit_usd":50,"weekly_usage_usd":30,"monthly_limit_usd":0,"monthly_usage_usd":90}}"#)
        expectEqual(value.quotas.map(\.percent), [80, 40])
        expectEqual(value.quotas.map(\.label), ["每日配额", "每周配额"])
    }
    func testMissingUsageDoesNotInventFullQuota() {
        expectThrows(try decode(#"{"subscription":{"daily_limit_usd":10}}"#))
        expectThrows(try decode(#"{"remaining":40}"#))
        expectThrows(try decode(#"{"balance":true}"#))
        expectThrows(try decode(#"{"balance":"nan"}"#))
        expectThrows(try decode(#"{"balance":50,"isValid":false}"#))
    }
    func testNumericStringsAndEnvelope() throws {
        expectEqual(try decode(#"{"data":{"balance":"45.5"}}"#).quotas.first?.percent, 46)
    }
    func testInvalidBaselineRejected() {
        for limit in [0.0, -1, .infinity, .nan] {
            expectThrows(try UsageDecoder.sub2API(Data(#"{"balance":1}"#.utf8), baseline: limit))
        }
    }
    func testOfficialWindowsAndResetTimestamp() throws {
        let value = try UsageDecoder.official([
            "rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 24, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                "secondary": ["usedPercent": 60, "windowDurationMins": 10080]
            ]] as [String: Any]
        ])
        expectEqual(value.quotas.map(\.percent), [76, 40])
        expectEqual(value.quotas.map(\.label), ["5 小时", "7 天"])
        expectEqual(value.quotas.first?.resetsAt?.timeIntervalSince1970, 1_800_000_000)
    }
    func testMissingOfficialDataIsUnavailableNotZero() {
        expectThrows(try UsageDecoder.official([:]))
        expectThrows(try UsageDecoder.official(["primary": ["usedPercent": NSNull()]]))
    }
    func testURLsNormalizeDashboardAndAPIBaseWithoutLeakingQuery() throws {
        for url in ["https://coderteam.icu", "https://coderteam.icu/redeem", "https://coderteam.icu/v1/", "https://coderteam.icu/v1/usage?token=secret"] {
            expectEqual(try UsageDecoder.endpoint(url).absoluteString, "https://coderteam.icu/v1/usage")
        }
        expectEqual(try UsageDecoder.endpoint("https://example.com/proxy/v1").absoluteString, "https://example.com/proxy/v1/usage")
        expectThrows(try UsageDecoder.endpoint("http://example.com"))
        expectThrows(try UsageDecoder.endpoint("https://user:secret@example.com"))
        expectNoThrow(try UsageDecoder.endpoint("http://127.0.0.1:8080"))
    }
    func testSessionRecognizesTurnLifecycleWithoutInterpretingMessagesAsCompletion() {
        var session = SessionState(id: "s1")
        session.consume(Data(#"{"type":"session_meta","payload":{"cwd":"/Users/example/seacoffee"}}"#.utf8))
        session.consume(event("task_started", at: "2026-09-21T12:00:00Z"))
        expectEqual(session.state, .running)
        session.consume(event("agent_message", at: "2026-09-21T12:00:01Z"))
        expectEqual(session.state, .running)
        session.consume(event("task_complete", at: "2026-09-21T12:00:02.123Z"))
        expectEqual(session.state, .completed)
        expectEqual(session.project, "seacoffee")
        let id = session.transitionID
        session.consume(event("task_complete", at: "2026-09-21T12:00:02.123Z"))
        expectEqual(session.transitionID, id)
        session.consume(event("task_started", at: "2026-09-21T12:00:00Z"))
        expectEqual(session.state, .completed)
    }
    func testFailureAndCancellationDoNotBecomeSuccess() {
        var session = SessionState(id: "s")
        session.consume(event("task_started", at: "2026-09-21T12:00:00Z"))
        session.consume(event("turn_aborted", at: "2026-09-21T12:00:01Z"))
        expectEqual(session.state, .interrupted)
        session.consume(event("task_started", at: "2026-09-21T12:00:02Z"))
        session.consume(event("task_failed", at: "2026-09-21T12:00:03Z"))
        expectEqual(session.state, .failed)
    }
    func testMalformedAndUnrelatedLinesAreIgnored() {
        var session = SessionState(id: "s")
        for line in ["{bad", "null", "[]", #"{"type":"response_item","payload":{"type":"task_complete"}}"#] {
            session.consume(Data(line.utf8))
        }
        expectEqual(session.state, .unknown)
    }
    private func decode(_ json: String) throws -> UsageSnapshot {
        try UsageDecoder.sub2API(Data(json.utf8), baseline: 100)
    }
    private func event(_ kind: String, at time: String) -> Data {
        Data("{\"type\":\"event_msg\",\"timestamp\":\"\(time)\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"turn-1\"}}".utf8)
    }
}
