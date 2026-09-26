import Foundation

public enum ClaudeError: LocalizedError, Equatable {
    case notConnected, missingCredentials, missingScope, expired, signedOut, rateLimited(Date?), invalidResponse, http(Int)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "请在设置中连接 Claude Code。"
        case .missingCredentials: return "未找到 Claude Code 登录，请先在终端运行 claude 并登录。"
        case .missingScope: return "当前 Claude 凭据没有读取额度的权限，请运行 claude 重新登录（setup-token 生成的令牌不可用）。"
        case .expired: return "Claude Code 登录已过期，在终端运行一次 claude 即可自动续期。"
        case .signedOut: return "Claude 拒绝了当前凭据，请运行 claude 重新登录。"
        case .rateLimited(let until):
            return "Claude 额度接口暂时限流" + (until.map { "，\($0.formatted(date: .omitted, time: .shortened)) 后重试" } ?? "，稍后自动重试")
        case .invalidResponse: return "Claude 返回了无法识别的数据。"
        case .http(let code): return "Claude 请求失败（HTTP \(code)），请稍后重试。"
        }
    }
}

/// Claude Code's own OAuth login. Sea Coffee only reads it; refreshing would rotate
/// Claude Code's refresh token, so expiry is left to the Claude CLI.
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let plan: String?

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    public static func parse(_ data: Data) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.invalidResponse }
        // Claude Code 2.1 can store only MCP OAuth state under the same item.
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw ClaudeError.missingCredentials }
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty, !scopes.contains("user:profile") {
            throw ClaudeError.missingScope
        }
        let expires = UsageDecoder.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Self(accessToken: token, expiresAt: expires, plan: planName(oauth))
    }

    static func planName(_ oauth: [String: Any]) -> String? {
        let tier = (oauth["rateLimitTier"] as? String ?? "").lowercased()
        let multiplier = tier.contains("20x") ? " 20x" : tier.contains("5x") ? " 5x" : ""
        let type = (oauth["subscriptionType"] as? String ?? "").lowercased()
        let base = type.isEmpty ? ["max", "pro", "team", "enterprise"].first { tier.contains($0) } ?? "" : type
        guard !base.isEmpty else { return nil }
        return base.prefix(1).uppercased() + base.dropFirst() + (base == "max" ? multiplier : "")
    }
}

public enum ClaudeProtocol {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-code/2.1.0"

    public static func validate(status: Int, retryAfter: String?, now: Date = Date()) throws {
        switch status {
        case 200..<300: return
        case 401: throw ClaudeError.signedOut
        case 403: throw ClaudeError.missingScope
        case 429:
            let until = retryAfter.flatMap(Double.init).map { now.addingTimeInterval($0) }
            throw ClaudeError.rateLimited(until)
        default: throw ClaudeError.http(status)
        }
    }

    public static func usage(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.invalidResponse }
        let windows = [("five_hour", "5 小时"), ("seven_day", "每周"),
                       ("seven_day_sonnet", "Sonnet 每周"), ("seven_day_opus", "Opus 每周")]
        let quotas = windows.compactMap { key, label -> Quota? in
            // A window without utilization is unknown, not unused.
            guard let window = root[key] as? [String: Any],
                  let used = UsageDecoder.number(window["utilization"]), used >= 0 else { return nil }
            return Quota(id: "claude-\(key)", label: label, remaining: 100 - used, limit: 100,
                         monetary: false, resetsAt: UsageDecoder.date(window["resets_at"]))
        }
        guard !quotas.isEmpty else { throw TelemetryError.unsupported }
        return UsageSnapshot(quotas: quotas, source: "Claude")
    }
}
