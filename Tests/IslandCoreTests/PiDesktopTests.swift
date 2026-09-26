import Foundation
import IslandCore
import SQLite3

final class PiDesktopTests {
    /// Builds a database with PI-Desktop's schema (v18, trimmed to the columns Sea Coffee reads).
    private func makeDatabase(_ url: URL, _ rows: [String]) {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE projects (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL);
            CREATE TABLE sessions (id TEXT PRIMARY KEY, project_id INTEGER, deleted_at INTEGER, updated_at INTEGER NOT NULL);
            CREATE TABLE turns (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'running',
                                model_id TEXT, started_at INTEGER NOT NULL, ended_at INTEGER);
            INSERT INTO projects VALUES (1, '/Users/example/pidesktop', 'pidesktop');
            """
        precondition(sqlite3_exec(db, schema + rows.joined(separator: ";"), nil, nil, nil) == SQLITE_OK)
    }

    func latestTurnPerSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("pi.sqlite")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDatabase(db, [
            "INSERT INTO sessions VALUES ('a', 1, NULL, \(now))",
            "INSERT INTO sessions VALUES ('b', 1, NULL, \(now - 5000))",
            "INSERT INTO sessions VALUES ('gone', 1, \(now), \(now))",
            "INSERT INTO sessions VALUES ('old', NULL, NULL, \(now - 400_000_000))",
            // Session a: an older completed turn, then the current running one.
            "INSERT INTO turns VALUES ('a1', 'a', 'completed', 'cline-pass/deepseek-v4.1-flash', \(now - 90000), \(now - 60000))",
            "INSERT INTO turns VALUES ('a2', 'a', 'running', 'cline-pass/deepseek-v4.1-flash', \(now - 30000), NULL)",
            "INSERT INTO turns VALUES ('b1', 'b', 'aborted', 'gpt-6-sol', \(now - 20000), \(now - 10000))",
            "INSERT INTO turns VALUES ('g1', 'gone', 'running', NULL, \(now - 1000), NULL)",
            "INSERT INTO turns VALUES ('o1', 'old', 'completed', NULL, \(now - 400_000_000), \(now - 399_000_000))",
        ])
        let turns = PiDesktopStore.latestTurns(at: db, since: Date().addingTimeInterval(-172800)) ?? []
        expectEqual(turns.map(\.turnID), ["b1", "a2"], "latest turn per live session within two days")
        expectEqual(turns.last?.project, "pidesktop")
        expectNil(turns.last?.endedAt)

        var running = SessionState(id: "pi-desktop:a", agent: .pi)
        running.consumePiDesktop(turns[1])
        expectEqual(running.state, .running)
        expectEqual(running.channelName, "Cline Pass")
        expectEqual(running.modelName, "deepseek-v4.1-flash")
        // A long turn stays fresh through the session's own activity time.
        expectEqual(running.updatedAt, Date(timeIntervalSince1970: Double(now) / 1000))
        let key = running.transitionID
        running.consumePiDesktop(turns[1])
        expectEqual(running.transitionID, key, "an unchanged turn is not a new transition")

        var aborted = SessionState(id: "pi-desktop:b", agent: .pi)
        aborted.consumePiDesktop(turns[0])
        expectEqual(aborted.state, .interrupted)
        expectNil(PiDesktopStore.latestTurns(at: root.appendingPathComponent("missing.sqlite"), since: .distantPast))
    }

    func monitorReportsCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("pi.sqlite")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDatabase(db, ["INSERT INTO sessions VALUES ('a', 1, NULL, \(now))",
                          "INSERT INTO turns VALUES ('a1', 'a', 'running', 'cline-pass/glm-5.3-flash', \(now), NULL)"])
        var received: MonitorSnapshot?
        let monitor = SessionMonitor(sources: [SessionSource(agent: .pi, path: db.path, isDatabase: true)]) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .running)
        expectEqual(received?.finished.count, 0)
        var handle: OpaquePointer?
        precondition(sqlite3_open(db.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "UPDATE turns SET status = 'completed', ended_at = \(now + 2000) WHERE id = 'a1'", nil, nil, nil)
        sqlite3_close(handle)
        monitor.poll()
        expectEqual(received?.finished.map(\.state), [.completed])
        expectEqual(received?.finished.first?.project, "pidesktop")
    }
}
