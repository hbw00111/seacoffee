import Foundation

public enum ClineError: LocalizedError {
    case invalidResponse, notConnected, signedOut, forbidden, denied, expired, noSubscription, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Cline 返回了无法识别的数据。"
        case .notConnected: return "请在设置中连接 Cline 账号。"
        case .signedOut: return "Cline 登录凭据已被拒绝，请重新登录。"
        case .forbidden: return "已保存 Cline 登录，但配额接口拒绝访问（HTTP 403）。"
        case .denied: return "Cline 登录授权已拒绝。"
        case .noSubscription: return "账号已连接，但 Cline Pass 套餐暂不可用，请在官网检查订阅。"
        case .expired: return "Cline 登录已超时，请重新连接。"
        case .http(let code): return "Cline 请求失败（HTTP \(code)），请稍后重试。"
        }
    }
}

public struct ClineCredentials: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let email: String?

    public static func parse(_ data: Data, previous: ClineCredentials? = nil) throws -> Self {
        let object = try ClineProtocol.envelope(data)
        guard let access = object["accessToken"] as? String, !access.isEmpty,
              let refresh = object["refreshToken"] as? String ?? previous?.refreshToken, !refresh.isEmpty,
              let expires = UsageDecoder.date(object["expiresAt"]) else { throw ClineError.invalidResponse }
        let user = object["userInfo"] as? [String: Any]
        return Self(accessToken: access, refreshToken: refresh, expiresAt: expires,
                    email: user?["email"] as? String ?? previous?.email)
    }
}

public struct ClineDeviceAuthorization: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Double
    public let interval: Double

    public static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device_code"] as? String, !device.isEmpty,
              let user = object["user_code"] as? String, !user.isEmpty,
              let link = object["verification_uri_complete"] as? String ?? object["verification_uri"] as? String,
              let url = URL(string: link), url.scheme == "https", let host = url.host,
              (host == "cline.bot" || host.hasSuffix(".cline.bot") || host == "workos.com" || host.hasSuffix(".workos.com")),
              url.user == nil, url.password == nil else { throw ClineError.invalidResponse }
        let expires = UsageDecoder.number(object["expires_in"]) ?? 300
        let interval = UsageDecoder.number(object["interval"]) ?? 5
        guard expires > 0, expires <= 3600, interval > 0, interval <= 300 else { throw ClineError.invalidResponse }
        return Self(deviceCode: device, userCode: user, verificationURL: url, expiresIn: expires, interval: interval)
    }
}

public enum ClinePollResult: Equatable, Sendable {
    case pending, slowDown
    case authorized(access: String, refresh: String)
}

public enum ClineProtocol {
    // Cline routes WorkOS credentials by this prefix; a raw JWT is rejected with 401.
    public static func authorizationHeader(_ accessToken: String) -> String {
        let token = accessToken.lowercased().hasPrefix("workos:") ? accessToken : "workos:" + accessToken
        return "Bearer " + token
    }

    public static func validateUsageStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw ClineError.signedOut
        case 403: throw ClineError.forbidden
        case 402, 404: throw ClineError.noSubscription
        default: throw ClineError.http(status)
        }
    }

    public static func poll(_ data: Data, status: Int) throws -> ClinePollResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClineError.invalidResponse }
        if (200..<300).contains(status) {
            guard let access = object["access_token"] as? String, !access.isEmpty,
                  let refresh = object["refresh_token"] as? String, !refresh.isEmpty else { throw ClineError.invalidResponse }
            return .authorized(access: access, refresh: refresh)
        }
        switch object["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw ClineError.denied
        case "expired_token", "invalid_grant": throw ClineError.expired
        default: throw ClineError.http(status)
        }
    }

    public static let clientID = "client_01K3A541FN8TA3EPPHTD2325AR"
    public static let api = "https://api.cline.bot"
    public static let workOS = "https://api.workos.com"

    public static func envelope(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true,
              let payload = object["data"] as? [String: Any] else { throw ClineError.invalidResponse }
        return payload
    }

    public static func usage(_ data: Data) throws -> UsageSnapshot {
        let payload = try envelope(data)
        guard let limits = payload["limits"] as? [[String: Any]] else { throw ClineError.invalidResponse }
        var seen = Set<String>()
        let order = ["five_hour": 0, "weekly": 1, "monthly": 2]
        let quotas = limits.sorted {
            (order[$0["type"] as? String ?? ""] ?? 3) < (order[$1["type"] as? String ?? ""] ?? 3)
        }.compactMap { item -> Quota? in
            guard let type = item["type"] as? String, !type.isEmpty,
                  let used = UsageDecoder.number(item["percentUsed"]), used >= 0,
                  seen.insert(type).inserted else { return nil }
            let label: String
            switch type {
            case "five_hour": label = "5 小时"
            case "weekly": label = "每周"
            case "monthly": label = "每月"
            default: label = type
            }
            return Quota(id: "cline-\(type)", label: label, remaining: 100 - used, limit: 100,
                         monetary: false, resetsAt: UsageDecoder.date(item["resetsAt"]))
        }
        guard !quotas.isEmpty else { throw TelemetryError.unsupported }
        return UsageSnapshot(quotas: quotas, source: "Cline Pass")
    }

    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}
