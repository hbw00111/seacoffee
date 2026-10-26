import Foundation

public struct MonitorSnapshot: Sendable {
    public var sessions: [SessionState]
    public var finished: [SessionState]
    /// Sessions that put a new question to the user since the last scan.
    public var asked: [SessionState] = []
    public var message: String?
}

/// Where one agent keeps its sessions and how to read them.
public struct SessionSource: Sendable {
    public let agent: Agent
    public let root: URL
    /// A SQLite database (PI-Desktop) rather than a directory of session files.
    public let isDatabase: Bool
    public init(agent: Agent, path: String, isDatabase: Bool = false) {
        self.agent = agent
        self.isDatabase = isDatabase
        root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    public static func defaults(codexPath: String, enabled: Set<Agent> = Set(Agent.allCases)) -> [SessionSource] {
        let paths: [(Agent, String)] = [(.codex, codexPath), (.claude, "~/.claude/projects"),
                                        (.grok, "~/.grok/sessions"), (.cline, "~/.cline/data/sessions"),
                                        (.pi, "~/.pi/agent/sessions"),
                                        (.dsh, "~/.dsh/storages/session_projcache/sessions")]
        var sources = paths.filter { enabled.contains($0.0) }.map { SessionSource(agent: $0.0, path: $0.1) }
        // PI-Desktop shares the Pi toggle but stores sessions in its own database.
        if enabled.contains(.pi) { sources.append(SessionSource(agent: .pi, path: "~/.pi-desktop/pi.sqlite", isDatabase: true)) }
        return sources
    }

    /// Cline and DSH rewrite a small JSON document; everyone else appends JSON lines.
    var isSnapshot: Bool { agent == .cline || agent == .dsh }

    func accepts(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        switch agent {
        case .codex: return url.pathExtension == "jsonl"
        // Top-level transcripts, plus subagent transcripts that only keep their parent running.
        case .claude: return url.pathExtension == "jsonl" && (url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL || parentTranscript(of: url) != nil)
        case .grok: return name == "events.jsonl"
        case .pi: return url.pathExtension == "jsonl" && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        case .cline: return name.hasPrefix("session_") && name.hasSuffix(".json") && !name.hasSuffix(".messages.json")
        case .dsh: return name.hasPrefix("session-") && name.hasSuffix(".json")
        }
    }

    /// Claude Code writes each subagent to `<project>/<session>/subagents/*.jsonl`; this returns the
    /// path of the conversation it belongs to, `<project>/<session>.jsonl`.
    func parentTranscript(of url: URL) -> String? {
        guard agent == .claude, url.pathExtension == "jsonl", url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        let session = url.deletingLastPathComponent().deletingLastPathComponent()
        let project = session.deletingLastPathComponent()
        guard project.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return nil }
        return project.appendingPathComponent(session.lastPathComponent + ".jsonl").standardizedFileURL.path
    }

    func newState(for url: URL) -> SessionState {
        // Codex rollout names are unique; other agents reuse file names (Grok's are all events.jsonl).
        var state = SessionState(id: agent == .codex ? url.lastPathComponent : "\(agent.rawValue):\(url.path)", agent: agent)
        if agent == .grok {
            // Grok names the project folder after the percent-encoded working directory.
            let folder = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if let cwd = folder.removingPercentEncoding, !cwd.isEmpty { state.project = URL(fileURLWithPath: cwd).lastPathComponent }
        }
        return state
    }

    func consume(_ line: Data, into state: inout SessionState) {
        switch agent {
        case .codex: state.consume(line)
        case .claude: state.consumeClaude(line, sidechain: false)
        case .grok: state.consumeGrok(line)
        case .pi: state.consumePi(line)
        case .cline, .dsh: break
        }
    }

    /// A whole document rewritten in place, read only when its modification date moves.
    func consumeSnapshot(_ data: Data, modified: Date, into state: inout SessionState) {
        switch agent {
        case .dsh: state.consumeDsh(data, modified: modified)
        case .cline: state.consumeCline(data, modified: modified)
        default: break
        }
    }
}

public final class SessionMonitor: @unchecked Sendable {
    private struct Cursor {
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var pending = Data()
        var state: SessionState
        /// Set for a Claude subagent: the main transcript it keeps running.
        var parent: String?
    }
    private let queue = DispatchQueue(label: "com.seacoffee.SeaIsland.telemetry", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cursors: [URL: Cursor] = [:]
    private var firstScan = true
    private let launchedAt = Date()
    /// Completions held back while background subagents still work, by transcript path.
    private var deferred: [String: String] = [:]
    /// A subagent silent for this long no longer keeps its conversation running.
    private let subagentSilence: TimeInterval = 900
    private let sources: [SessionSource]
    private let callback: (MonitorSnapshot) -> Void

    public init(sources: [SessionSource], callback: @escaping (MonitorSnapshot) -> Void) {
        self.sources = sources
        self.callback = callback
    }
    public convenience init(path: String, callback: @escaping (MonitorSnapshot) -> Void) {
        self.init(sources: [SessionSource(agent: .codex, path: path)], callback: callback)
    }
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }
    public func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }

    private func read(_ url: URL, source: SessionSource, cursor: inout Cursor) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size < cursor.offset { cursor = Cursor(state: source.newState(for: url)) }
        guard size > cursor.offset else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound initial work for long histories. Incremental reads keep incomplete lines.
        var skipFirst = false
        if size - cursor.offset > 4 * 1024 * 1024 {
            cursor.offset = size - 4 * 1024 * 1024; cursor.pending = Data(); skipFirst = true
        }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        cursor.offset += UInt64(data.count)
        cursor.pending.append(data)
        while let newline = cursor.pending.firstIndex(of: 10) {
            let line = Data(cursor.pending[..<newline])
            cursor.pending.removeSubrange(...newline)
            if skipFirst { skipFirst = false; continue }
            if cursor.parent != nil { cursor.state.consumeClaude(line, sidechain: true) } else { source.consume(line, into: &cursor.state) }
        }
        if cursor.pending.count > 1024 * 1024 { cursor.pending = Data() }
    }

    public func poll() { queue.sync { scan() } }

    private func scan() {
        let fm = FileManager.default
        let present = sources.filter { fm.fileExists(atPath: $0.root.path) }
        guard !present.isEmpty else {
            callback(MonitorSnapshot(sessions: [], finished: [], message: "尚未找到会话目录")); return
        }
        let now = Date()
        var finished: [SessionState] = []
        var completions: [(path: String, state: SessionState)] = []
        var asked: [SessionState] = []
        var readFailure = false
        var allowed = Set<URL>()
        for source in present {
            if source.isDatabase {
                guard let turns = PiDesktopStore.latestTurns(at: source.root, since: now.addingTimeInterval(-172800)) else {
                    // A locked or migrating database is skipped for this poll, keeping the last states.
                    allowed.formUnion(cursors.keys.filter { $0.scheme == "pi-desktop" }); continue
                }
                for turn in turns {
                    guard let key = URL(string: "pi-desktop:\(turn.sessionID)") else { continue }
                    var cursor = cursors[key] ?? Cursor(state: SessionState(id: "pi-desktop:\(turn.sessionID)", agent: source.agent))
                    let oldTransition = cursor.state.transitionID
                    cursor.state.consumePiDesktop(turn)
                    if !firstScan, oldTransition != cursor.state.transitionID,
                       [.completed, .failed, .interrupted].contains(cursor.state.state), cursor.state.updatedAt >= launchedAt {
                        finished.append(cursor.state)
                    }
                    cursors[key] = cursor
                    allowed.insert(key)
                }
                continue
            }
            // A resumed conversation continues writing to its original creation-date folder.
            // Discover by modification time across the tree, not by folder date.
            var found: [(URL, Date)] = []
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            let files = fm.enumerator(at: source.root, includingPropertiesForKeys: keys,
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = files?.nextObject() as? URL {
                guard source.accepts(url),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let date = values.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(date) < 172800 { found.append((url, date)) }
            }
            let selected = Array(found.sorted { $0.1 > $1.1 }.prefix(100))
            allowed.formUnion(selected.map(\.0))
            for (url, modified) in selected {
                do {
                    let parent = source.parentTranscript(of: url)
                    var cursor = cursors[url] ?? Cursor(state: source.newState(for: url), parent: parent)
                    let oldTransition = cursor.state.transitionID
                    let oldQuestion = cursor.state.question?.id
                    if source.isSnapshot {
                        if modified != cursor.modified {
                            let data = try Data(contentsOf: url)
                            guard data.count < 4 * 1024 * 1024 else { continue }
                            source.consumeSnapshot(data, modified: modified, into: &cursor.state)
                        }
                    } else {
                        try read(url, source: source, cursor: &cursor)
                    }
                    cursor.modified = modified
                    if parent != nil || cursor.state.auxiliary { cursors[url] = cursor; continue }
                    // Only a finish this monitor watched counts: DSH rewrites the cache of every
                    // session it lists, so an aged-out cache that comes back would otherwise
                    // announce work that ended days ago.
                    if !firstScan, !oldTransition.isEmpty, oldTransition != cursor.state.transitionID,
                       [.completed, .failed, .interrupted].contains(cursor.state.state), cursor.state.updatedAt >= launchedAt {
                        if cursor.state.state == .completed {
                            completions.append((url.standardizedFileURL.path, cursor.state))
                        } else {
                            finished.append(cursor.state)
                        }
                    }
                    // Only a fresh question that still needs the user: not one answered within this scan,
                    // and not an old unanswered one found when a long-idle file is read again.
                    if !firstScan, let question = cursor.state.question, question.id != oldQuestion, !question.answered,
                       question.askedAt >= launchedAt, now.timeIntervalSince(question.askedAt) < 300 {
                        asked.append(cursor.state)
                    }
                    cursors[url] = cursor
                } catch { readFailure = true }
            }
        }
        cursors = cursors.filter { allowed.contains($0.key) }
        firstScan = false

        // Background subagents keep working after the main turn ends: the conversation stays
        // running, and its completion is announced once they are done.
        var busy: [String: Date] = [:]
        for cursor in cursors.values {
            guard let parent = cursor.parent, cursor.state.state == .running,
                  now.timeIntervalSince(cursor.state.updatedAt) < subagentSilence else { continue }
            busy[parent] = max(busy[parent] ?? .distantPast, cursor.state.updatedAt)
        }
        for completion in completions {
            if busy[completion.path] != nil { deferred[completion.path] = completion.state.transitionID } else { finished.append(completion.state) }
        }
        let mains = Dictionary(cursors.filter { $0.value.parent == nil }.map { ($0.key.standardizedFileURL.path, $0.value.state) }) { a, _ in a }
        for (path, transition) in deferred where busy[path] == nil {
            deferred[path] = nil
            if let state = mains[path], state.state == .completed, state.transitionID == transition { finished.append(state) }
        }

        var states = cursors.filter { $0.value.parent == nil && !$0.value.state.auxiliary }.map { url, cursor -> SessionState in
            var state = cursor.state
            if let active = busy[url.standardizedFileURL.path], state.state != .running {
                state.state = .running
                state.updatedAt = max(state.updatedAt, active)
            }
            return state
        }
        for index in states.indices where states[index].state == .running && now.timeIntervalSince(states[index].updatedAt) > 2700 {
            states[index].state = .unknown // Silence is never interpreted as successful completion.
        }
        states.sort { $0.updatedAt > $1.updatedAt }
        callback(MonitorSnapshot(sessions: states, finished: finished, asked: asked, message: readFailure ? "部分会话文件暂不可读" : nil))
    }
}
