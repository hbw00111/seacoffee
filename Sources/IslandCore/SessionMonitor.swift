import Foundation

public struct MonitorSnapshot: Sendable {
    public var sessions: [SessionState]
    public var finished: [SessionState]
    public var message: String?
}

public final class SessionMonitor: @unchecked Sendable {
    private struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var state: SessionState
    }
    private let queue = DispatchQueue(label: "com.seacoffee.SeaIsland.telemetry", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cursors: [URL: Cursor] = [:]
    private var firstScan = true
    private let launchedAt = Date()
    private var root: URL
    private let callback: (MonitorSnapshot) -> Void

    public init(path: String, callback: @escaping (MonitorSnapshot) -> Void) {
        root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        self.callback = callback
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

    public func poll() { queue.sync { scan() } }

    private func scan() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            callback(MonitorSnapshot(sessions: [], finished: [], message: "尚未找到 Codex 会话目录")); return
        }
        let now = Date()
        // A resumed conversation continues writing to its original creation-date folder.
        // Discover by modification time across the tree, not by folder date.
        var found: [(URL, Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) < 172800 { found.append((url, date)) }
        }
        let selected = Array(found.sorted { $0.1 > $1.1 }.prefix(100))
        let allowed = Set(selected.map(\.0))
        cursors = cursors.filter { allowed.contains($0.key) }
        var finished: [SessionState] = []
        var readFailure = false
        for (url, _) in selected {
            do {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                var cursor = cursors[url] ?? Cursor(state: SessionState(id: url.lastPathComponent))
                let oldTransition = cursor.state.transitionID
                if size < cursor.offset { cursor = Cursor(state: SessionState(id: url.lastPathComponent)) }
                if size > cursor.offset {
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
                        cursor.state.consume(line)
                    }
                    if cursor.pending.count > 1024 * 1024 { cursor.pending = Data() }
                }
                if !firstScan, oldTransition != cursor.state.transitionID,
                   [.completed, .failed, .interrupted].contains(cursor.state.state), cursor.state.updatedAt >= launchedAt {
                    finished.append(cursor.state)
                }
                cursors[url] = cursor
            } catch { readFailure = true }
        }
        firstScan = false
        var states = cursors.values.map(\.state)
        for index in states.indices where states[index].state == .running && now.timeIntervalSince(states[index].updatedAt) > 2700 {
            states[index].state = .unknown // Silence is never interpreted as successful completion.
        }
        states.sort { $0.updatedAt > $1.updatedAt }
        callback(MonitorSnapshot(sessions: states, finished: finished, message: readFailure ? "部分会话文件暂不可读" : nil))
    }
}
