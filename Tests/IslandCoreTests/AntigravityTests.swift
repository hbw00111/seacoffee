import Foundation
import IslandCore
import SQLite3

final class AntigravityTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func credentials() throws {
        let json = #"{"token":{"access_token":"ya29.sample","token_type":"Bearer","refresh_token":"1//sample","expiry":"2026-11-16T21:41:33.665511+08:00","expires_in":"3599"},"auth_method":"consumer","id_token_email":"a@example.com"}"#
        // go-keyring stores the JSON base64-wrapped; `security -w` returns that text.
        let wrapped = try AntigravityCredentials.parse(data("go-keyring-base64:" + data(json).base64EncodedString() + "\n"))
        expectEqual(wrapped.accessToken, "ya29.sample")
        expectEqual(wrapped.email, "a@example.com")
        expectEqual(wrapped.expiresAt, UsageDecoder.date("2026-11-16T13:41:33.665511Z"))
        expectEqual(try AntigravityCredentials.parse(data(json)), wrapped, "the plain file form parses the same")
        expectEqual(try AntigravityCredentials.parse(data(#"{"token":{"access_token":"a","expiry":"2020-01-01T00:00:00Z"}}"#)).isExpired, true)
        expectEqual(try AntigravityCredentials.parse(data(#"{"token":{"access_token":"a"}}"#)).isExpired, false)
        expectAntigravityError(.missingCredentials, try AntigravityCredentials.parse(data(#"{"token":{"access_token":""}}"#)))
        expectAntigravityError(.invalidResponse, try AntigravityCredentials.parse(data("go-keyring-base64:%%%")))
        expectAntigravityError(.invalidResponse, try AntigravityCredentials.parse(data("[]")))
    }

    func modelQuotas() throws {
        let usage = try AntigravityProtocol.usage(data(#"""
            {"models":{
              "gemini-4-hydrogen-medium":{"displayName":"Gemini 4 Hydrogen (Medium)","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-11-16T15:00:00Z"}},
              "gemini-4-hydrogen-high":{"displayName":"Gemini 4 Hydrogen (High)","quotaInfo":{"remainingFraction":0.4,"resetTime":"2026-11-16T15:00:00Z"}},
              "claude-opus-5-5-high":{"displayName":"Claude Opus 5.5 (High)","quotaInfo":{"resetTime":"2026-11-17T02:00:00Z"}},
              "gemini-3.8-flash-low":{"displayName":"Gemini 3.8 Flash","quotaInfo":{"remainingFraction":1}},
              "tab_flash_lite":{"quotaInfo":{"remainingFraction":0.1}},
              "no-quota":{"displayName":"No Quota"},
              "empty-quota":{"displayName":"Empty Quota","quotaInfo":{}}
            }}
            """#))
        // Effort variants fold into their tightest value; the tightest model comes first.
        expectEqual(usage.quotas.map(\.label), ["Claude Opus 5.5", "Gemini 4 Hydrogen", "Gemini 3.8 Flash"])
        expectEqual(usage.quotas.map(\.percent), [0, 40, 100])
        expectEqual(usage.quotas.map(\.id), ["antigravity-Claude Opus 5.5", "antigravity-Gemini 4 Hydrogen", "antigravity-Gemini 3.8 Flash"])
        expectEqual(usage.quotas.first?.resetsAt, UsageDecoder.date("2026-11-17T02:00:00Z"))
        expectEqual(usage.quotas.first?.monetary, false)
        expectNil(usage.quotas.last?.resetsAt)
        expectAntigravityError(.usageUnavailable, try AntigravityProtocol.usage(data(#"{"models":{"a":{"displayName":"A"}}}"#)))
        expectAntigravityError(.invalidResponse, try AntigravityProtocol.usage(data(#"{}"#)))
        expectAntigravityError(.invalidResponse, try AntigravityProtocol.usage(data("nope")))
    }

    func accountAndStatus() {
        let account = AntigravityProtocol.account(data(#"{"cloudaicompanionProject":"sample-project","currentTier":{"id":"free-tier","name":"Free"},"paidTier":{"name":"Google AI Pro"}}"#))
        expectEqual(account.project, "sample-project")
        expectEqual(account.plan, "Google AI Pro")
        let nested = AntigravityProtocol.account(data(#"{"cloudaicompanionProject":{"id":"nested"},"currentTier":{"name":"Free"}}"#))
        expectEqual(nested.project, "nested")
        expectEqual(nested.plan, "Free")
        expectNil(AntigravityProtocol.account(data("{}")).project)
        expectNil(AntigravityProtocol.account(data("{}")).plan)
        expectEqual(String(decoding: AntigravityProtocol.modelsBody(project: "p"), as: UTF8.self), #"{"project":"p"}"#)
        expectEqual(String(decoding: AntigravityProtocol.modelsBody(project: nil), as: UTF8.self), "{}")
        expectNoThrow(try AntigravityProtocol.validate(status: 200))
        expectAntigravityError(.signedOut, try AntigravityProtocol.validate(status: 401))
        expectAntigravityError(.http(429, nil), try AntigravityProtocol.validate(status: 429))
        let denied = data(#"{"error":{"code":403,"message":"Permission denied on resource project sample.","status":"PERMISSION_DENIED"}}"#)
        expectAntigravityError(.http(403, "PERMISSION_DENIED · Permission denied on resource project sample."), try AntigravityProtocol.validate(status: 403, body: denied))
        expectEqual(AntigravityError.http(403, "PERMISSION_DENIED").errorDescription, "Antigravity 请求失败（HTTP 403：PERMISSION_DENIED）。")
    }

    /// Antigravity's own table, trimmed to the columns Sea Coffee selects plus the title it must not need.
    private func makeDatabase(_ url: URL, _ rows: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '',
                last_modified_time datetime NOT NULL, workspace_uris text NOT NULL, status text NOT NULL DEFAULT '',
                parent_conversation_id text NOT NULL DEFAULT '', nesting_depth integer NOT NULL DEFAULT 0);
            """
        precondition(sqlite3_exec(db, schema + rows.joined(separator: ";"), nil, nil, nil) == SQLITE_OK)
    }
    private func row(_ id: String, _ status: String, _ time: Date, workspace: String = #"["file:///Users/example/api"]"#,
                     parent: String = "", depth: Int = 0) -> String {
        "INSERT OR REPLACE INTO conversation_summaries VALUES ('\(id)', 'secret title', '\(stamp(time))', '\(workspace)', '\(status)', '\(parent)', \(depth))"
    }
    /// Go's text form: `2026-11-16 12:09:36.878149+00:00`.
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'000+00:00'"
        return formatter.string(from: date)
    }

    func conversations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        expectEqual(AntigravityStore.conversations(under: root, since: .distantPast)?.count, 0, "no database is no conversations")
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        try makeDatabase(root.appendingPathComponent("antigravity-cli/conversation_summaries.db"), [
            row("run", "CASCADE_RUN_STATUS_RUNNING", now.addingTimeInterval(-5)),
            row("both", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(-10), workspace: #"["file:///Users/example/%E8%AE%BA%E6%96%87"]"#),
            row("child", "CASCADE_RUN_STATUS_RUNNING", now, parent: "run", depth: 1),
            row("old", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(-400_000)),
            row("never", "CASCADE_RUN_STATUS_IDLE", Date(timeIntervalSince1970: -62_135_596_800)),
        ])
        // The desktop app mirrors CLI conversations; its copy of `both` is older and must lose.
        try makeDatabase(root.appendingPathComponent("antigravity/conversation_summaries.db"), [
            row("both", "CASCADE_RUN_STATUS_RUNNING", now.addingTimeInterval(-60)),
            row("app", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(-20), workspace: ""),
        ])
        let found = AntigravityStore.conversations(under: root, since: now.addingTimeInterval(-172800)) ?? []
        expectEqual(found.map(\.id), ["run", "both", "app"], "top-level conversations of two days, newest first")
        expectEqual(found.map(\.status), ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_IDLE", "CASCADE_RUN_STATUS_IDLE"])
        expectEqual(found.map(\.project), ["api", "论文", nil])
        // Julian-day arithmetic is good to well under a millisecond.
        expectEqual(abs((found.first?.modifiedAt ?? .distantPast).timeIntervalSince(now.addingTimeInterval(-5))) < 0.001, true, "text time decodes to the same instant")

        try Data("not a database".utf8).write(to: root.appendingPathComponent("antigravity-cli/conversation_summaries.db"))
        expectEqual(AntigravityStore.conversations(under: root, since: now.addingTimeInterval(-172800))?.map(\.id), ["app", "both"],
                    "one unreadable database does not hide the other")
        try Data("not a database".utf8).write(to: root.appendingPathComponent("antigravity/conversation_summaries.db"))
        expectNil(AntigravityStore.conversations(under: root, since: .distantPast))
    }

    func runStates() {
        func conversation(_ status: String, _ seconds: TimeInterval) -> AntigravityStore.Conversation {
            AntigravityStore.Conversation(id: "c", status: "CASCADE_RUN_STATUS_" + status, modifiedAt: Date(timeIntervalSince1970: seconds), project: "api")
        }
        var s = SessionState(id: "antigravity:c", agent: .antigravity)
        s.consumeAntigravity(conversation("IDLE", 100))
        expectEqual(s.state, .unknown, "idle on first sight has no known outcome")
        expectEqual(s.transitionID, "")
        expectEqual(s.project, "api")
        s.consumeAntigravity(conversation("RUNNING", 110))
        expectEqual(s.state, .running)
        let started = s.transitionID
        s.consumeAntigravity(conversation("BUSY", 120))
        expectEqual(s.transitionID, started, "more work in the same turn is not a new transition")
        expectEqual(s.updatedAt, Date(timeIntervalSince1970: 120))
        s.consumeAntigravity(conversation("IDLE", 130))
        expectEqual(s.state, .completed)
        let finished = s.transitionID
        s.consumeAntigravity(conversation("IDLE", 130))
        expectEqual(s.transitionID, finished)
        s.consumeAntigravity(conversation("RUNNING", 140))
        s.consumeAntigravity(conversation("CANCELING", 150))
        expectEqual(s.state, .running)
        s.consumeAntigravity(conversation("IDLE", 151))
        expectEqual(s.state, .interrupted, "a turn seen canceling ends interrupted")
        s.consumeAntigravity(conversation("SOMETHING_NEW", 160))
        expectEqual(s.state, .unknown)
    }

    func monitorReportsCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("antigravity-cli/conversation_summaries.db")
        let now = Date()
        try makeDatabase(db, [row("a", "CASCADE_RUN_STATUS_RUNNING", now), row("idle", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(-30))])
        var received: MonitorSnapshot?
        let monitor = SessionMonitor(sources: [SessionSource(agent: .antigravity, path: root.path, isDatabase: true)]) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.map(\.state), [.running, .unknown])
        expectEqual(received?.sessions.first?.id, "antigravity:a")
        expectEqual(received?.finished.count, 0)
        var handle: OpaquePointer?
        precondition(sqlite3_open(db.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, row("a", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(2)), nil, nil, nil)
        sqlite3_close(handle)
        monitor.poll()
        expectEqual(received?.finished.map(\.state), [.completed])
        expectEqual(received?.finished.first?.agent, .antigravity)
        expectEqual(received?.finished.first?.project, "api")
        monitor.poll()
        expectEqual(received?.finished.count, 0, "a finished turn is announced once")
    }

    private func expectAntigravityError<T>(_ expected: AntigravityError, _ expression: @autoclosure () throws -> T,
                                           file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try expression(); expectEqual("no error", "\(expected)", file: file, line: line) }
        catch let error as AntigravityError { expectEqual(error, expected, file: file, line: line) }
        catch { expectEqual("\(error)", "\(expected)", file: file, line: line) }
    }
}
