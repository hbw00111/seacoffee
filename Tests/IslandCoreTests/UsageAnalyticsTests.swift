import Foundation
import SQLite3
import IslandCore

final class UsageAnalyticsTests {
    func normalization() {
        expectEqual(UsageAnalyticsReader.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 1), 300)
        expectEqual(UsageAnalyticsReader.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 0), 400)
        expectEqual(UsageAnalyticsReader.freshInput(app: "codex", input: 1000, read: 600, write: 100, semantics: 2), 1000)
        expectEqual(UsageAnalyticsReader.freshInput(app: "claude", input: 1000, read: 600, write: 100, semantics: 0), 1000)
        expectEqual(UsageAnalyticsReader.freshInput(app: "grokbuild", input: 1000, read: 600, write: 100, semantics: 1), 300)
        expectEqual(UsageAnalyticsReader.freshInput(app: "pi", input: 100, read: 600, write: 100, semantics: 2), 100)
    }
    func totals() {
        let rows = [
            UsageRecord(id:"1",date:Date(),app:"codex",provider:"a",model:"m",input:300,output:50,cacheRead:600,cacheWrite:100,cost:1.25,status:200),
            UsageRecord(id:"2",date:Date(),app:"claude",provider:"b",model:"m",input:100,output:50,cacheRead:0,cacheWrite:0,cost:nil,status:500),
            UsageRecord(id:"3",date:Date(),app:"pi",provider:"c",model:"m",input:0,output:0,cacheRead:0,cacheWrite:0,cost:0,status:nil)
        ]
        let totals = UsageTotals(rows)
        expectEqual(totals.tokens, 1200)
        expectEqual(totals.cost, 1.25)
        expectEqual(totals.priced, 2)
        expectEqual(totals.successRate, 0.5)
        expectEqual(totals.hitRate, 600.0 / 1100.0)
        expectNil(UsageTotals().successRate)
        expectNil(UsageTotals().hitRate)
        let since = Calendar.current.startOfDay(for: Date())
        let report = UsageReport(records: rows, since: since, app: "codex", provider: "a", model: "m")
        expectEqual(report.rows.count, 1)
        expectEqual(report.totals.tokens, 1050)
        expectEqual(report.buckets.reduce(0) { $0 + $1.totals.tokens }, report.totals.tokens)
        expectEqual(report.models.first?.1.tokens, report.totals.tokens)
        expectEqual(UsageReport(records: rows, since: since, app: "missing").totals.requests, 0)

    }
    func database() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw UsageReadError.unavailable }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE proxy_request_logs(request_id TEXT PRIMARY KEY, created_at INTEGER, app_type TEXT, model TEXT,
            input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
            total_cost_usd TEXT, status_code INTEGER, input_token_semantics INTEGER);
            INSERT INTO proxy_request_logs VALUES('1',1000,'codex','test',1000,50,600,100,'1.25',200,1);
            INSERT INTO proxy_request_logs VALUES('2',2000,'claude','test',100,50,0,0,NULL,0,0);
            INSERT INTO proxy_request_logs VALUES('future',4000,'claude','test',100,50,0,0,'bad',500,0);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageReadError.incompatible }
        let before = try Data(contentsOf: url)
        let result = try UsageAnalyticsReader.read(at: url, since: Date(timeIntervalSince1970: 1000), until: Date(timeIntervalSince1970: 3000))
        expectEqual(result.records.count, 2)
        expectEqual(result.records.last?.tokens, 1050)
        expectNil(result.records.first?.cost)
        expectNil(result.records.first?.status)
        expectEqual(result.truncated, false)
        let capped = try UsageAnalyticsReader.read(at: url, since: .distantPast, until: Date(timeIntervalSince1970: 3000), limit: 1)
        expectEqual(capped.truncated, true)
        expectEqual(capped.records.count, 1)
        expectEqual(try Data(contentsOf: url), before, "database must remain unchanged")
        expectThrows(try UsageAnalyticsReader.read(at: root.appendingPathComponent("absent.db"), since: .distantPast))
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
