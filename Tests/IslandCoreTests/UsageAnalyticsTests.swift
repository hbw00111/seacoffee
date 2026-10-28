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
        expectEqual(today.logs.first?.id, "recorded")
        expectEqual(today.logs(status: 500).map(\.id), ["failed"])
        expectEqual(today.totals.successRate, 5.0 / 6.0)
        expectEqual(today.totals.speed?.value, 50)
        expectEqual(today.totals.speed?.estimated, false)
        let all = UsageStatsReport(data, range: .all, now: now, calendar: calendar)
        expectEqual(all.totals.requests, 7 + 10)
        expectEqual(all.totals.cost, 1.25 + 2.5 + 0.5 + 2.5)
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

        expectThrows(try UsageStats.read(at: root.appendingPathComponent("absent.db")))
        expectEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent.db").path), false)
    }
    func combinedRecords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_792_306_800)
        let (root, url) = try database(now: now, calendar: calendar)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try UsageStats.read(at: url)
        data.dshSessions = [try session(id: "recorded", at: now.addingTimeInterval(-30)),
                            try session(id: "old", at: now.addingTimeInterval(-86_401)),
                            try session(id: "future", at: now.addingTimeInterval(60)),
                            try session(id: "blank", at: now, blank: true)]
        let requests = UsageStatsReport(try UsageStats.read(at: url), range: .today, now: now, calendar: calendar)
        let report = UsageStatsReport(data, range: .today, now: now, calendar: calendar)
        expectEqual(report.totals.requests, requests.totals.requests, "a DSH session is not a request")
        expectEqual(report.totals.sessions, 1)
        expectEqual(report.totals.recordCount, 7)
        expectEqual(report.totals.cost, requests.totals.cost, "DSH does not invent a price")
        expectEqual(report.totals.successRate, requests.totals.successRate, "DSH has no HTTP result")
        expectEqual(report.totals.realTokens, requests.totals.realTokens + 1200)
        expectEqual(report.totals.speed?.value, 80, "measured decode spans use a ratio of sums")
        expectEqual(report.records.first?.id, "dsh:recorded")
        expectEqual(Set(report.records.map(\.id)).count, report.records.count, "request and session IDs cannot collide")
        expectEqual(report.logs.count, 6)
        let dsh = UsageStatsReport(data, range: .today, filter: UsageFilter(app: "dsh"), now: now, calendar: calendar)
        expectEqual(dsh.records.map(\.id), ["dsh:recorded"])
        let codex = UsageStatsReport(data, range: .today, filter: UsageFilter(app: "codex"), now: now, calendar: calendar)
        expectEqual(codex.totals.sessions, 0)
        let model = UsageStatsReport(data, range: .today, filter: UsageFilter(model: "gpt-5"), now: now, calendar: calendar)
        expectEqual(model.totals.requests, 1)
        expectEqual(model.totals.sessions, 1)
        expectEqual(model.models.count, 1)
        expectEqual(model.models.first?.totals.sessions, 1)
        expectEqual(model.providers.filter { $0.app == "dsh" }.first?.name, "Relay")
        expectEqual(UsageStatsReport(data, range: .today, filter: UsageFilter(provider: "Relay"), now: now, calendar: calendar).totals.sessions, 1)
        expectEqual(data.apps.contains("dsh"), true)
        expectEqual(data.models.contains("gpt-5"), true)
        let all = UsageStatsReport(data, range: .all, now: now, calendar: calendar)
        expectEqual(all.totals.sessions, 2)
        expectEqual(all.totals.requests, 17, "daily rollups remain in totals, not the detail timeline")
        expectEqual(all.records.count, 9)
    }

    func dshOnlyRecords() throws {
        let now = Date(timeIntervalSince1970: 1_792_306_800)
        let sessions = try (0..<45).map { try session(id: "s-\($0)", at: now.addingTimeInterval(-Double($0))) }
        let data = UsageDataset(dshSessions: sessions)
        let report = UsageStatsReport(data, range: .all, now: now)
        expectEqual(report.records.count, 45, "the unified pager must receive every session")
        expectEqual(report.totals.requests, 0)
        expectEqual(report.totals.sessions, 45)
        expectEqual(report.totals.realTokens, 45 * 1200)
        expectNil(report.totals.successRate)
        expectNil(report.totals.averageCost)
        expectEqual(report.providers.first?.totals.sessions, 45)
        expectEqual(report.models.first?.totals.sessions, 45)
        expectEqual(data.apps, ["dsh"])
        expectEqual(data.providers, ["Relay"])
        expectEqual(data.models, ["gpt-5"])
        expectEqual(report.records.last?.id, "dsh:s-44")
    }

    private func session(id: String, at date: Date, blank: Bool = false) throws -> DshSession {
        let rows: [String: Any] = [
            "sessionStats": ["val": ["turns": blank ? 0 : 2, "steps": blank ? 0 : 4,
                                     "decodeMs": 1000, "decodeTokens": 200]],
            "tokenUsage": ["val": ["totals": ["uncachedInputTokens": blank ? 0 : 300,
                                                "outputTokens": blank ? 0 : 200, "cacheReadTokens": blank ? 0 : 600,
                                                "cacheWriteTokens": blank ? 0 : 100]]],
            "modelSelection": ["val": ["lastUsed": ["model": "route/gpt-5", "provider": "Relay"]]],
            "sessionListMetadata": ["val": ["lastPromptAt": date.timeIntervalSince1970 * 1000]]
        ]
        let json = try JSONSerialization.data(withJSONObject: ["record": ["identity": ["createdAt": date.timeIntervalSince1970 * 1000], "rows": rows]])
        guard let session = DshStore.parse(json, id: id, modified: date) else { throw UsageReadError.incompatible }
        return session
    }

    func quotaHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaHistoryStore(url: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(_ offset: Double, _ balance: Double) -> UsageSnapshot {
            UsageSnapshot(quotas: [Quota(id:"wallet",label:"余额基准",remaining:balance,limit:100)],balance:balance,fetchedAt:start.addingTimeInterval(offset))
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
