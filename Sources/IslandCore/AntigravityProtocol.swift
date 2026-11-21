import Foundation

public enum AntigravityError: LocalizedError, Equatable {
    case notRunning, usageUnavailable, invalidResponse
    /// The status and, when the server gave one, its own reason.
    case http(Int, String?)
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Antigravity 应用和 agy acp 都没有运行，保留上次额度；打开 Antigravity 后自动恢复。"
        case .usageUnavailable: return "Antigravity 没有返回可识别的额度。"
        case .invalidResponse: return "Antigravity 返回了无法识别的数据。"
        case .http(let code, let reason): return "Antigravity 请求失败（HTTP \(code)\(reason.map { "：\($0)" } ?? "")）。"
        }
    }
}

/// The running Antigravity desktop app's local server, as the app describes it in
/// `~/.gemini/antigravity/daemon/hub_<port>.json`. Sea Coffee asks that server for the quota the
/// way CodexBar does, so it needs no login of its own and never talks to Google.
public struct AntigravityHub: Sendable, Equatable {
    public let pid: Int32
    public let httpsPort: Int?
    public let httpPort: Int?
    /// Empty for an `agy acp` server, which asks for none.
    public let csrfToken: String
    public init(pid: Int32, httpsPort: Int?, httpPort: Int?, csrfToken: String) {
        self.pid = pid; self.httpsPort = httpsPort; self.httpPort = httpPort; self.csrfToken = csrfToken
    }

    public static func parse(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = UsageDecoder.number(root["pid"]), pid > 0,
              let token = root["csrfToken"] as? String, !token.isEmpty else { return nil }
        func port(_ key: String) -> Int? { UsageDecoder.number(root[key]).map { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil } }
        let hub = Self(pid: Int32(pid), httpsPort: port("httpsPort"), httpPort: port("httpPort"), csrfToken: token)
        return hub.endpoints.isEmpty ? nil : hub
    }

    /// `agy acp` (the server editors such as T3 Code start) writes no discovery file, but its log
    /// `antigravity-acp/log/acp-server-<time>-<pid>.log` opens with the ports it listens on
    /// (`Language server listening on random port at 56294 for HTTPS (gRPC)`). Unlike the
    /// interactive `agy`, this server answers without a CSRF token.
    public static func acpServer(log: Data, pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        let text = String(decoding: log.prefix(64 * 1024), as: UTF8.self)
        var https: Int?, http: Int?
        for line in text.split(separator: "\n") where line.contains("listening on random port at ") {
            guard let range = line.range(of: "listening on random port at ") else { continue }
            let rest = line[range.upperBound...]
            guard let port = Int(rest.prefix { $0.isNumber }), (1...65535).contains(port) else { continue }
            if rest.contains("for HTTPS") { https = https ?? port } else if rest.contains("for HTTP") { http = http ?? port }
        }
        let hub = Self(pid: pid, httpsPort: https, httpPort: http, csrfToken: "")
        return hub.endpoints.isEmpty ? nil : hub
    }

    /// `acp-server-20261121_143851-45082.log` → 45082.
    public static func acpLogPID(_ name: String) -> Int32? {
        guard name.hasPrefix("acp-server-"), name.hasSuffix(".log"),
              let tail = name.dropLast(4).split(separator: "-").last, let pid = Int32(tail), pid > 0 else { return nil }
        return pid
    }

    /// Loopback only, HTTPS first.
    public var endpoints: [URL] {
        [httpsPort.map { "https://127.0.0.1:\($0)" }, httpPort.map { "http://127.0.0.1:\($0)" }]
            .compactMap { $0 }.compactMap { URL(string: $0 + "/exa.language_server_pb.LanguageServerService/") }
    }
}

public enum AntigravityProtocol {
    public static let csrfHeader = "X-Codeium-Csrf-Token"
    public static let summaryMethod = "RetrieveUserQuotaSummary"
    public static let summaryBody = Data(#"{"forceRefresh":true}"#.utf8)
    public static let statusMethod = "GetUserStatus"
    public static let statusBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8)

    public static func validate(status: Int, body: Data = Data()) throws {
        guard !(200..<300).contains(status) else { return }
        // Connect errors are `{"code": "...", "message": "..."}`.
        let error = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let reason = [error?["code"] as? String, error?["message"] as? String].compactMap { $0 }.joined(separator: " · ")
        throw AntigravityError.http(status, reason.isEmpty ? nil : String(reason.prefix(160)))
    }

    /// `RetrieveUserQuotaSummary`: model groups (Gemini; Claude and GPT), each with a five-hour and a
    /// weekly bucket. Only Gemini is kept. Order: the tightest five-hour bucket (the notch shows it), then the tightest
    /// weekly one (the expanded panel's second row), then the rest by window and remaining. A
    /// bucket without `remainingFraction` is unknown and left out, never shown as empty.
    public static func usage(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = (root["response"] as? [String: Any])?["groups"] as? [[String: Any]] else { throw AntigravityError.invalidResponse }
        var quotas: [(rank: Int, quota: Quota)] = []
        // Only the Gemini group is shown; the Claude/GPT group is left out by choice.
        for group in groups where (group["displayName"] as? String ?? "").lowercased().hasPrefix("gemini") {
            let family = family(group["displayName"] as? String ?? "")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] where bucket["disabled"] as? Bool != true {
                guard let id = bucket["bucketId"] as? String, !id.isEmpty,
                      let fraction = UsageDecoder.number(bucket["remainingFraction"]) else { continue }
                let window = window(bucket["window"] as? String) ?? bucket["displayName"] as? String ?? id
                let rank = ["5h": 0, "weekly": 1][(bucket["window"] as? String)?.lowercased() ?? ""] ?? 2
                quotas.append((rank, Quota(id: "antigravity-\(id)", label: [family, window].filter { !$0.isEmpty }.joined(separator: " "),
                                    remaining: min(1, max(0, fraction)) * 100, limit: 100, monetary: false,
                                    resetsAt: UsageDecoder.date(bucket["resetTime"]))))
            }
        }
        guard !quotas.isEmpty else { throw AntigravityError.usageUnavailable }
        var ordered = quotas.sorted {
            ($0.rank, $0.quota.fraction, $0.quota.id) < ($1.rank, $1.quota.fraction, $1.quota.id)
        }
        if let weekly = ordered.firstIndex(where: { $0.rank == 1 }), weekly > 1 {
            ordered.insert(ordered.remove(at: weekly), at: 1)
        }
        return UsageSnapshot(quotas: ordered.map(\.quota))
    }

    /// `GetUserStatus`: the signed-in account and its plan, shown in Settings only.
    public static func identity(_ data: Data) -> (email: String?, plan: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return (nil, nil) }
        func text(_ value: Any?) -> String? {
            (value as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        return (text(status["email"]), text((status["userTier"] as? [String: Any])?["name"]) ?? text(planInfo?["planName"]))
    }

    /// `Gemini Models` → `Gemini`; `Claude and GPT models` → `Claude/GPT`.
    static func family(_ displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(" models") { name = String(name.dropLast(7)) }
        return name.replacingOccurrences(of: " and ", with: "/")
    }

    static func window(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "5h": return "5 小时"
        case "weekly": return "每周"
        case "daily": return "每日"
        case "monthly": return "每月"
        default: return nil
        }
    }
}
