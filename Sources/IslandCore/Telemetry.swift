import Foundation

public struct Quota: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let remaining: Double
    public let limit: Double
    public let monetary: Bool
    public let resetsAt: Date?
    public var fraction: Double { min(1, max(0, remaining / limit)) }
    public var percent: Int { Int((fraction * 100).rounded()) }

    public init(id: String, label: String, remaining: Double, limit: Double, monetary: Bool = true, resetsAt: Date? = nil) {
        self.id = id; self.label = label; self.remaining = remaining
        self.limit = limit; self.monetary = monetary; self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let quotas: [Quota]
    public let balance: Double?
    public let source: String
    public let fetchedAt: Date
    public init(quotas: [Quota], balance: Double? = nil, source: String, fetchedAt: Date = Date()) {
        self.quotas = quotas; self.balance = balance; self.source = source; self.fetchedAt = fetchedAt
    }
}

public enum TelemetryError: LocalizedError {
    case invalidURL, invalidBaseline, unsupported, invalidKey, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 站点地址。"
        case .invalidBaseline: return "满格基准必须是大于 0 的有限数值。"
        case .unsupported: return "接口未返回可识别的余额或配额；此站点版本可能不支持。"
        case .invalidKey: return "API Key 无效、已过期或没有查询权限。"
        case .http(let code): return "查询失败（HTTP \(code)），请稍后重试。"
        }
    }
}

public enum UsageDecoder {
    public static func endpoint(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw TelemetryError.invalidURL
        }
        // Site settings accept both the dashboard URL and an OpenAI-compatible base URL.
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if ["redeem", "dashboard", "login", "usage"].contains(path) { path = "" }
        if path.hasSuffix("v1/usage") { path = String(path.dropLast(8)) }
        if path.hasSuffix("v1") { path = String(path.dropLast(2)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (path.isEmpty ? "" : "/" + path) + "/v1/usage"
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw TelemetryError.invalidURL }
        return url
    }

    public static func sub2API(_ data: Data, baseline: Double) throws -> UsageSnapshot {
        guard baseline.isFinite, baseline > 0 else { throw TelemetryError.invalidBaseline }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TelemetryError.unsupported }
        let obj = root["data"] as? [String: Any] ?? root
        if obj["isValid"] as? Bool == false { throw TelemetryError.invalidKey }
        var quotas: [Quota] = []
        if let q = obj["quota"] as? [String: Any], let limit = number(q["limit"]), limit > 0,
           let left = number(q["remaining"]) ?? number(q["used"]).map({ limit - $0 }) {
            quotas.append(Quota(id: "key", label: "Key 总额度", remaining: left, limit: limit))
        }
        if let windows = obj["rate_limits"] as? [[String: Any]] {
            for (index, w) in windows.enumerated() {
                guard let limit = number(w["limit"]), limit > 0,
                      let left = number(w["remaining"]) ?? number(w["used"]).map({ limit - $0 }) else { continue }
                let window = w["window"] as? String ?? "窗口"
                quotas.append(Quota(id: "window-\(index)", label: window, remaining: left, limit: limit, resetsAt: date(w["reset_at"])))
            }
        }
        if let s = obj["subscription"] as? [String: Any] {
            for (key, label) in [("daily", "每日配额"), ("weekly", "每周配额"), ("monthly", "每月配额")] {
                guard let limit = number(s["\(key)_limit_usd"]), limit > 0,
                      let used = number(s["\(key)_usage_usd"]) else { continue }
                quotas.append(Quota(id: key, label: label, remaining: limit - used, limit: limit))
            }
        }
        let balance = number(obj["balance"])
        if let balance, quotas.isEmpty {
            quotas.append(Quota(id: "wallet", label: "余额基准", remaining: balance, limit: baseline))
        }
        guard !quotas.isEmpty else { throw TelemetryError.unsupported }
        return UsageSnapshot(quotas: quotas, balance: balance, source: "Sub2API")
    }

    public static func official(_ object: [String: Any]) throws -> UsageSnapshot {
        let buckets = object["rateLimitsByLimitId"] as? [String: Any]
        let rate = buckets?["codex"] as? [String: Any] ?? object["rateLimits"] as? [String: Any] ?? object
        var quotas: [Quota] = []
        for key in ["primary", "secondary"] {
            guard let w = rate[key] as? [String: Any],
                  let used = number(w["usedPercent"]) ?? number(w["used_percent"]) else { continue }
            let minutes = number(w["windowDurationMins"]) ?? number(w["window_minutes"])
            let label: String
            if let minutes {
                label = minutes >= 1440 ? "\(Int(minutes / 1440)) 天" : "\(Int(minutes / 60)) 小时"
            } else { label = key == "primary" ? "主额度" : "次额度" }
            quotas.append(Quota(id: key, label: label, remaining: 100 - used, limit: 100, monetary: false,
                                resetsAt: date(w["resetsAt"] ?? w["resets_at"])))
        }
        guard !quotas.isEmpty else { throw TelemetryError.unsupported }
        return UsageSnapshot(quotas: quotas, source: "Codex 官方")
    }

    public static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let string = value as? String { result = Double(string) }
        else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    public static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

import CoreFoundation

public enum RunState: String, Sendable { case running, completed, interrupted, failed, unknown }

public struct SessionState: Equatable, Sendable, Identifiable {
    public var id: String
    public var agent: Agent = .codex
    public var project: String = "Codex"
    /// The model that answered most recently, as the agent names it (e.g. `claude-opus-5-5`).
    public var model: String?
    public var state: RunState = .unknown
    public var updatedAt: Date = .distantPast
    public var transitionID: String = ""
    public init(id: String, agent: Agent = .codex) { self.id = id; self.agent = agent; project = agent.name }

    // Only event metadata is retained; prompts and answers are never stored by this app.
    public mutating func consume(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "session_meta" {
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            return
        }
        if object["type"] as? String == "turn_context" {
            if let name = payload["model"] as? String, !name.isEmpty { model = name }
            return
        }
        guard object["type"] as? String == "event_msg", let kind = payload["type"] as? String,
              let time = UsageDecoder.date(object["timestamp"]), time >= updatedAt else { return }
        let next: RunState?
        switch kind {
        case "task_started", "turn_started": next = .running
        case "task_complete", "task_completed", "turn_complete", "turn_completed": next = .completed
        case "turn_aborted", "task_cancelled", "turn_cancelled", "task_stopped": next = .interrupted
        case "task_failed", "turn_failed": next = .failed
        default: next = nil
        }
        if let next {
            state = next
            transitionID = "\(kind):\(payload["turn_id"] as? String ?? ""):\(time.timeIntervalSince1970)"
            updatedAt = time
        } else if state == .running && ["token_count", "agent_message", "agent_reasoning"].contains(kind) {
            updatedAt = time
        }
    }
}
