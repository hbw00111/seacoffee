import Foundation
import IslandCore

final class ClaudeTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func windows() throws {
        let usage = try ClaudeProtocol.usage(data(#"{"five_hour":{"utilization":27.4,"resets_at":"2026-09-26T15:00:00.123Z"},"seven_day":{"utilization":0,"resets_at":null},"seven_day_opus":{"utilization":null},"seven_day_sonnet":{"utilization":112},"extra_usage":{"is_enabled":false}}"#))
        expectEqual(usage.quotas.map(\.label), ["5 小时", "每周", "每周 Sonnet"])
        expectEqual(usage.quotas.map(\.percent), [73, 100, 0])
        expectEqual(usage.quotas.map(\.monetary), [false, false, false])
        expectEqual(usage.quotas.first?.resetsAt, UsageDecoder.date("2026-09-26T15:00:00.123Z"))
        expectNil(usage.quotas[1].resetsAt)
        // Weekly becomes primary when the session window is missing.
        let weekly = try ClaudeProtocol.usage(data(#"{"five_hour":null,"seven_day":{"utilization":"40"}}"#))
        expectEqual(weekly.quotas.first?.label, "每周")
        expectEqual(weekly.quotas.first?.percent, 60)
    }

    func invalidUsage() {
        for json in [#"{}"#, #"[]"#, #"{"five_hour":{"utilization":true}}"#,
                     #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{}}"#, "not json"] {
            expectThrows(try ClaudeProtocol.usage(data(json)))
        }
    }

    func credentials() throws {
        let parsed = try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"r","expiresAt":1790000000000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#))
        expectEqual(parsed.accessToken, "sk-ant-oat-x")
        expectEqual(parsed.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
        expectEqual(parsed.plan, "Max 20x")
        expectEqual(try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"a","rateLimitTier":"default_claude_pro"}}"#)).plan, "Pro")
        expectNil(try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"a"}}"#)).plan)
        expectEqual(try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"a","expiresAt":1000}}"#)).isExpired, true)
        expectEqual(try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"a"}}"#)).isExpired, false)
        expectError(.missingCredentials, try ClaudeCredentials.parse(data(#"{"mcpOAuth":{"server":{}}}"#)))
        expectError(.missingCredentials, try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":""}}"#)))
        expectError(.missingScope, try ClaudeCredentials.parse(data(#"{"claudeAiOauth":{"accessToken":"a","scopes":["user:inference"]}}"#)))
        expectError(.invalidResponse, try ClaudeCredentials.parse(data("garbage")))
    }

    func keychainStamp() {
        let output = """
        keychain: "/Users/me/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="me"
            "cdat"<timedate>=0x32303236303932343033323830385A00  "20260924032808Z\\000"
            "mdat"<timedate>=0x32303236313032383031313934375A00  "20261028011947Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """
        let stamp = KeychainItemStamp.parse(output)
        expectEqual(stamp, KeychainItemStamp.parse(output.replacingOccurrences(of: "keychain:", with: "keychain :")))
        expectEqual(stamp?.created, "20260924032808Z")
        expectEqual(stamp?.modified, "20261028011947Z")
        let rewritten = KeychainItemStamp.parse(output.replacingOccurrences(of: "20261028011947Z", with: "20261028051300Z"))
        expectEqual(KeychainItemStamp.changed(from: stamp, to: rewritten), true)
        expectEqual(KeychainItemStamp.changed(from: stamp, to: stamp), false)
        // Unreadable on either side is inconclusive, never a renewal or a failed one.
        expectNil(KeychainItemStamp.changed(from: nil, to: stamp))
        expectNil(KeychainItemStamp.changed(from: stamp, to: nil))
        expectNil(KeychainItemStamp.parse(output.replacingOccurrences(of: "\"mdat\"", with: "\"xdat\"")))
        expectNil(KeychainItemStamp.parse(output.replacingOccurrences(of: "\"20260924032808Z", with: "\"2026Z")))
        expectNil(KeychainItemStamp.parse(""))
    }

    func httpStatus() {
        let now = Date(timeIntervalSince1970: 1000)
        expectNoThrow(try ClaudeProtocol.validate(status: 200, retryAfter: nil))
        expectError(.signedOut, try ClaudeProtocol.validate(status: 401, retryAfter: nil))
        expectError(.missingScope, try ClaudeProtocol.validate(status: 403, retryAfter: nil))
        expectError(.rateLimited(Date(timeIntervalSince1970: 1120)), try ClaudeProtocol.validate(status: 429, retryAfter: "120", now: now))
        expectError(.rateLimited(nil), try ClaudeProtocol.validate(status: 429, retryAfter: "Fri, 01 Jan", now: now))
        expectError(.http(500), try ClaudeProtocol.validate(status: 500, retryAfter: nil))
    }

    func usageScreen() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-10-18 10:00 in Shanghai.
        let now = Date(timeIntervalSince1970: 1_792_288_800)
        let esc = "\u{1B}"
        // An early frame still loading, then the full frame; the later one wins.
        let screen = """
        \(esc)[2K\(esc)[1ACurrent session\(esc)[1B\(esc)[2G█████\(esc)[3C9% used\r
        Settings\(esc)[2CStatus\(esc)[2CUsage\r
        \(esc)[?25lCurrent session\(esc)[1E██████████\(esc)[10C19% used\(esc)[1EResets 3pm (Asia/Shanghai)\r
        Current week (all models)\(esc)[1E███\(esc)[5C42.5% used\(esc)[1EResets Oct 21, 11am (Asia/Shanghai)\r
        Current week (Sonnet only)\r\n80% left\r\nResets Jan 3 at 9:30am\r
        \(esc)]0;claude\u{07}What's contributing to your limits usage?\r
        """
        guard let usage = ClaudeUsageScreen.usage(screen, now: now, timeZone: shanghai) else {
            return expectEqual("nil", "usage", "screen should parse")
        }
        expectEqual(usage.quotas.map(\.id), ["claude-five_hour", "claude-seven_day", "claude-seven_day_sonnet"])
        expectEqual(usage.quotas.map(\.label), ["5 小时", "每周", "每周 Sonnet"])
        expectEqual(usage.quotas.map(\.remaining), [81, 57.5, 80])
        expectEqual(usage.quotas.map(\.monetary), [false, false, false])
        guard usage.quotas.count == 3 else { return }
        expectEqual(usage.quotas[0].resetsAt, Date(timeIntervalSince1970: 1_792_306_800))  // today 15:00
        expectEqual(usage.quotas[1].resetsAt, Date(timeIntervalSince1970: 1_792_551_600))  // Oct 21 11:00
        expectEqual(usage.quotas[2].resetsAt, Date(timeIntervalSince1970: 1_798_939_800))  // next Jan 3 09:30

        // A time already passed today means tomorrow.
        expectEqual(ClaudeUsageScreen.usage("Current session\n50% used\nResets 9am", now: now, timeZone: shanghai)?
            .quotas.first?.resetsAt, Date(timeIntervalSince1970: 1_792_371_600))
        // Unreadable reset text is unknown, not a guess.
        expectNil(ClaudeUsageScreen.usage("Current session\n50% used\nResets soon", now: now, timeZone: shanghai)?
            .quotas.first?.resetsAt)
        // No percentage, or an impossible one, is not usage.
        for text in ["", "Current session\nLoading…", "Current session\n140% used", "Total cost: $0.00\n18% of your usage came from MCP"] {
            expectNil(ClaudeUsageScreen.usage(text, now: now, timeZone: shanghai))
        }
    }

    private func expectError<T>(_ expected: ClaudeError, _ expression: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try expression(); expectEqual("no error", "\(expected)", file: file, line: line) }
        catch let error as ClaudeError { expectEqual(error, expected, file: file, line: line) }
        catch { expectEqual("\(error)", "\(expected)", file: file, line: line) }
    }
}
