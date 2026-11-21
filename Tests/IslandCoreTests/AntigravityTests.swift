import Foundation
import IslandCore
import SQLite3

final class AntigravityTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func hubDiscovery() {
        let hub = AntigravityHub.parse(data(#"{"pid":1858,"httpsPort":49800,"httpPort":49801,"lsVersion":"2.32.1","csrfToken":"sample-token"}"#))
        expectEqual(hub?.pid, 1858)
        expectEqual(hub?.csrfToken, "sample-token")
        expectEqual(hub?.endpoints.map(\.absoluteString) ?? [], [
            "https://127.0.0.1:49800/exa.language_server_pb.LanguageServerService/",
            "http://127.0.0.1:49801/exa.language_server_pb.LanguageServerService/"])
        expectEqual(AntigravityHub.parse(data(#"{"pid":7,"httpPort":49801,"csrfToken":"t"}"#))?.endpoints.count, 1)
        for bad in [#"{"pid":7,"httpPort":49801}"#, #"{"pid":7,"csrfToken":"t"}"#, #"{"pid":0,"httpPort":1,"csrfToken":"t"}"#,
                    #"{"pid":7,"httpPort":70000,"csrfToken":"t"}"#, "[]"] {
            expectNil(AntigravityHub.parse(data(bad)))
        }
    }

    func quotaSummary() throws {
        // The shape the desktop app's local server returned on 2026-11-17, values changed.
        let usage = try AntigravityProtocol.usage(data(#"""
            {"response":{"description":"…","groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.808,"resetTime":"2026-11-21T00:55:05Z"},
                {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.96,"resetTime":"2026-11-17T04:22:48Z"},
                {"bucketId":"gemini-unknown","window":"weekly","resetTime":"2026-11-22T14:55:31Z"},
                {"bucketId":"gemini-off","window":"daily","remainingFraction":0.5,"disabled":true},
                {"bucketId":"gemini-new","displayName":"Burst","window":"burst","remainingFraction":1.4}]},
              {"displayName":"Claude and GPT models","buckets":[
                {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.25,"resetTime":"2026-11-22T14:55:31Z"},
                {"bucketId":"3p-5h","window":"5h","remainingFraction":0.1}]}]}}
            """#))
        // Only Gemini, even when Claude/GPT is tighter. Five-hour first (the notch), weekly second
        // (the panel), then the rest; unknown and disabled buckets are left out; an unknown window keeps its own name.
        expectEqual(usage.quotas.map(\.label), ["Gemini 5 小时", "Gemini 每周", "Gemini Burst"])
        expectEqual(usage.quotas.map(\.percent), [96, 81, 100])
        expectEqual(usage.quotas.first?.id, "antigravity-gemini-5h")
        expectEqual(usage.quotas[1].resetsAt, UsageDecoder.date("2026-11-21T00:55:05Z"))
        expectEqual(usage.quotas.first?.monetary, false)
        expectAntigravityError(.usageUnavailable, try AntigravityProtocol.usage(data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"a"}]}]}}"#)))
        expectAntigravityError(.usageUnavailable, try AntigravityProtocol.usage(data(#"{"response":{"groups":[{"displayName":"Claude and GPT models","buckets":[{"bucketId":"b","window":"5h","remainingFraction":0.5}]}]}}"#)))
        expectAntigravityError(.invalidResponse, try AntigravityProtocol.usage(data(#"{"response":{}}"#)))
        expectAntigravityError(.invalidResponse, try AntigravityProtocol.usage(data("nope")))
    }

    func identityAndStatus() {
        let identity = AntigravityProtocol.identity(data(#"{"userStatus":{"email":"a@example.com","userTier":{"id":"g1-ultra-tier","name":"Google AI Ultra"},"planStatus":{"planInfo":{"planName":"Pro"}}}}"#))
        expectEqual(identity.email, "a@example.com")
        expectEqual(identity.plan, "Google AI Ultra")
        expectEqual(AntigravityProtocol.identity(data(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"}}}}"#)).plan, "Pro")
        expectNil(AntigravityProtocol.identity(data("{}")).email)
        expectNoThrow(try AntigravityProtocol.validate(status: 200))
        expectAntigravityError(.http(500, nil), try AntigravityProtocol.validate(status: 500))
        let refused = data(#"{"code":"unauthenticated","message":"unauthenticated: missing CSRF token"}"#)
        expectAntigravityError(.http(401, "unauthenticated · unauthenticated: missing CSRF token"), try AntigravityProtocol.validate(status: 401, body: refused))
        expectEqual(AntigravityError.http(401, "unauthenticated").errorDescription, "Antigravity 请求失败（HTTP 401：unauthenticated）。")
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

    /// T3 Code runs `agy acp --gemini-dir ~/.t3/userdata/providers/antigravity/<hash>`.
    func linkedFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent(".gemini"), linked = home.appendingPathComponent("providers")
        expectEqual(AntigravityStore.roots(base: base, linked: linked), [base], "no T3 folder is just ~/.gemini")
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        let t3 = linked.appendingPathComponent("0f3a9c1e")
        try makeDatabase(t3.appendingPathComponent("antigravity-acp/conversation_summaries.db"), [
            row("t3", "CASCADE_RUN_STATUS_RUNNING", now.addingTimeInterval(-3)),
        ])
        try makeDatabase(base.appendingPathComponent("antigravity/conversation_summaries.db"), [
            row("app", "CASCADE_RUN_STATUS_IDLE", now.addingTimeInterval(-20)),
        ])
        try Data().write(to: linked.appendingPathComponent("stray-file"))
        let roots = AntigravityStore.roots(base: base, linked: linked)
        expectEqual(roots.map(\.lastPathComponent), [".gemini", "0f3a9c1e"], "subfolders only, files ignored")
        expectEqual(AntigravityStore.conversations(under: roots, since: now.addingTimeInterval(-172800))?.map(\.id), ["t3", "app"],
                    "T3 Code's conversations join the app's")
        let id = "0b90e9b2-ff91-4b88-9c9b-6481423ecbcd"
        try makeConversation(t3.appendingPathComponent("antigravity-acp/conversations/\(id).db"), [executorMetadata("gemini-4-neon-high")])
        expectEqual(AntigravityStore.model(under: roots, conversation: id), "gemini-4-neon-high", "model read from T3 Code's folder")
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

    /// Protobuf wire format: a length-delimited field.
    private func field(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        func varint(_ value: Int) -> [UInt8] {
            var value = value, out: [UInt8] = []
            while value >= 0x80 { out.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
            return out + [UInt8(value)]
        }
        return varint(number << 3 | 2) + varint(payload.count) + payload
    }
    /// An `executor_metadata` blob: unrelated fields around the run configuration's model.
    private func executorMetadata(_ model: String) -> Data {
        let config = [0x08, 0x96, 0x01] + field(2, Array("secret prompt".utf8)) + field(28, Array(model.utf8))
        let other = field(28, Array("not-this".utf8))
        return Data([0x09, 1, 2, 3, 4, 5, 6, 7, 8] + field(3, other) + field(10, [0x15, 1, 2, 3, 4] + field(1, config)))
    }
    private func makeConversation(_ url: URL, _ blobs: [Data]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE executor_metadata (idx integer PRIMARY KEY, data blob); CREATE TABLE steps (idx integer, step_payload blob)", nil, nil, nil) == SQLITE_OK)
        for (index, blob) in blobs.enumerated() {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO executor_metadata VALUES (?1, ?2)", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(index))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            precondition(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }

    func conversationModel() throws {
        expectEqual(AntigravityStore.model(fromExecutorMetadata: executorMetadata("gemini-4-hydrogen-medium")), "gemini-4-hydrogen-medium")
        expectNil(AntigravityStore.model(fromExecutorMetadata: Data()))
        expectNil(AntigravityStore.model(fromExecutorMetadata: Data([0x52, 0x7f, 0x01])))
        expectNil(AntigravityStore.model(fromExecutorMetadata: Data(field(10, field(1, field(28, Array("two words".utf8)))))))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0b90e9b2-ff91-4b88-9c9b-6481423ecbcd"
        expectNil(AntigravityStore.model(under: root, conversation: id))
        try makeConversation(root.appendingPathComponent("antigravity-cli/conversations/\(id).db"),
                             [executorMetadata("gemini-3.8-flash-high"), executorMetadata("gemini-4-neon-high")])
        expectEqual(AntigravityStore.model(under: root, conversation: id), "gemini-4-neon-high", "the latest turn's model")
        try makeConversation(root.appendingPathComponent("antigravity/conversations/empty.db"), [])
        expectNil(AntigravityStore.model(under: root, conversation: "empty"))
        expectNil(AntigravityStore.model(under: root, conversation: "../antigravity-cli/conversations/\(id)"))

        var asked = 0
        func conversation(_ status: String, _ seconds: TimeInterval) -> AntigravityStore.Conversation {
            AntigravityStore.Conversation(id: "c", status: "CASCADE_RUN_STATUS_" + status, modifiedAt: Date(timeIntervalSince1970: seconds), project: "api")
        }
        var s = SessionState(id: "antigravity:c", agent: .antigravity)
        var current = "gemini-4-hydrogen-medium"
        let lookup = { () -> String? in asked += 1; return current }
        s.consumeAntigravity(conversation("IDLE", 100), model: lookup)
        expectEqual(s.model, "gemini-4-hydrogen-medium", "read on first sight")
        s.consumeAntigravity(conversation("IDLE", 100), model: lookup)
        s.consumeAntigravity(conversation("RUNNING", 110), model: lookup)
        s.consumeAntigravity(conversation("BUSY", 120), model: lookup)
        expectEqual(asked, 2, "not read again until the state changes")
        current = "gemini-4-neon-high"
        s.consumeAntigravity(conversation("IDLE", 130), model: lookup)
        expectEqual(s.state, .completed)
        expectEqual(s.modelName, "gemini-4-neon-high", "the model that finished the turn")
        s.consumeAntigravity(conversation("RUNNING", 140), model: { nil })
        expectEqual(s.model, "gemini-4-neon-high", "an unreadable lookup keeps the last known model")
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
        expectNil(received?.finished.first?.model)
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
