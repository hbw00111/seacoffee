import Foundation

public enum AntigravityError: LocalizedError, Equatable {
    case missingCredentials, expired, signedOut, usageUnavailable, invalidResponse
    /// The status and, when the server gave one, its own reason.
    case http(Int, String?)
    public var errorDescription: String? {
        switch self {
        case .missingCredentials: return "未找到 Antigravity 登录，请先在终端运行 agy 并登录。"
        case .expired: return "Antigravity 登录已过期，保留上次额度；下次使用 Antigravity 时会自动恢复。"
        case .signedOut: return "Antigravity 拒绝了当前凭据，请运行 agy 重新登录。"
        case .usageUnavailable: return "Antigravity 没有返回任何模型的额度。"
        case .invalidResponse: return "Antigravity 返回了无法识别的数据。"
        case .http(let code, let reason): return "Antigravity 请求失败（HTTP \(code)\(reason.map { "：\($0)" } ?? "")）。"
        }
    }
}

/// Antigravity's login (the `agy` CLI and the desktop app share it), from the login Keychain item
/// `gemini` / `antigravity`. Read-only: Antigravity refreshes the hourly token while it runs.
public struct AntigravityCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let email: String?

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    /// The item is written by go-keyring, which wraps the JSON as `go-keyring-base64:<base64>`.
    public static func parse(_ data: Data) throws -> Self {
        var payload = data
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { throw AntigravityError.invalidResponse }
            payload = decoded
        }
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AntigravityError.invalidResponse }
        guard let token = root["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty else { throw AntigravityError.missingCredentials }
        return Self(accessToken: access, expiresAt: UsageDecoder.date(token["expiry"]), email: root["id_token_email"] as? String)
    }
}

public enum AntigravityProtocol {
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"
    /// The host the `agy` CLI itself talks to.
    public static let loadURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let modelsURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    public static let loadBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.utf8)

    public static func modelsBody(project: String?) -> Data {
        (try? JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])) ?? Data("{}".utf8)
    }

    /// Only 401 means the login was rejected; a 403 names a project or permission problem,
    /// so the server's reason (`error.status` and `error.message`) is shown as it is.
    public static func validate(status: Int, body: Data = Data()) throws {
        switch status {
        case 200..<300: return
        case 401: throw AntigravityError.signedOut
        default:
            let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
            let reason = [error?["status"] as? String, error?["message"] as? String].compactMap { $0 }.joined(separator: " · ")
            throw AntigravityError.http(status, reason.isEmpty ? nil : String(reason.prefix(160)))
        }
    }

    /// `loadCodeAssist`: the Cloud project requests are billed to, and the subscription tier.
    public static func account(_ data: Data) -> (project: String?, plan: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let project = root["cloudaicompanionProject"]
        let id = project as? String ?? (project as? [String: Any])?["id"] as? String
        let plan = [root["paidTier"], root["currentTier"]].lazy
            .compactMap { ($0 as? [String: Any])?["name"] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return (id.flatMap { $0.isEmpty ? nil : $0 }, plan)
    }

    /// `fetchAvailableModels`: every model carries its own `quotaInfo`. Effort variants of one
    /// model (`… (Low)`, `… (High)`) become one row; the tightest rows come first.
    public static func usage(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else { throw AntigravityError.invalidResponse }
        var rows: [String: (fraction: Double, resetsAt: Date?)] = [:]
        for case let model as [String: Any] in models.values {
            // Internal models (tab completion, checkpoints) have no display name.
            guard let name = (model["displayName"] as? String).map(family), !name.isEmpty,
                  let info = model["quotaInfo"] as? [String: Any] else { continue }
            let reset = UsageDecoder.date(info["resetTime"])
            // proto3 JSON omits a zero fraction: a reset time alone means the quota is used up.
            // Neither field means the quota is unknown, and the model is left out.
            guard let fraction = UsageDecoder.number(info["remainingFraction"]) ?? (reset == nil ? nil : 0) else { continue }
            if let known = rows[name], known.fraction <= fraction { continue }
            rows[name] = (min(1, max(0, fraction)), reset)
        }
        guard !rows.isEmpty else { throw AntigravityError.usageUnavailable }
        let quotas = rows.sorted { ($0.value.fraction, $0.key) < ($1.value.fraction, $1.key) }.map {
            Quota(id: "antigravity-\($0.key)", label: $0.key, remaining: $0.value.fraction * 100, limit: 100,
                  monetary: false, resetsAt: $0.value.resetsAt)
        }
        return UsageSnapshot(quotas: quotas)
    }

    /// `Gemini 4 Hydrogen (Medium)` → `Gemini 4 Hydrogen`.
    static func family(_ displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") { name = String(name[..<open]) }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
