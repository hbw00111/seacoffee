import Foundation
import SQLite3

public struct UsageRecord: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let app: String
    public let provider: String
    public let model: String
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let cost: Double?
    public let status: Int?
    public var tokens: Double { input + output + cacheRead + cacheWrite }
    public var succeeded: Bool? { status.map { (200..<400).contains($0) } }
    public init(id: String, date: Date, app: String, provider: String, model: String,
                input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cost: Double?, status: Int?) {
        self.id = id; self.date = date; self.app = app; self.provider = provider; self.model = model
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cost = cost; self.status = status
    }
}

public struct UsageTotals: Sendable {
    public var requests = 0
    public var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0
    public var priced = 0, succeeded = 0, withStatus = 0
    public var tokens: Double { input + output + cacheRead + cacheWrite }
    public var hitRate: Double? { input + cacheRead + cacheWrite > 0 ? cacheRead / (input + cacheRead + cacheWrite) : nil }
    public var successRate: Double? { withStatus > 0 ? Double(succeeded) / Double(withStatus) : nil }
    public init(_ rows: [UsageRecord] = []) {
        for row in rows {
            requests += 1; input += row.input; output += row.output; cacheRead += row.cacheRead; cacheWrite += row.cacheWrite
            if let amount = row.cost { priced += 1; cost += amount }
            if let success = row.succeeded { withStatus += 1; if success { succeeded += 1 } }
        }
    }
}

public enum UsageReadError: LocalizedError {
    case missing, unavailable, incompatible
    public var errorDescription: String? {
        switch self {
        case .missing: return "未找到本机 CC Switch 用量记录。额度趋势仍可使用。"
        case .unavailable: return "暂时无法读取用量数据库，请稍后刷新。"
        case .incompatible: return "此版本的 CC Switch 用量格式暂不支持。"
        }
    }
}

/// Reads only numeric usage and display labels; never selects credentials, prompts or error bodies.
public enum UsageAnalyticsReader {
    public struct Result: Sendable {
        public let records: [UsageRecord]
        public let truncated: Bool
    }
    public static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db") }
    // Mirrors CC Switch's documented legacy / total-inclusive / fresh-input semantics.
    public static func freshInput(app: String, input: Double, read: Double, write: Double, semantics: Int) -> Double {
        guard ["codex", "gemini", "grokbuild"].contains(app), semantics != 2 else { return input }
        let cached = semantics == 1 ? read + write : read
        return input >= cached ? input - cached : input
    }
    public static func read(at url: URL = defaultURL, since: Date, until: Date = Date(), limit: Int = 200_000) throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageReadError.missing }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw UsageReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        func columns(_ table: String) throws -> Set<String> {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { throw UsageReadError.incompatible }
            defer { sqlite3_finalize(stmt) }
            var names = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = sqlite3_column_text(stmt, 1) { names.insert(String(cString: value)) }
            }
            return names
        }
        let fields = try columns("proxy_request_logs")
        guard Set(["request_id", "created_at", "app_type", "model", "input_tokens", "output_tokens"]).isSubset(of: fields) else { throw UsageReadError.incompatible }
        func optional(_ field: String, fallback: String = "0") -> String { fields.contains(field) ? "l.\(field)" : fallback }
        let providers = try columns("providers")
        let canJoin = fields.contains("provider_id") && Set(["id", "app_type", "name"]).isSubset(of: providers)
        let provider = canJoin ? "COALESCE(p.name, '未标注服务商')" : "'未标注服务商'"
        let join = canJoin ? "LEFT JOIN providers p ON p.id = l.provider_id AND p.app_type = l.app_type" : ""
        let sql = """
            SELECT l.request_id, l.created_at, l.app_type, \(provider), l.model,
            l.input_tokens, l.output_tokens, \(optional("cache_read_tokens")), \(optional("cache_creation_tokens")),
            \(optional("total_cost_usd", fallback: "NULL")), \(optional("status_code", fallback: "NULL")), \(optional("input_token_semantics"))
            FROM proxy_request_logs l \(join)
            WHERE l.created_at >= ?1 AND l.created_at <= ?2 ORDER BY l.created_at DESC, l.request_id LIMIT ?3
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw UsageReadError.incompatible }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, Int64(limit + 1))
        func text(_ index: Int32) -> String { sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "" }
        func number(_ index: Int32) -> Double { let n = sqlite3_column_double(stmt, index); return n.isFinite ? max(0, n) : 0 }
        var rows: [UsageRecord] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw UsageReadError.unavailable }
            if rows.count == limit { return Result(records: rows, truncated: true) }
            let app = text(2), read = number(7), write = number(8)
            let rawCost = Double(text(9))
            let cost = rawCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let status = sqlite3_column_type(stmt, 10) == SQLITE_NULL || sqlite3_column_int(stmt, 10) == 0 ? nil : Int(sqlite3_column_int(stmt, 10))
            rows.append(UsageRecord(id: text(0), date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                app: app, provider: text(3), model: text(4).isEmpty ? "未知模型" : text(4),
                input: freshInput(app: app, input: number(5), read: read, write: write, semantics: Int(sqlite3_column_int(stmt, 11))),
                output: number(6), cacheRead: read, cacheWrite: write, cost: cost, status: status))
        }
        return Result(records: rows, truncated: false)
    }
}

/// Prepared off the UI thread; rendering never scans the source records.
public struct UsageReport: Sendable {
    public struct Bucket: Identifiable, Sendable {
        public let date: Date
        public let totals: UsageTotals
        public var id: Date { date }
    }
    public let rows: [UsageRecord]
    public let totals: UsageTotals
    public let buckets: [Bucket]
    public let models: [(String, UsageTotals)]
    public init(records: [UsageRecord] = [], since: Date = Date(), until: Date = Date(), hourly: Bool = false,
                app: String? = nil, provider: String? = nil, model: String? = nil) {
        rows = records.filter { $0.date >= since && $0.date <= until && (app == nil || $0.app == app)
            && (provider == nil || $0.provider == provider) && (model == nil || $0.model == model) }
        totals = UsageTotals(rows)
        models = Dictionary(grouping: rows, by: \.model).map { ($0.key, UsageTotals($0.value)) }
            .sorted { $0.1.tokens == $1.1.tokens ? $0.0 < $1.0 : $0.1.tokens > $1.1.tokens }
        let calendar = Calendar.current
        let component: Calendar.Component = hourly ? .hour : .day
        let groups = Dictionary(grouping: rows) { calendar.dateInterval(of: component, for: $0.date)!.start }
        var date = calendar.dateInterval(of: component, for: since)!.start
        var result: [Bucket] = []
        while date <= until {
            result.append(Bucket(date: date, totals: UsageTotals(groups[date] ?? [])))
            date = calendar.date(byAdding: component, value: 1, to: date)!
        }
        buckets = result
    }
}
