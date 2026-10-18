import Foundation
import SQLite3
import IslandCore

final class UsageAnalyticsTests {
    func normalization() {
        expectEqual(UsageStats.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 1), 300)
        expectEqual(UsageStats.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 0), 400)
        expectEqual(UsageStats.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 2), 1000)
        expectEqual(UsageStats.freshInput(app: "codex", input: 500, read: 600, write: 100, semantics: 1), 500)
        expectEqual(UsageStats.freshInput(app: "claude", input: 1000, read: 600, write: 100, semantics: 0), 1000)
        expectEqual(UsageStats.freshInput(app: "grokbuild", input: 1000, read: 600, write: 100, semantics: 1), 300)
        expectEqual(UsageStats.freshInput(app: "pi", input: 100, read: 600, write: 100, semantics: 2), 100)
    }

    /// A CC Switch 4.0 database with one row per case, built in a temp folder.
    private func database(now: Date, calendar: Calendar) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("cc-switch.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw UsageReadError.unavailable }
        defer { sqlite3_close(db) }
        let t = Int(now.timeIntervalSince1970)
        let old = UsageStatsTestDay.string(calendar.date(byAdding: .day, value: -40, to: now)!, calendar)
        let sql = """
            CREATE TABLE providers(id TEXT, app_type TEXT, name TEXT, settings_config TEXT);
            INSERT INTO providers VALUES('p1','codex','Relay','{"apiKey":"never-read"}'), ('p2','claude-desktop','Desk',NULL);
            CREATE TABLE model_pricing(model_id TEXT PRIMARY KEY, display_name TEXT, input_cost_per_million TEXT, output_cost_per_million TEXT,
                cache_read_cost_per_million TEXT, cache_creation_cost_per_million TEXT);
            INSERT INTO model_pricing VALUES('gpt-5','GPT-5','1.25','10','0.125','0');
            CREATE TABLE proxy_request_logs(request_id TEXT PRIMARY KEY, provider_id TEXT, app_type TEXT, model TEXT, request_model TEXT,
                input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
                input_cost_usd TEXT, output_cost_usd TEXT, cache_read_cost_usd TEXT, cache_creation_cost_usd TEXT, total_cost_usd TEXT,
                latency_ms INTEGER, first_token_ms INTEGER, duration_ms INTEGER, status_code INTEGER, error_message TEXT, session_id TEXT,
                provider_type TEXT, is_streaming INTEGER, cost_multiplier TEXT, created_at INTEGER, data_source TEXT, pricing_model TEXT,
                input_token_semantics INTEGER);
            INSERT INTO proxy_request_logs VALUES
              ('recorded','p1','codex','gpt-5',NULL,1000,200,600,100,'0.1','0.2','0.3','0.4','1.25',5000,1000,5000,200,'secret',NULL,NULL,1,'1',\(t - 60),'proxy','gpt-5',1),
              ('estimated','p1','codex','gpt-5-2025-08-07',NULL,1000000,0,0,0,'0','0','0','0','0',800,NULL,NULL,200,NULL,NULL,NULL,0,'2',\(t - 120),'proxy',NULL,2),
              ('unpriced','p2','claude-desktop','mystery',NULL,100,50,0,0,'0','0','0','0','0',900,NULL,NULL,200,NULL,NULL,NULL,0,'1',\(t - 180),'proxy',NULL,2),
              ('failed','p2','claude','mystery',NULL,100,0,0,0,'0','0','0','0','0',300,NULL,NULL,500,'boom',NULL,NULL,0,'1',\(t - 240),'proxy',NULL,2),
              ('zero-multiplier','p2','claude','mystery',NULL,100,50,0,0,'0','0','0','0','0',300,NULL,NULL,200,NULL,NULL,NULL,0,'0',\(t - 300),'proxy',NULL,2),
              ('session-dup','_session','claude','mystery',NULL,100,50,0,0,'0','0','0','0','0',0,NULL,NULL,200,NULL,NULL,NULL,0,'1',\(t - 200),'session_log',NULL,0),
              ('session-own','_session','claude','claude-opus-5-5',NULL,10,400,0,0,'0','0','0','0','0',2000,NULL,NULL,200,NULL,NULL,NULL,0,'1',\(t - 400),'session_log',NULL,0),
              ('yesterday','p1','codex','gpt-5',NULL,10,10,0,0,'0','0','0','0','0.5',100,NULL,NULL,200,NULL,NULL,NULL,0,'1',\(t - 86400),'proxy','gpt-5',2);
            CREATE TABLE usage_daily_rollups(date TEXT, app_type TEXT, provider_id TEXT, model TEXT, request_model TEXT DEFAULT '', pricing_model TEXT DEFAULT '',
                request_count INTEGER, success_count INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                cache_creation_tokens INTEGER, total_cost_usd TEXT, avg_latency_ms INTEGER, input_token_semantics INTEGER);
            INSERT INTO usage_daily_rollups VALUES('\(old)','codex','p1','gpt-5','','',10,9,1000,500,0,0,'2.5',100,2);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageReadError.incompatible }
        return (root, url)
    }

    func statistics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-10-18 15:00 Shanghai: far enough from midnight for the fixed offsets above.
        let now = Date(timeIntervalSince1970: 1_792_306_800)
        let (root, url) = try database(now: now, calendar: calendar)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: url)
        let data = try UsageStats.read(at: url)
        expectEqual(try Data(contentsOf: url), before, "database must remain unchanged")
        let byID = Dictionary(uniqueKeysWithValues: data.logs.map { ($0.id, $0) })

        // Session row duplicating a proxy row is dropped; the unmatched one stays.
        expectNil(byID["session-dup"])
        expectEqual(byID["session-own"]?.provider, "Claude (Session)")
        expectEqual(data.logs.count, 7)

        // Costs: stored, re-priced through model_pricing (×2 multiplier), unpriced, legitimately free.
        expectEqual(byID["recorded"]?.costState, .recorded)
        expectEqual(byID["recorded"]?.cost, 1.25)
        expectEqual(byID["estimated"]?.costState, .estimated)
        expectEqual(byID["estimated"]?.cost, 2.5)
        expectEqual(byID["unpriced"]?.costState, .unpriced)
        expectEqual(byID["failed"]?.costState, .free)
        expectEqual(byID["zero-multiplier"]?.costState, .free)

        // claude-desktop folds into claude; provider names come from the providers table.
        expectEqual(byID["unpriced"]?.app, "claude")
        expectEqual(byID["unpriced"]?.rawApp, "claude-desktop")
        expectEqual(byID["unpriced"]?.provider, "Desk")
        expectEqual(byID["recorded"]?.provider, "Relay")

        // Tokens: semantics 1 subtracts both cache kinds; the log column subtracts cache reads only.
        expectEqual(byID["recorded"]?.freshInput, 300)
        expectEqual(byID["recorded"]?.displayInput, 400)
        expectEqual(byID["recorded"]?.realTokens, 1200)
        expectEqual(byID["recorded"]?.groupModel, "gpt-5")

        // Speed: 200 output over 4 s of generation; session rows get an estimate; short rows get none.
        expectEqual(byID["recorded"]?.speed, 50)
        expectNil(byID["unpriced"]?.speed)
        expectNil(byID["unpriced"]?.estimatedSpeed)
        expectEqual(byID["session-own"]?.estimatedSpeed, 200)

        // Today: details only. 30 days: the old rollup is outside. All: the rollup day is included.
        let today = UsageStatsReport(data, range: .today, now: now, calendar: calendar)
        expectEqual(today.totals.requests, 6)
        expectEqual(today.hourly, true)
        expectEqual(today.buckets.count, 15)
        expectEqual(today.buckets.reduce(0) { $0 + $1.totals.requests }, 6)
        expectEqual(today.logs.first?.id, "recorded")
        expectEqual(today.logs(status: 500).map(\.id), ["failed"])
        expectEqual(today.totals.successRate, 5.0 / 6.0)
        expectEqual(today.totals.speed?.value, 50)
        expectEqual(today.totals.speed?.estimated, false)
        let all = UsageStatsReport(data, range: .all, now: now, calendar: calendar)
        expectEqual(all.totals.requests, 7 + 10)
        expectEqual(all.totals.cost, 1.25 + 2.5 + 0.5 + 2.5)
        expectEqual(all.hourly, false)
        expectEqual(all.buckets.count, 41)
        expectEqual(UsageStatsReport(data, range: .month, now: now, calendar: calendar).totals.requests, 7)

        // Tables: providers by (id, app), models by pricing model, sorted by requests.
        expectEqual(all.providers.first?.name, "Relay")
        expectEqual(all.providers.first?.totals.requests, 13)
        expectEqual(all.models.first(where: { $0.name == "gpt-5" })?.totals.requests, 12)
        expectEqual(all.models.first(where: { $0.name == "gpt-5" })?.totals.averageCost, (1.25 + 0.5 + 2.5) / 12)

        // Filters apply to details and rollups alike.
        let codex = UsageStatsReport(data, range: .all, filter: UsageFilter(app: "codex"), now: now, calendar: calendar)
        expectEqual(codex.totals.requests, 3 + 10)
        expectEqual(UsageStatsReport(data, range: .all, filter: UsageFilter(provider: "Desk"), now: now, calendar: calendar).totals.requests, 3)

        // Heatmap: Monday-first columns ending this week; quartile levels over non-zero days.
        let heatmap = UsageHeatmap(data, metric: .requests, now: now, calendar: calendar)
        expectEqual(heatmap.weeks.count, 53)
        expectEqual(heatmap.weeks.allSatisfy { $0.count == 7 }, true)
        expectEqual(calendar.component(.weekday, from: heatmap.weeks[0][0].date), 2)
        let days = heatmap.weeks.flatMap { $0 }
        expectEqual(days.first { calendar.isDate($0.date, inSameDayAs: now) }?.value, 6)
        expectEqual(days.first { calendar.isDate($0.date, inSameDayAs: now) }?.level, 2)  // days 1, 6, 10 → thresholds 1, 6, 10
        expectEqual(days.filter(\.future).allSatisfy { $0.value == 0 }, true)
        expectEqual(days.map(\.level).max(), 3)

        expectThrows(try UsageStats.read(at: root.appendingPathComponent("absent.db")))
        expectEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent.db").path), false)
    }
    func quotaHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaHistoryStore(url: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(_ offset: Double, _ balance: Double) -> UsageSnapshot {
            UsageSnapshot(quotas: [Quota(id:"wallet",label:"余额基准",remaining:balance,limit:100)],balance:balance,source:"test",fetchedAt:start.addingTimeInterval(offset))
        }
        try await store.record(provider:"A",usage:snapshot(0,80))
        try await store.record(provider:"A",usage:snapshot(60,70))
        try await store.record(provider:"B",usage:snapshot(70,90))
        var rows = try await store.read()
        expectEqual(rows.count, 2)
        expectEqual(rows.first?.balance, 70)
        try await store.record(provider:"A",usage:snapshot(10,50))
        rows = try await store.read()
        expectEqual(rows.first?.balance, 70, "late callbacks must not replace newer observations")
        try await store.record(provider:"A",usage:snapshot(900,95))
        rows = try await store.read()
        expectEqual(rows.count, 3)
        expectEqual(rows.last?.balance, 95, "recharges remain observations, not negative spending")
        expectEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await store.record(provider:"A",usage:snapshot(32*86400,88))
        rows = try await store.read()
        expectEqual(rows.count, 1)
        try Data("invalid".utf8).write(to:url)
        do { try await store.record(provider:"A",usage:snapshot(33*86400,80)); expectEqual(true,false,"corrupt history must not be overwritten") }
        catch { expectEqual(try String(contentsOf:url,encoding:.utf8),"invalid") }
    }
}

enum UsageStatsTestDay {
    static func string(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
