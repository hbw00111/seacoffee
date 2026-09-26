import Foundation
import IslandCore

final class GrokTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func windows() throws {
        let usage = try GrokProtocol.usage(data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-23T03:15:23.440068+00:00","end":"2026-09-30T03:15:23.440068+00:00"},"creditUsagePercent":10.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":9.0}],"billingPeriodStart":"2026-09-01T00:00:00+00:00","billingPeriodEnd":"2026-10-01T00:00:00+00:00"}}"#))
        expectEqual(usage.quotas.map(\.label), ["每周"])
        expectEqual(usage.quotas.map(\.percent), [90])
        expectEqual(usage.quotas.first?.monetary, false)
        expectEqual(usage.quotas.first?.resetsAt, UsageDecoder.date("2026-09-30T03:15:23.440068+00:00"))
        expectEqual(usage.source, "Grok")
        // Without the current period, the billing period supplies both bounds; on-demand spend is the fallback.
        let monthly = try GrokProtocol.usage(data(#"{"config":{"onDemandCap":{"val":2000},"onDemandUsed":{"val":500},"billingPeriodStart":"2026-09-01T00:00:00Z","billingPeriodEnd":"2026-10-01T00:00:00Z"}}"#))
        expectEqual(monthly.quotas.first?.label, "每月")
        expectEqual(monthly.quotas.first?.percent, 75)
        expectEqual(monthly.quotas.first?.resetsAt, UsageDecoder.date("2026-10-01T00:00:00Z"))
        let over = try GrokProtocol.usage(data(#"{"config":{"creditUsagePercent":"130"}}"#))
        expectEqual(over.quotas.first?.percent, 0)
        expectEqual(over.quotas.first?.label, "本期")
    }

    func invalidUsage() {
        expectGrokError(.usageUnavailable, try GrokProtocol.usage(data(#"{"config":{"currentPeriod":{"end":"2026-09-30T03:15:23Z"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}"#)))
        for json in [#"{}"#, #"{"config":{}}"#, #"{"config":{"creditUsagePercent":true}}"#, "nope"] {
            expectThrows(try GrokProtocol.usage(data(json)))
        }
    }

    func credentials() throws {
        let parsed = try GrokCredentials.parse(data(#"{"https://accounts.x.ai/sign-in":{"key":"legacy"},"https://auth.x.ai::client":{"key":"super","expires_at":"2026-09-26T08:25:10.236488Z","email":"a@example.com"}}"#))
        expectEqual(parsed.accessToken, "super")
        expectEqual(parsed.email, "a@example.com")
        expectEqual(parsed.expiresAt, UsageDecoder.date("2026-09-26T08:25:10.236488Z"))
        expectEqual(try GrokCredentials.parse(data(#"{"https://auth.x.ai::c":{"key":""},"https://accounts.x.ai/sign-in":{"key":"legacy"}}"#)).accessToken, "legacy")
        expectEqual(try GrokCredentials.parse(data(#"{"x":{"key":"a","expires_at":"2020-01-01T00:00:00Z"}}"#)).isExpired, true)
        expectGrokError(.missingCredentials, try GrokCredentials.parse(data(#"{}"#)))
        expectGrokError(.invalidResponse, try GrokCredentials.parse(data("[]")))
    }

    func planAndStatus() {
        expectEqual(GrokProtocol.plan(data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#)), "SuperGrok Heavy")
        expectNil(GrokProtocol.plan(data(#"{"subscription_tier_display":" "}"#)))
        expectNil(GrokProtocol.plan(data(#"{}"#)))
        expectNoThrow(try GrokProtocol.validate(status: 200))
        expectGrokError(.signedOut, try GrokProtocol.validate(status: 401))
        expectGrokError(.signedOut, try GrokProtocol.validate(status: 403))
        expectGrokError(.http(502), try GrokProtocol.validate(status: 502))
    }

    private func expectGrokError<T>(_ expected: GrokError, _ expression: @autoclosure () throws -> T,
                                    file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try expression(); expectEqual("no error", "\(expected)", file: file, line: line) }
        catch let error as GrokError { expectEqual(error, expected, file: file, line: line) }
        catch { expectEqual("\(error)", "\(expected)", file: file, line: line) }
    }
}
