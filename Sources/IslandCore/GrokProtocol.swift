import Foundation

public enum GrokError: LocalizedError, Equatable {
    case notConnected, missingCredentials, expired, signedOut, usageUnavailable, invalidResponse, http(Int)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "请在设置中连接 Grok。"
        case .missingCredentials: return "未找到 Grok 登录，请先在终端运行 grok login。"
        case .expired: return "Grok 登录已过期，在终端运行一次 grok 即可自动续期。"
        case .signedOut: return "Grok 拒绝了当前凭据，请运行 grok login 重新登录。"
        case .usageUnavailable: return "Grok 返回了计费周期，但没有用量百分比。"
        case .invalidResponse: return "Grok 返回了无法识别的数据。"
        case .http(let code): return "Grok 请求失败（HTTP \(code)），请稍后重试。"
        }
    }
}

/// Grok Build CLI's login from `~/.grok/auth.json`. Read-only: the CLI owns refresh.
public struct GrokCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let email: String?

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    public static func parse(_ data: Data) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GrokError.invalidResponse }
        // Keys are OIDC scopes; prefer SuperGrok (auth.x.ai) over the legacy session.
        let ranked = root.keys.sorted().sorted { rank($0) < rank($1) }
        guard let entry = ranked.lazy.compactMap({ root[$0] as? [String: Any] })
                .first(where: { ($0["key"] as? String)?.isEmpty == false }),
              let token = entry["key"] as? String else { throw GrokError.missingCredentials }
        return Self(accessToken: token, expiresAt: UsageDecoder.date(entry["expires_at"]), email: entry["email"] as? String)
    }

    private static func rank(_ key: String) -> Int {
        key.hasPrefix("https://auth.x.ai::") ? 0 : key.hasPrefix("https://accounts.x.ai/sign-in") ? 1 : 2
    }
}

public enum GrokProtocol {
    public static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    public static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    public static let tokenAuthHeader = "xai-grok-cli"

    public static func validate(status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw GrokError.signedOut
        default: throw GrokError.http(status)
        }
    }

    public static func usage(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { throw GrokError.invalidResponse }
        let period = config["currentPeriod"] as? [String: Any]
        // Never mix the current period's end with the billing period's start.
        let (start, end) = UsageDecoder.date(period?["end"]) != nil
            ? (UsageDecoder.date(period?["start"]), UsageDecoder.date(period?["end"]))
            : (UsageDecoder.date(config["billingPeriodStart"]), UsageDecoder.date(config["billingPeriodEnd"]))
        let used: Double
        if let percent = UsageDecoder.number(config["creditUsagePercent"]) {
            used = percent
        } else if let cap = UsageDecoder.number((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0,
                  let spent = UsageDecoder.number((config["onDemandUsed"] as? [String: Any])?["val"]) {
            used = spent / cap * 100
        } else if end != nil {
            // A period without usage is unknown, not unused.
            throw GrokError.usageUnavailable
        } else { throw GrokError.invalidResponse }
        let quota = Quota(id: "grok-credits", label: label(type: period?["type"] as? String, start: start, end: end),
                          remaining: 100 - min(100, max(0, used)), limit: 100, monetary: false, resetsAt: end)
        return UsageSnapshot(quotas: [quota], source: "Grok")
    }

    public static func plan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = (root["subscription_tier_display"] as? String)?.trimmingCharacters(in: .whitespaces),
              !tier.isEmpty else { return nil }
        return tier
    }

    static func label(type: String?, start: Date?, end: Date?) -> String {
        let kind = type?.uppercased() ?? ""
        if kind.hasSuffix("WEEKLY") { return "每周" }
        if kind.hasSuffix("MONTHLY") { return "每月" }
        if kind.hasSuffix("DAILY") { return "每日" }
        guard let start, let end, end > start else { return "本期" }
        let days = end.timeIntervalSince(start) / 86_400
        return days >= 25 ? "每月" : days >= 6 ? "每周" : "本期"
    }
}
