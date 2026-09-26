import Foundation
import IslandCore

private var failures: [String] = []
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { failures.append("\(file):\(line) \(message) expected \(expected), got \(actual)") }
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { failures.append("\(file):\(line) expected nil") }
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); failures.append("\(file):\(line) expected an error") } catch { }
}
func expectNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { failures.append("\(file):\(line) unexpected error: \(error)") }
}

@main
enum Checks {
    static func main() {
        let cline = ClineTests(); let claude = ClaudeTests(); let grok = GrokTests(); let credentials = CredentialFileTests(); let agents = AgentSessionTests()
        let telemetry = TelemetryTests(); let monitor = SessionMonitorTests()
        let checks: [(String, () throws -> Void)] = [
            ("quota color boundaries", {
                expectEqual(QuotaLevel(fraction: 0.5), .healthy)
                expectEqual(QuotaLevel(fraction: 0.49), .warning)
                expectEqual(QuotaLevel(fraction: 0.2), .warning)
                expectEqual(QuotaLevel(fraction: 0.19), .low)
                expectEqual(QuotaLevel(fraction: 0), .low)
                expectEqual(QuotaLevel(fraction: nil), .unknown)
                expectEqual(QuotaLevel(fraction: .nan), .unknown)
            }),
            ("completion timing and reduced motion", {
                expectEqual(CompletionMotion(elapsed: 0).rotation, 0)
                expectEqual(CompletionMotion(elapsed: 2).rotation, 720)
                expectEqual(CompletionMotion(elapsed: 2.3).checkProgress, 1)
                expectEqual(CompletionMotion(elapsed: CompletionMotion.duration).mergeProgress, 0)
                expectEqual(CompletionMotion(elapsed: 0).mergeProgress, 0)
                expectEqual(CompletionMotion(elapsed: 1).mergeProgress, 1)
                expectEqual(CompletionMotion(elapsed: 0, reduced: true).rotation, 0)
                expectEqual(CompletionMotion(elapsed: 0, reduced: true).checkProgress, 1)
                expectEqual(CompletionMotion(elapsed: CompletionMotion.duration).settled, true)
            }),
            ("Cline Pass quota windows", cline.windows),
            ("Cline missing and invalid quota", cline.invalidUsage),
            ("Cline token rotation and persistence", cline.tokens),
            ("Cline device authorization validation", cline.deviceAuthorization),
            ("Cline OAuth polling responses", cline.polling),
            ("Cline WorkOS authorization and HTTP errors", cline.authorizationAndErrors),
            ("Cline OAuth form encoding", cline.formEncoding),
            ("Claude quota windows", claude.windows),
            ("Claude missing and invalid quota", claude.invalidUsage),
            ("Claude Code credential parsing", claude.credentials),
            ("Claude HTTP status and rate limits", claude.httpStatus),
            ("Grok credit windows", grok.windows),
            ("Grok missing and invalid usage", grok.invalidUsage),
            ("Grok CLI credential parsing", grok.credentials),
            ("Grok plan and HTTP status", grok.planAndStatus),
            ("credential file round trip and permissions", credentials.roundTripAndPermissions),
            ("credential file rejects links and tightens modes", credentials.unsafeFiles),
            ("wallet baseline", telemetry.testWalletUsesExplicitBaselineAndRetainsActualAmount),
            ("recharge overflow", telemetry.testRechargeClampsRingButNotBalance),
            ("zero and negative balances", telemetry.testZeroBalanceIsValidAndNegativeBalanceIsNotNegativeProgress),
            ("key quota windows", telemetry.testKeyLimitsAreNotConfusedWithWallet),
            ("subscription windows", telemetry.testSubscriptionPreservesSeparateWindows),
            ("missing and invalid data", telemetry.testMissingUsageDoesNotInventFullQuota),
            ("numeric strings", telemetry.testNumericStringsAndEnvelope),
            ("invalid baseline", telemetry.testInvalidBaselineRejected),
            ("official windows", telemetry.testOfficialWindowsAndResetTimestamp),
            ("missing official data", telemetry.testMissingOfficialDataIsUnavailableNotZero),
            ("endpoint normalization", telemetry.testURLsNormalizeDashboardAndAPIBaseWithoutLeakingQuery),
            ("turn lifecycle", telemetry.testSessionRecognizesTurnLifecycleWithoutInterpretingMessagesAsCompletion),
            ("failed and cancelled tasks", telemetry.testFailureAndCancellationDoNotBecomeSuccess),
            ("malformed JSONL", telemetry.testMalformedAndUnrelatedLinesAreIgnored),
            ("incremental files and notification deduplication", monitor.testIncrementalWritesCompletionDeduplicationAndNoHistoricalNotification),
            ("resumed old conversation with concurrent completion", monitor.testResumedOldConversationSurvivesOtherConversationCompletion),
            ("file truncation and stale tasks", monitor.testTruncatedFileAndStaleRunningState),
            ("Claude Code turns, tools, subagents and interrupts", agents.claudeTurns),
            ("Grok turn outcomes", agents.grokTurns),
            ("Cline session statuses", agents.clineStatuses),
            ("Pi turns, models and Cline Pass channel", agents.piTurns),
            ("monitor follows Claude, Grok and Cline together", agents.monitorsAllAgents)
        ]
        for (name, check) in checks {
            let count = failures.count
            do { try check() } catch { failures.append("\(name): \(error)") }
            print("\(failures.count == count ? "PASS" : "FAIL") \(name)")
        }
        for error in failures { fputs(error + "\n", stderr) }
        print("\(checks.count) checks, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
