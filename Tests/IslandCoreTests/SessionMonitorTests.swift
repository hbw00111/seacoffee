import Foundation
import IslandCore

final class SessionMonitorTests {
    func testIncrementalWritesCompletionDeduplicationAndNoHistoricalNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-fixture.jsonl")
        let old = line("task_complete", at: Date().addingTimeInterval(-60))
        try old.write(to: file)
        var received: [MonitorSnapshot] = []
        let monitor = SessionMonitor(path: root.path) { received.append($0) }
        monitor.poll()
        expectEqual(received.last?.sessions.first?.state, .completed)
        expectEqual(received.last?.finished.count, 0, "Historical completions should never interrupt the user")

        let start = line("task_started", at: Date().addingTimeInterval(1))
        try append(start, to: file)
        monitor.poll()
        expectEqual(received.last?.sessions.first?.state, .running)

        let complete = line("task_complete", at: Date().addingTimeInterval(2))
        try append(complete.prefix(complete.count / 2), to: file)
        monitor.poll()
        expectEqual(received.last?.sessions.first?.state, .running, "A partial line cannot end a task")
        try append(complete.suffix(complete.count - complete.count / 2), to: file)
        monitor.poll()
        expectEqual(received.last?.finished.count, 1)
        expectEqual(received.last?.finished.first?.state, .completed)

        monitor.poll()
        expectEqual(received.last?.finished.count, 0, "Polling must not repeat notifications")
        try append(complete, to: file)
        monitor.poll()
        expectEqual(received.last?.finished.count, 0, "Duplicate event must not repeat notifications")
    }

    func testTruncatedFileAndStaleRunningState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jsonl")
        try line("task_started", at: Date().addingTimeInterval(-3600)).write(to: file)
        var received: MonitorSnapshot?
        let monitor = SessionMonitor(path: root.path) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .unknown)
        expectEqual(received?.finished.count, 0)
        try Data().write(to: file)
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .unknown)
        try append(line("task_started", at: Date().addingTimeInterval(1)), to: file)
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .running)
    }

    func testResumedOldConversationSurvivesOtherConversationCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldFolder = root.appendingPathComponent("2020/01/01")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldConversation = oldFolder.appendingPathComponent("resumed.jsonl")
        let otherConversation = root.appendingPathComponent("other.jsonl")
        try line("task_started", at: Date()).write(to: oldConversation)
        try line("task_started", at: Date()).write(to: otherConversation)
        var received: MonitorSnapshot?
        let monitor = SessionMonitor(path: root.path) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.filter { $0.state == .running }.count, 2)
        expectEqual(received?.finished.count, 0)

        try append(line("task_complete", at: Date().addingTimeInterval(1)), to: otherConversation)
        monitor.poll()
        expectEqual(received?.finished.count, 1)
        expectEqual(received?.sessions.filter { $0.state == .running }.map(\.id), ["resumed.jsonl"])
        monitor.poll()
        expectEqual(received?.finished.count, 0)
        expectEqual(received?.sessions.filter { $0.state == .running }.count, 1)

        // Restart must rediscover the old conversation without an in-memory cursor.
        let restarted = SessionMonitor(path: root.path) { received = $0 }
        restarted.poll()
        expectEqual(received?.sessions.filter { $0.state == .running }.count, 1)
        expectEqual(received?.finished.count, 0)
        try append(line("task_complete", at: Date().addingTimeInterval(2)), to: oldConversation)
        restarted.poll()
        expectEqual(received?.sessions.filter { $0.state == .running }.count, 0)
        expectEqual(received?.finished.map(\.id), ["resumed.jsonl"])
    }

    private func line(_ kind: String, at date: Date) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: date))\",\"payload\":{\"type\":\"\(kind)\"}}\n".utf8)
    }
    private func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
}
