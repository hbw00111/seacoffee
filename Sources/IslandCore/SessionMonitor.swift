import Foundation

public struct MonitorSnapshot: Sendable {
    public var sessions: [SessionState]
    public var finished: [SessionState]
    public var message: String?
}

/// Where one agent keeps its sessions and how to read them.
public struct SessionSource: Sendable {
    public let agent: Agent
    public let root: URL
    public init(agent: Agent, path: String) {
        self.agent = agent
        root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    public static func defaults(codexPath: String, enabled: Set<Agent> = Set(Agent.allCases)) -> [SessionSource] {
        let paths: [(Agent, String)] = [(.codex, codexPath), (.claude, "~/.claude/projects"),
                                        (.grok, "~/.grok/sessions"), (.cline, "~/.cline/data/sessions")]
        return paths.filter { enabled.contains($0.0) }.map { SessionSource(agent: $0.0, path: $0.1) }
    }

    /// Cline rewrites a small JSON document; everyone else appends JSON lines.
    var isSnapshot: Bool { agent == .cline }

    func accepts(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        switch agent {
        case .codex: return url.pathExtension == "jsonl"
        // Top-level transcripts only; subagent transcripts live one level deeper.
        case .claude: return url.pathExtension == "jsonl" && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        case .grok: return name == "events.jsonl"
        case .cline: return name.hasPrefix("session_") && name.hasSuffix(".json") && !name.hasSuffix(".messages.json")
        }
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
        case .claude: state.consumeClaude(line)
        case .grok: state.consumeGrok(line)
        case .cline: break
        }
    }
}

public final class SessionMonitor: @unchecked Sendable {
    private struct Cursor {
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var pending = Data()
        var state: SessionState
    }
    private let queue = DispatchQueue(label: "com.seacoffee.SeaIsland.telemetry", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cursors: [URL: Cursor] = [:]
    private var firstScan = true
    private let launchedAt = Date()
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
            source.consume(line, into: &cursor.state)
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
        var readFailure = false
        var allowed = Set<URL>()
        for source in present {
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
                    var cursor = cursors[url] ?? Cursor(state: source.newState(for: url))
                    let oldTransition = cursor.state.transitionID
                    if source.isSnapshot {
                        if modified != cursor.modified {
                            let data = try Data(contentsOf: url)
                            guard data.count < 4 * 1024 * 1024 else { continue }
                            cursor.state.consumeCline(data, modified: modified)
                        }
                    } else {
                        try read(url, source: source, cursor: &cursor)
                    }
                    cursor.modified = modified
                    if !firstScan, oldTransition != cursor.state.transitionID,
                       [.completed, .failed, .interrupted].contains(cursor.state.state), cursor.state.updatedAt >= launchedAt {
                        finished.append(cursor.state)
                    }
                    cursors[url] = cursor
                } catch { readFailure = true }
            }
        }
        cursors = cursors.filter { allowed.contains($0.key) }
        firstScan = false
        var states = cursors.values.map(\.state)
        for index in states.indices where states[index].state == .running && now.timeIntervalSince(states[index].updatedAt) > 2700 {
            states[index].state = .unknown // Silence is never interpreted as successful completion.
        }
        states.sort { $0.updatedAt > $1.updatedAt }
        callback(MonitorSnapshot(sessions: states, finished: finished, message: readFailure ? "部分会话文件暂不可读" : nil))
    }
}
