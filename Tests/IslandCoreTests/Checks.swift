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
    static func main() async {
        let cline = ClineTests(); let claude = ClaudeTests(); let grok = GrokTests(); let credentials = CredentialFileTests(); let agents = AgentSessionTests(); let piDesktop = PiDesktopTests(); let topUp = WalletTopUpTests(); let dsh = DshTests()
        let telemetry = TelemetryTests(); let monitor = SessionMonitorTests()
        let checks: [(String, () async throws -> Void)] = [
            ("usage cache normalization", UsageAnalyticsTests().normalization),
            ("usage statistics matching CC Switch: dedup, cost, speed, rollups", UsageAnalyticsTests().statistics),
            ("unified usage: DSH sessions, requests, filters and groups", UsageAnalyticsTests().combinedRecords),
            ("DSH-only usage without request data or fabricated costs", UsageAnalyticsTests().dshOnlyRecords),
            ("model pricing candidates in CC Switch order", ModelPricingTests().candidates),
            ("model pricing exact and prefix lookup", ModelPricingTests().lookup),
            ("cost calculation by input semantics and multiplier", ModelPricingTests().cost),
            ("usage formatting matches CC Switch strings", UsageFormatTests().formatting),
            ("quota history persistence, retention and isolation", UsageAnalyticsTests().quotaHistory),
            ("quota color boundaries", {
                expectEqual(QuotaLevel(fraction: 0.5), .healthy)
                expectEqual(QuotaLevel(fraction: 0.2), .healthy)
                expectEqual(QuotaLevel(fraction: 0.195), .healthy)
                expectEqual(QuotaLevel(fraction: 0.19), .warning)
                expectEqual(QuotaLevel(fraction: 0.01), .warning)
                expectEqual(QuotaLevel(fraction: 0.004), .low)
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
            ("Claude /usage screen fallback", claude.usageScreen),
            ("Grok credit windows", grok.windows),
            ("Grok missing and invalid usage", grok.invalidUsage),
            ("Grok CLI credential parsing", grok.credentials),
            ("Grok plan and HTTP status", grok.planAndStatus),
            ("credential preview masks secrets and short keys", credentials.maskedPreview),
            ("credential file round trip and permissions", credentials.roundTripAndPermissions),
            ("credential file rejects links and tightens modes", credentials.unsafeFiles),
            ("wallet baseline", telemetry.testWalletUsesExplicitBaselineAndRetainsActualAmount),
            ("wallet top-up resets the baseline", topUp.rebasing),
            ("wallet snapshot rebasing", topUp.snapshotRebase),
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
            ("auxiliary Codex calls stay off the island", monitor.testAuxiliaryCodexCallsStayOffTheIsland),
            ("Claude Code turns, tools, subagents and interrupts", agents.claudeTurns),
            ("Claude Code questions: waiting, answered, interrupted", agents.claudeQuestions),
            ("Codex questions: one-off notice", agents.codexQuestions),
            ("monitor reports fresh questions once", agents.monitorReportsQuestions),
            ("Grok turn outcomes", agents.grokTurns),
            ("Cline session statuses", agents.clineStatuses),
            ("Pi turns, models and Cline Pass channel", agents.piTurns),
            ("PI-Desktop database: latest turn per session", piDesktop.latestTurnPerSession),
            ("PI-Desktop database: completion notices", piDesktop.monitorReportsCompletion),
            ("DSH projection cache, tokens and speed", dsh.cacheAndSessionState),
            ("DSH snapshot monitoring and completion", dsh.storeAndMonitor),
            ("rewritten old cache does not announce a finish", dsh.rewrittenOldCacheDoesNotNotify),
            ("monitor follows Claude, Grok and Cline together", agents.monitorsAllAgents),
            ("Claude background subagents keep a conversation running", agents.backgroundSubagents)
        ]
        for (name, check) in checks {
            let count = failures.count
            do { try await check() } catch { failures.append("\(name): \(error)") }
            print("\(failures.count == count ? "PASS" : "FAIL") \(name)")
        }
        for error in failures { fputs(error + "\n", stderr) }
        print("\(checks.count) checks, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
