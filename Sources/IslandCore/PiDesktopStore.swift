import Foundation
import SQLite3

/// PI-Desktop keeps its sessions in `~/.pi-desktop/pi.sqlite` instead of Pi's JSONL files.
/// Each turn row carries its own status, so the latest turn per session is the session's state.
/// The database is opened read-only (never `immutable`, so fresh WAL pages are seen), and only
/// status, times, model and project name are selected — never message content.
public enum PiDesktopStore {
    public struct Turn: Equatable, Sendable {
        public let sessionID: String
        public let turnID: String
        public let status: String
        public let model: String?
        public let startedAt: Date
        public let endedAt: Date?
        /// Last activity in the session; keeps a long-running turn from looking silent.
        public let sessionUpdatedAt: Date
        public let project: String?
    }

    public static func latestTurns(at url: URL, since: Date, limit: Int = 100) -> [Turn]? {
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        // Never wait on PI-Desktop's writer; a skipped poll is retried two seconds later.
        sqlite3_busy_timeout(db, 150)
        let sql = """
            SELECT s.id, t.id, t.status, t.model_id, t.started_at, t.ended_at, s.updated_at, p.path, p.name
            FROM turns t
            JOIN sessions s ON s.id = t.session_id
            LEFT JOIN projects p ON p.id = s.project_id
            WHERE s.deleted_at IS NULL AND t.started_at >= ?1
              AND t.started_at = (SELECT MAX(started_at) FROM turns WHERE session_id = s.id)
            ORDER BY t.started_at DESC LIMIT ?2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        sqlite3_bind_int(statement, 2, Int32(limit))
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, column)) / 1000)
        }
        var turns: [Turn] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let session = text(0), let turn = text(1), let status = text(2), let started = date(4) else { continue }
            let project = text(8) ?? text(7).map { URL(fileURLWithPath: $0).lastPathComponent }
            turns.append(Turn(sessionID: session, turnID: turn, status: status, model: text(3), startedAt: started,
                              endedAt: date(5), sessionUpdatedAt: date(6) ?? started, project: project))
        }
        return turns
    }
}

extension SessionState {
    public mutating func consumePiDesktop(_ turn: PiDesktopStore.Turn) {
        if let project = turn.project { self.project = project }
        if let name = turn.model { model = name }
        let next: RunState
        switch turn.status {
        case "running": next = .running
        case "completed": next = .completed
        case "aborted", "cancelled": next = .interrupted
        case "error", "failed": next = .failed
        default: next = .unknown
        }
        let key = "\(turn.turnID):\(turn.status)"
        let time = next == .running ? max(turn.startedAt, turn.sessionUpdatedAt) : (turn.endedAt ?? turn.sessionUpdatedAt)
        if transitionID != key { state = next; transitionID = key }
        updatedAt = max(updatedAt, time)
    }
}
