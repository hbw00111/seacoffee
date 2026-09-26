import Foundation
import IslandCore

final class ClaudeTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func windows() throws {
        let usage = try ClaudeProtocol.usage(data(#"{"five_hour":{"utilization":27.4,"resets_at":"2026-09-26T15:00:00.123Z"},"seven_day":{"utilization":0,"resets_at":null},"seven_day_opus":{"utilization":null},"seven_day_sonnet":{"utilization":112},"extra_usage":{"is_enabled":false}}"#))
        expectEqual(usage.quotas.map(\.label), ["5 小时", "每周", "Sonnet 每周"])
        expectEqual(usage.quotas.map(\.percent), [73, 100, 0])
        expectEqual(usage.quotas.map(\.monetary), [false, false, false])
        expectEqual(usage.quotas.first?.resetsAt, UsageDecoder.date("2026-09-26T15:00:00.123Z"))
        expectNil(usage.quotas[1].resetsAt)
        expectEqual(usage.source, "Claude")
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

    func httpStatus() {
        let now = Date(timeIntervalSince1970: 1000)
        expectNoThrow(try ClaudeProtocol.validate(status: 200, retryAfter: nil))
        expectError(.signedOut, try ClaudeProtocol.validate(status: 401, retryAfter: nil))
        expectError(.missingScope, try ClaudeProtocol.validate(status: 403, retryAfter: nil))
        expectError(.rateLimited(Date(timeIntervalSince1970: 1120)), try ClaudeProtocol.validate(status: 429, retryAfter: "120", now: now))
        expectError(.rateLimited(nil), try ClaudeProtocol.validate(status: 429, retryAfter: "Fri, 01 Jan", now: now))
        expectError(.http(500), try ClaudeProtocol.validate(status: 500, retryAfter: nil))
    }

    private func expectError<T>(_ expected: ClaudeError, _ expression: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try expression(); expectEqual("no error", "\(expected)", file: file, line: line) }
        catch let error as ClaudeError { expectEqual(error, expected, file: file, line: line) }
        catch { expectEqual("\(error)", "\(expected)", file: file, line: line) }
    }
}
