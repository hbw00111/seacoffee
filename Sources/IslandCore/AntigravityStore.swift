import Foundation
import SQLite3

/// Antigravity (the `agy` CLI and the desktop app) lists its conversations in
/// `~/.gemini/antigravity-cli/conversation_summaries.db` and `~/.gemini/antigravity/…`, one row
/// per conversation with a live run status. Only status, times and workspace folders are
/// selected — never the title, preview or search index, which hold conversation text. Each
/// conversation's own database (`conversations/<id>.db`) is opened only for its model name.
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
        // A skipped poll is retried two seconds later.
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }
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

    /// The model behind a conversation's latest turn, e.g. `gemini-4-hydrogen-medium`, from
    /// `<folder>/conversations/<id>.db`. Only the newest `executor_metadata` row is read — the
    /// turn's run configuration — and only its model name is kept; steps, prompts and the
    /// generation log are never selected. Nil when no turn has been recorded or it is unreadable.
    public static func model(under root: URL, conversation id: String) -> String? {
        // Ids are UUIDs; anything else must not become a path.
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let candidates = folders.map { root.appendingPathComponent($0).appendingPathComponent("conversations").appendingPathComponent(id + ".db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
        for url in candidates {
            if let blob = latestExecutorMetadata(url), let name = model(fromExecutorMetadata: blob) { return name }
        }
        return nil
    }

    private static func modified(_ url: URL) -> Date {
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.modificationDate]) as? Date
        let main = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return max(wal ?? .distantPast, main ?? .distantPast)
    }

    private static func latestExecutorMetadata(_ url: URL) -> Data? {
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM executor_metadata ORDER BY idx DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    /// The run configuration's model: protobuf field 10 → 1 → 28.
    public static func model(fromExecutorMetadata data: Data) -> String? {
        guard let raw = ProtobufText.string(in: data, path: [10, 1, 28]) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 80, !name.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return name
    }

    /// Read-only, never waiting on Antigravity's writer and never leaving files in its folder.
    private static func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        // Without a `-wal` file nobody is writing. Opening such a WAL database read-only would
        // create `-wal` and `-shm` files in Antigravity's folder; `immutable` reads it untouched.
        let idle = !FileManager.default.fileExists(atPath: url.path + "-wal")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(path)?mode=ro" + (idle ? "&immutable=1" : "")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        // A skipped read is retried on the next state change.
        sqlite3_busy_timeout(db, 150)
        return db
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
    /// `model` looks up the latest turn's model; it is asked on first sight and on each state
    /// change, not on every poll, since it opens the conversation's own database.
    public mutating func consumeAntigravity(_ conversation: AntigravityStore.Conversation, model: () -> String? = { nil }) {
        if let project = conversation.project { self.project = project }
        let firstSight = updatedAt == .distantPast
        let next: RunState
        switch conversation.status {
        case "CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING": next = .running
        // A conversation returns to idle after each turn; one first seen idle has no known outcome.
        case "CASCADE_RUN_STATUS_IDLE":
            next = state != .running ? state : transitionID.hasPrefix("canceling:") ? .interrupted : .completed
        default: next = .unknown
        }
        let canceling = conversation.status == "CASCADE_RUN_STATUS_CANCELING"
        let changed = next != state
        if changed || (canceling && !transitionID.hasPrefix("canceling:")) {
            state = next
            transitionID = "\(canceling ? "canceling" : next.rawValue):\(conversation.modifiedAt.timeIntervalSince1970)"
        }
        // A turn can switch models; the one that ran it is read again as it ends.
        if firstSight || changed, let name = model() { self.model = name }
        updatedAt = max(updatedAt, conversation.modifiedAt)
    }
}

/// Just enough protobuf wire-format reading to pull one string out of a nested message.
enum ProtobufText {
    /// The first length-delimited field at `path` that holds valid UTF-8; nil on malformed input.
    static func string(in data: Data, path: [Int]) -> String? {
        guard let field = path.first else { return nil }
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]; index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint(), key >> 3 > 0 else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                let payload = Data(bytes[index..<index + Int(length)])
                index += Int(length)
                guard key >> 3 == UInt64(field) else { continue }
                if path.count == 1 {
                    if let text = String(data: payload, encoding: .utf8) { return text }
                } else if let found = string(in: payload, path: Array(path.dropFirst())) {
                    return found
                }
            default: return nil
            }
            if index > bytes.count { return nil }
        }
        return nil
    }
}
