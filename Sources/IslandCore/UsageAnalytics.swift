import Foundation
import SQLite3

// Usage statistics read from CC Switch's local database and computed the way CC Switch 4.0
// computes them (usage_stats.rs, calculator.rs, components/usage). Only numbers and labels are
// selected; prompts, error bodies and credentials are never read.

public enum UsageCostState: Sendable, Equatable {
    /// Stored by CC Switch.
    case recorded
    /// Stored as $0 but priced from model_pricing, as CC Switch's own backfill would do.
    case estimated
    /// A successful request with tokens and no price: shown as "未定价".
    case unpriced
    /// Legitimately $0: failed request, no tokens, or a zero multiplier.
    case free
}

public struct UsageLog: Identifiable, Sendable {
    public let id: String
    public let date: Date
    /// `claude-desktop` folded into `claude`, as every CC Switch dashboard query does.
    public let app: String
    public let rawApp: String
    public let providerID: String
    public let provider: String
    public let model: String
    public let requestModel: String?
    public let pricingModel: String?
    public let status: Int
    public let source: String
    public let rawInput: Double
    /// Fresh input by `input_token_semantics` (sql_helpers::fresh_input_sql).
    public let freshInput: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let latencyMs: Double
    public let firstTokenMs: Double?
    public let cost: Double
    public let costParts: CostBreakdown?
    public let multiplier: Decimal
    public let costState: UsageCostState

    /// Statistics group a row by its pricing model when there is one.
    public var groupModel: String { pricingModel.flatMap { $0.isEmpty ? nil : $0 } ?? model }
    public var succeeded: Bool { (200..<300).contains(status) }
    public var realTokens: Double { freshInput + output + cacheRead + cacheWrite }
    public var isProxy: Bool { source == "proxy" }
    /// The request log's "新增输入": cache-inclusive apps subtract cache reads only, ignoring semantics.
    public var displayInput: Double {
        UsageStats.cacheInclusive.contains(rawApp) && rawInput >= cacheRead ? rawInput - cacheRead : rawInput
    }
    var generationMs: Double? { firstTokenMs.flatMap { latencyMs - $0 > 0 ? latencyMs - $0 : nil } }
    var speedEligible: Bool { generationMs.map { output >= 100 && $0 >= 100 } ?? false }
    var estimateEligible: Bool { firstTokenMs == nil && !isProxy && output >= 200 && latencyMs >= 1000 }
    /// Output tokens per second of generation; nil when CC Switch shows "—".
    public var speed: Double? { speedEligible ? generationMs.map { output / ($0 / 1000) } : nil }
    /// Session-log rows without first-token timing, shown with "≈".
    public var estimatedSpeed: Double? { speed == nil && estimateEligible ? output / (latencyMs / 1000) : nil }
}

/// One `usage_daily_rollups` row: detail rows older than CC Switch's 30-day retention.
public struct UsageRollup: Sendable {
    public let day: String
    public let app: String
    public let providerID: String
    public let provider: String
    public let groupModel: String
    public let requests: Int
    public let successes: Int
    public let freshInput: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let cost: Double
}

public struct UsageDataset: Sendable {
    public var logs: [UsageLog]
    public var rollups: [UsageRollup]
    public init(logs: [UsageLog] = [], rollups: [UsageRollup] = []) { self.logs = logs; self.rollups = rollups }
    public var apps: [String] { Array(Set(logs.map(\.app) + rollups.map(\.app))).sorted() }
    public var providers: [String] { Array(Set(logs.map(\.provider) + rollups.map(\.provider))).sorted() }
    public var models: [String] { Array(Set(logs.map(\.groupModel) + rollups.map(\.groupModel))).sorted() }
    public var firstDay: String? { (logs.map { UsageStats.day($0.date) } + rollups.map(\.day)).min() }
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

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today = "当天", day = "近 24 小时", week = "近 7 天", twoWeeks = "近 14 天", month = "近 30 天", all = "全部"
    public var id: String { rawValue }
    /// src/lib/usageRange.ts: N-day ranges start at the local midnight of now − (N−1) days.
    public func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        case .twoWeeks: return calendar.startOfDay(for: now.addingTimeInterval(-13 * 86_400))
        case .month: return calendar.startOfDay(for: now.addingTimeInterval(-29 * 86_400))
        case .all: return Date(timeIntervalSince1970: 0)
        }
    }
}

public struct UsageFilter: Sendable, Equatable {
    public var app: String?, provider: String?, model: String?
    public init(app: String? = nil, provider: String? = nil, model: String? = nil) { self.app = app; self.provider = provider; self.model = model }
    func matches(app rowApp: String, provider rowProvider: String, model rowModel: String) -> Bool {
        (app == nil || app == rowApp) && (provider == nil || provider == rowProvider) && (model == nil || model == rowModel)
    }
}

public struct UsageTotals: Sendable, Equatable {
    public var requests = 0, successes = 0
    public var freshInput = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0
    /// Sums for speed: exact (output, generation ms) and estimated (output, latency ms).
    public var speedOutput = 0.0, speedMs = 0.0, estimateOutput = 0.0, estimateMs = 0.0
    public init() {}
    /// 真实消耗 Tokens.
    public var realTokens: Double { freshInput + output + cacheRead + cacheWrite }
    public var hitRate: Double { let all = freshInput + cacheWrite + cacheRead; return all > 0 ? cacheRead / all : 0 }
    public var successRate: Double? { requests > 0 ? Double(successes) / Double(requests) : nil }
    public var averageCost: Double? { requests > 0 ? cost / Double(requests) : nil }
    /// Ratio of sums over eligible rows, falling back to the estimate; rollups add nothing.
    public var speed: (value: Double, estimated: Bool)? {
        if speedOutput > 0, speedMs > 0 { return (speedOutput / (speedMs / 1000), false) }
        if estimateOutput > 0, estimateMs > 0 { return (estimateOutput / (estimateMs / 1000), true) }
        return nil
    }
    mutating func add(_ log: UsageLog) {
        requests += 1; if log.succeeded { successes += 1 }
        freshInput += log.freshInput; output += log.output; cacheRead += log.cacheRead; cacheWrite += log.cacheWrite; cost += log.cost
        if log.speedEligible, let ms = log.generationMs { speedOutput += log.output; speedMs += ms }
        if log.estimateEligible { estimateOutput += log.output; estimateMs += log.latencyMs }
    }
    mutating func add(_ rollup: UsageRollup) {
        requests += rollup.requests; successes += rollup.successes
        freshInput += rollup.freshInput; output += rollup.output; cacheRead += rollup.cacheRead; cacheWrite += rollup.cacheWrite; cost += rollup.cost
    }
}

public struct UsageGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let app: String?
    public let totals: UsageTotals
}

public struct UsageBucket: Identifiable, Sendable {
    public let start: Date
    public let totals: UsageTotals
    public var id: Date { start }
}

/// Everything one range and filter shows, prepared off the main thread.
public struct UsageStatsReport: Sendable {
    public let start: Date
    public let end: Date
    public let hourly: Bool
    public let totals: UsageTotals
    public let buckets: [UsageBucket]
    /// Sorted by request count, as CC Switch's tables are.
    public let providers: [UsageGroup]
    public let models: [UsageGroup]
    /// Detail rows only, newest first.
    public let logs: [UsageLog]

    public init(_ data: UsageDataset = UsageDataset(), range: UsageRange = .week, filter: UsageFilter = UsageFilter(),
                now: Date = Date(), calendar: Calendar = .current) {
        let start = range.start(now: now, calendar: calendar)
        self.start = start; end = now
        let logs = data.logs.filter { $0.date >= start && $0.date <= now && filter.matches(app: $0.app, provider: $0.provider, model: $0.groupModel) }
        let days = UsageStats.rollupDays(start: start, end: now, calendar: calendar)
        let rollups = days.map { days in data.rollups.filter {
            $0.day >= days.lowerBound && $0.day <= days.upperBound && filter.matches(app: $0.app, provider: $0.provider, model: $0.groupModel)
        } } ?? []

        var totals = UsageTotals()
        logs.forEach { totals.add($0) }; rollups.forEach { totals.add($0) }
        self.totals = totals
        self.logs = logs.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }

        func groups(_ key: (String, String) -> String, name: @escaping (String) -> String,
                    logKey: (UsageLog) -> (String, String), rollupKey: (UsageRollup) -> (String, String)) -> [UsageGroup] {
            var sums: [String: (String, String, UsageTotals)] = [:]
            for log in logs { let (a, b) = logKey(log); sums[key(a, b), default: (a, b, UsageTotals())].2.add(log) }
            for rollup in rollups { let (a, b) = rollupKey(rollup); sums[key(a, b), default: (a, b, UsageTotals())].2.add(rollup) }
            return sums.map { UsageGroup(id: $0.key, name: name($0.value.0), app: $0.value.1.isEmpty ? nil : $0.value.1, totals: $0.value.2) }
                .sorted { $0.totals.requests == $1.totals.requests ? $0.name < $1.name : $0.totals.requests > $1.totals.requests }
        }
        var names: [String: String] = [:]
        logs.forEach { names[$0.providerID] = $0.provider }; rollups.forEach { names[$0.providerID] = names[$0.providerID] ?? $0.provider }
        providers = groups({ "\($0)|\($1)" }, name: { names[$0] ?? $0 }, logKey: { ($0.providerID, $0.app) }, rollupKey: { ($0.providerID, $0.app) })
        models = groups({ a, _ in a }, name: { $0 }, logKey: { ($0.groupModel, "") }, rollupKey: { ($0.groupModel, "") })

        // ≤ 24 h: hourly buckets measured from the range start; otherwise local days.
        hourly = now.timeIntervalSince(start) <= 86_400
        if hourly {
            let count = max(1, Int((now.timeIntervalSince(start) / 3600).rounded(.up)))
            var sums = Array(repeating: UsageTotals(), count: count)
            for log in logs { sums[min(count - 1, max(0, Int(log.date.timeIntervalSince(start) / 3600)))].add(log) }
            buckets = sums.enumerated().map { UsageBucket(start: start.addingTimeInterval(Double($0.offset) * 3600), totals: $0.element) }
        } else {
            var sums: [String: UsageTotals] = [:]
            logs.forEach { sums[UsageStats.day($0.date, calendar: calendar), default: UsageTotals()].add($0) }
            rollups.forEach { sums[$0.day, default: UsageTotals()].add($0) }
            // "全部" starts at the first recorded day rather than 1970.
            let first = range == .all ? (sums.keys.min().flatMap { UsageStats.date($0, calendar: calendar) } ?? calendar.startOfDay(for: now)) : calendar.startOfDay(for: start)
            var result: [UsageBucket] = []
            var day = first
            while day <= now {
                result.append(UsageBucket(start: day, totals: sums[UsageStats.day(day, calendar: calendar)] ?? UsageTotals()))
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            buckets = result
        }
    }

    public func logs(status: Int?) -> [UsageLog] { status.map { code in logs.filter { $0.status == code } } ?? logs }
}

public enum UsageHeatmapMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens = "Tokens", requests = "请求", cost = "成本"
    public var id: String { rawValue }
}

/// UsageHeatmap.tsx: Monday-first weeks, 53 columns per span, five levels from the quartiles
/// of non-zero past days.
public struct UsageHeatmap: Sendable {
    public struct Day: Identifiable, Sendable {
        public let date: Date
        public let value: Double
        public let level: Int
        public let future: Bool
        public var id: Date { date }
    }
    /// Columns of seven days, oldest first.
    public let weeks: [[Day]]

    public init(_ data: UsageDataset, metric: UsageHeatmapMetric, filter: UsageFilter = UsageFilter(),
                now: Date = Date(), calendar: Calendar = .current) {
        var values: [String: Double] = [:]
        func value(_ totals: UsageTotals) -> Double {
            switch metric {
            case .tokens: return totals.realTokens
            case .requests: return Double(totals.requests)
            case .cost: return totals.cost
            }
        }
        var sums: [String: UsageTotals] = [:]
        for log in data.logs where log.date <= now && filter.matches(app: log.app, provider: log.provider, model: log.groupModel) {
            sums[UsageStats.day(log.date, calendar: calendar), default: UsageTotals()].add(log)
        }
        if let days = UsageStats.rollupDays(start: Date(timeIntervalSince1970: 0), end: now, calendar: calendar) {
            for rollup in data.rollups where rollup.day <= days.upperBound && filter.matches(app: rollup.app, provider: rollup.provider, model: rollup.groupModel) {
                sums[rollup.day, default: UsageTotals()].add(rollup)
            }
        }
        for (day, totals) in sums { values[day] = value(totals) }

        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7 // Monday = 0
        let thisMonday = calendar.date(byAdding: .day, value: -weekday, to: today)!
        var firstMonday = calendar.date(byAdding: .day, value: -52 * 7, to: thisMonday)!
        if let first = data.firstDay.flatMap({ UsageStats.date($0, calendar: calendar) }) {
            while first < firstMonday { firstMonday = calendar.date(byAdding: .day, value: -53 * 7, to: firstMonday)! }
        }
        let past = values.filter { $0.key <= UsageStats.day(today, calendar: calendar) }.values.filter { $0 > 0 }.sorted()
        let thresholds = [0.25, 0.5, 0.75].map { q in past.isEmpty ? 0 : past[min(past.count - 1, Int(Double(past.count) * q))] }
        var weeks: [[Day]] = []
        var monday = firstMonday
        while monday <= thisMonday {
            weeks.append((0..<7).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: monday)!
                let amount = values[UsageStats.day(date, calendar: calendar)] ?? 0
                let level = amount <= 0 ? 0 : amount <= thresholds[0] ? 1 : amount <= thresholds[1] ? 2 : amount <= thresholds[2] ? 3 : 4
                return Day(date: date, value: amount, level: level, future: date > today)
            })
            monday = calendar.date(byAdding: .day, value: 7, to: monday)!
        }
        self.weeks = weeks
    }
}

public enum UsageStats {
    static let cacheInclusive: Set<String> = ["codex", "gemini", "grokbuild"]
    static let sessionSources: Set<String> = ["session_log", "codex_session", "gemini_session", "opencode_session"]
    static let sessionProviders = ["_session": "Claude (Session)", "_codex_session": "Codex (Session)",
                                   "_gemini_session": "Gemini (Session)", "_opencode_session": "OpenCode (Session)",
                                   "_grok_session": "Grok Build (Session)", "_mcode_session": "MiniMax Code (Session)",
                                   "_pi_session": "Pi (Session)"]
    public static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db") }

    /// sql_helpers::fresh_input_sql.
    public static func freshInput(app: String, input: Double, read: Double, write: Double, semantics: Int) -> Double {
        guard cacheInclusive.contains(app), semantics != 2 else { return input }
        if semantics == 1, input >= read + write { return input - read - write }
        if semantics == 0, input >= read { return input - read }
        return input
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    /// compute_rollup_date_bounds: only local days the range covers completely.
    static func rollupDays(start: Date, end: Date, calendar: Calendar = .current) -> ClosedRange<String>? {
        let startDay = calendar.startOfDay(for: start) == start ? start : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        let c = calendar.dateComponents([.hour, .minute], from: end)
        let endDay = c.hour == 23 && c.minute == 59 ? end : calendar.date(byAdding: .day, value: -1, to: end)!
        let (low, high) = (day(startDay, calendar: calendar), day(endDay, calendar: calendar))
        return low <= high ? low...high : nil
    }

    /// Reads every detail row (CC Switch keeps about 30 days), all rollups and the price table.
    public static func read(at url: URL = defaultURL) throws -> UsageDataset {
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageReadError.missing }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw UsageReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        func columns(_ table: String) -> Set<String> {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var names = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW { if let value = sqlite3_column_text(stmt, 1) { names.insert(String(cString: value)) } }
            return names
        }
        func query(_ sql: String, _ row: (OpaquePointer) throws -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw UsageReadError.incompatible }
            defer { sqlite3_finalize(stmt) }
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw UsageReadError.unavailable }
                try row(stmt)
            }
        }
        func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func optionalText(_ s: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : text(s, i) }
        func number(_ s: OpaquePointer, _ i: Int32) -> Double { let n = sqlite3_column_double(s, i); return n.isFinite ? max(0, n) : 0 }
        func decimal(_ string: String) -> Decimal? { Decimal(string: string.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) }

        let logFields = columns("proxy_request_logs")
        let required: Set<String> = ["request_id", "provider_id", "app_type", "model", "input_tokens", "output_tokens", "cache_read_tokens",
                                     "cache_creation_tokens", "total_cost_usd", "latency_ms", "status_code", "created_at"]
        guard required.isSubset(of: logFields) else { throw UsageReadError.incompatible }
        func optional(_ field: String, _ fallback: String) -> String { logFields.contains(field) ? field : fallback }

        var providerNames: [String: String] = [:]
        if Set(["id", "app_type", "name"]).isSubset(of: columns("providers")) {
            try query("SELECT id, app_type, name FROM providers") { providerNames["\(text($0, 1))|\(text($0, 0))"] = text($0, 2) }
        }
        func providerName(_ id: String, app: String) -> String {
            providerNames["\(app)|\(id)"] ?? (app == "claude" ? providerNames["claude-desktop|\(id)"] : nil) ?? sessionProviders[id] ?? id
        }
        var prices: [String: ModelPrice] = [:]
        if Set(["model_id", "input_cost_per_million", "output_cost_per_million"]).isSubset(of: columns("model_pricing")) {
            let priceFields = columns("model_pricing")
            let read = priceFields.contains("cache_read_cost_per_million") ? "cache_read_cost_per_million" : "'0'"
            let write = priceFields.contains("cache_creation_cost_per_million") ? "cache_creation_cost_per_million" : "'0'"
            try query("SELECT model_id, input_cost_per_million, output_cost_per_million, \(read), \(write) FROM model_pricing") {
                let id = text($0, 0)
                guard let input = decimal(text($0, 1)), let output = decimal(text($0, 2)) else { return }
                prices[id] = ModelPrice(modelID: id, input: input, output: output,
                                        cacheRead: decimal(text($0, 3)) ?? 0, cacheWrite: decimal(text($0, 4)) ?? 0)
            }
        }

        let sql = """
            SELECT request_id, created_at, app_type, provider_id, model, \(optional("request_model", "NULL")), \(optional("pricing_model", "NULL")),
            status_code, COALESCE(\(optional("data_source", "NULL")), 'proxy'), input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
            latency_ms, \(optional("first_token_ms", "NULL")), total_cost_usd, \(optional("cost_multiplier", "'1'")), \(optional("input_token_semantics", "0")),
            \(optional("input_cost_usd", "'0'")), \(optional("output_cost_usd", "'0'")), \(optional("cache_read_cost_usd", "'0'")), \(optional("cache_creation_cost_usd", "'0'"))
            FROM proxy_request_logs
            """
        var logs: [UsageLog] = []
        try query(sql) { s in
            let rawApp = text(s, 2), providerID = text(s, 3), model = text(s, 4)
            let requestModel = optionalText(s, 5), pricingModel = optionalText(s, 6)
            let status = Int(sqlite3_column_int(s, 7))
            let input = number(s, 9), output = number(s, 10), read = number(s, 11), write = number(s, 12)
            let semantics = Int(sqlite3_column_int(s, 17))
            let multiplierText = text(s, 16)
            let multiplier = decimal(multiplierText) ?? 1
            let tokens = input + output + read + write > 0
            var total = decimal(text(s, 15)) ?? 0
            var parts: CostBreakdown? = total > 0 ? CostBreakdown(input: decimal(text(s, 18)) ?? 0, output: decimal(text(s, 19)) ?? 0,
                                                                  cacheRead: decimal(text(s, 20)) ?? 0, cacheWrite: decimal(text(s, 21)) ?? 0, total: total) : nil
            var state: UsageCostState = total > 0 ? .recorded : .free
            // CC Switch re-prices $0 rows with tokens when a price exists (maybe_backfill_log_costs).
            if total <= 0, tokens, let key = ModelPricing.pricingKey(pricingModel: pricingModel, model: model, requestModel: requestModel),
               let price = ModelPricing.find(key, in: prices) {
                let breakdown = ModelPricing.cost(app: rawApp, semantics: semantics, input: Decimal(input), output: Decimal(output),
                                                  cacheRead: Decimal(read), cacheWrite: Decimal(write), price: price, multiplier: multiplier)
                if breakdown.total > 0 { total = breakdown.total; parts = breakdown; state = .estimated }
            }
            // isUnpricedUsage: a NaN multiplier still counts as not zero.
            if state == .free, (200..<300).contains(status), tokens, decimal(multiplierText).map({ $0 != 0 }) ?? true { state = .unpriced }
            let app = rawApp == "claude-desktop" ? "claude" : rawApp
            logs.append(UsageLog(id: text(s, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), app: app, rawApp: rawApp,
                                 providerID: providerID, provider: providerName(providerID, app: rawApp), model: model.isEmpty ? "unknown" : model,
                                 requestModel: requestModel, pricingModel: pricingModel, status: status, source: text(s, 8),
                                 rawInput: input, freshInput: freshInput(app: rawApp, input: input, read: read, write: write, semantics: semantics),
                                 output: output, cacheRead: read, cacheWrite: write, latencyMs: number(s, 13),
                                 firstTokenMs: sqlite3_column_type(s, 14) == SQLITE_NULL ? nil : number(s, 14),
                                 cost: NSDecimalNumber(decimal: total).doubleValue, costParts: parts, multiplier: multiplier, costState: state))
        }

        var rollups: [UsageRollup] = []
        let rollupFields = columns("usage_daily_rollups")
        if Set(["date", "app_type", "provider_id", "model", "request_count", "input_tokens", "output_tokens", "total_cost_usd"]).isSubset(of: rollupFields) {
            func field(_ name: String, _ fallback: String) -> String { rollupFields.contains(name) ? name : fallback }
            try query("""
                SELECT date, app_type, provider_id, COALESCE(NULLIF(\(field("pricing_model", "''")), ''), model), request_count, \(field("success_count", "0")),
                input_tokens, output_tokens, \(field("cache_read_tokens", "0")), \(field("cache_creation_tokens", "0")), total_cost_usd
                FROM usage_daily_rollups
                """) { s in
                let rawApp = text(s, 1), providerID = text(s, 2)
                rollups.append(UsageRollup(day: text(s, 0), app: rawApp == "claude-desktop" ? "claude" : rawApp, providerID: providerID,
                                           provider: providerName(providerID, app: rawApp), groupModel: text(s, 3),
                                           requests: Int(sqlite3_column_int64(s, 4)), successes: Int(sqlite3_column_int64(s, 5)),
                                           freshInput: number(s, 6), output: number(s, 7), cacheRead: number(s, 8), cacheWrite: number(s, 9),
                                           cost: Double(text(s, 10)).map { $0.isFinite ? max(0, $0) : 0 } ?? 0))
            }
        }
        return UsageDataset(logs: deduplicated(logs), rollups: rollups)
    }

    /// effective_usage_log_filter: a session-log row is dropped when a successful proxy row with the
    /// same tokens and model was recorded within ±600 s.
    static func deduplicated(_ logs: [UsageLog]) -> [UsageLog] {
        struct Key: Hashable { let input, output, read: Double }
        var proxies: [Key: [UsageLog]] = [:]
        for log in logs where log.isProxy && log.succeeded {
            proxies[Key(input: log.rawInput, output: log.output, read: log.cacheRead), default: []].append(log)
        }
        return logs.filter { row in
            guard sessionSources.contains(row.source) else { return true }
            let lenientWrite = row.cacheWrite == 0 && row.source != "session_log"
            let apps: Set<String> = row.rawApp == "claude" ? ["claude", "claude-desktop"] : [row.rawApp]
            return !(proxies[Key(input: row.rawInput, output: row.output, read: row.cacheRead)] ?? []).contains { proxy in
                apps.contains(proxy.rawApp) && (proxy.cacheWrite == row.cacheWrite || lenientWrite)
                    && abs(proxy.date.timeIntervalSince(row.date)) <= 600
                    && (proxy.model.lowercased() == row.model.lowercased() || proxy.model == "unknown" || row.model == "unknown")
            }
        }
    }
}
