import Foundation
import SQLite3

/// Antigravity (the `agy` CLI and the desktop app) lists its conversations in
/// `~/.gemini/antigravity-cli/conversation_summaries.db` and `~/.gemini/antigravity/…`, one row
/// per conversation with a live run status. Only status, times and workspace folders are
/// selected — never the title, preview or search index, which hold conversation text.
public enum AntigravityStore {
    public struct Conversation: Equatable, Sendable {
        public let id: String
        /// `CASCADE_RUN_STATUS_IDLE`, `_RUNNING`, `_BUSY` or `_CANCELING`.
        public let status: String
        public let modifiedAt: Date
        public let project: String?
        public init(id: String, status: String, modifiedAt: Date, project: String?) {
            self.id = id; self.status = status; self.modifiedAt = modifiedAt; self.project = project
        }
    }

    static let folders = ["antigravity-cli", "antigravity"]

    /// Top-level conversations changed since `since`, newest first. The desktop app mirrors the
    /// CLI's conversations into its own database, so the fresher row of each id wins. Returns nil
    /// when a database exists but cannot be read right now; none at all is an empty list.
    public static func conversations(under root: URL, since: Date, limit: Int = 100) -> [Conversation]? {
        var latest: [String: Conversation] = [:]
        var failed = false
        for folder in folders {
            let url = root.appendingPathComponent(folder).appendingPathComponent("conversation_summaries.db")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let rows = read(url, since: since, limit: limit) else { failed = true; continue }
            for row in rows where latest[row.id].map({ $0.modifiedAt < row.modifiedAt }) ?? true { latest[row.id] = row }
        }
        if failed && latest.isEmpty { return nil }
        return Array(latest.values.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }

    private static func read(_ url: URL, since: Date, limit: Int) -> [Conversation]? {
        var db: OpaquePointer?
        // Without a `-wal` file nobody is writing. Opening such a WAL database read-only would
        // create `-wal` and `-shm` files in Antigravity's folder; `immutable` reads it untouched.
        let idle = !FileManager.default.fileExists(atPath: url.path + "-wal")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(path)?mode=ro" + (idle ? "&immutable=1" : "")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        // Never wait on Antigravity's writer; a skipped poll is retried two seconds later.
        sqlite3_busy_timeout(db, 150)
        // Times are text (`2026-11-16 12:09:36.878149+00:00`); subagent conversations are nested.
        let sql = """
            SELECT conversation_id, status, (julianday(last_modified_time) - 2440587.5) * 86400.0, workspace_uris
            FROM conversation_summaries
            WHERE nesting_depth = 0 AND parent_conversation_id = ''
              AND julianday(last_modified_time) >= julianday(?1, 'unixepoch')
            ORDER BY last_modified_time DESC LIMIT ?2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var rows: [Conversation] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }), !id.isEmpty,
                  sqlite3_column_type(statement, 2) != SQLITE_NULL else { continue }
            let status = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let workspaces = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            rows.append(Conversation(id: id, status: status,
                                     modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                     project: project(workspaces)))
        }
        return rows
    }

    /// `["file:///Users/example/api"]` → `api`.
    static func project(_ workspaces: String) -> String? {
        guard let uris = try? JSONSerialization.jsonObject(with: Data(workspaces.utf8)) as? [String],
              let first = uris.first, let url = URL(string: first), url.isFileURL else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

extension SessionState {
    public mutating func consumeAntigravity(_ conversation: AntigravityStore.Conversation) {
        if let project = conversation.project { self.project = project }
        let next: RunState
        switch conversation.status {
        case "CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING": next = .running
        // A conversation returns to idle after each turn; one first seen idle has no known outcome.
        case "CASCADE_RUN_STATUS_IDLE":
            next = state != .running ? state : transitionID.hasPrefix("canceling:") ? .interrupted : .completed
        default: next = .unknown
        }
        let canceling = conversation.status == "CASCADE_RUN_STATUS_CANCELING"
        if next != state || (canceling && !transitionID.hasPrefix("canceling:")) {
            state = next
            transitionID = "\(canceling ? "canceling" : next.rawValue):\(conversation.modifiedAt.timeIntervalSince1970)"
        }
        updatedAt = max(updatedAt, conversation.modifiedAt)
    }
}
