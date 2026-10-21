import Foundation
import IslandCore

final class DshTests {
    func cacheAndSessionState() throws {
        // A running session: an open turn, an open step, a pending question and a Cline Pass route.
        let running = cache(running: true, question: "call-1")
        let parsed = DshStore.parse(running, id: "session-abc", modified: Date())
        let session = try unwrap(parsed)
        expectEqual(session.project, "seacoffee")
        expectEqual(session.provider, "cline-pass")
        expectEqual(session.model, "cline-pass/deepseek-v4.1-flash")
        expectEqual(session.displayModel, "deepseek-v4.1-flash")
        expectEqual(session.running, true)
        expectEqual(session.openStep, 78)
        expectEqual(session.turns, 3)
        expectEqual(session.steps, 77)
        expectEqual(session.tokens, 11_091_355)
        expectEqual(Int((session.tokensPerSecond ?? 0).rounded()), 281)
        expectEqual(Int((session.averageFirstTokenMs ?? 0).rounded()), 8883)
        expectEqual(session.question, "call-1")
        expectEqual(session.lastPromptAt, Date(timeIntervalSince1970: 1_792_326_472.748))

        var state = SessionState(id: "dsh", agent: .dsh)
        state.consumeDsh(running, modified: Date())
        expectEqual(state.state, .running)
        expectEqual(state.project, "seacoffee")
        expectEqual(state.model, "cline-pass/deepseek-v4.1-flash")
        expectEqual(state.modelName, "deepseek-v4.1-flash")
        expectEqual(state.channelName, "Cline Pass")

        // A turn that ended is a completed one, and no longer waits on an answer.
        state.consumeDsh(cache(running: false), modified: Date().addingTimeInterval(5))
        expectEqual(state.state, .completed)
        expectEqual(state.awaitingAnswer, false)

        // A cache with no turn at all stays unknown rather than looking finished.
        var blank = SessionState(id: "blank", agent: .dsh)
        blank.consumeDsh(cache(running: false, turns: 0, steps: 0, tokens: false), modified: Date())
        expectEqual(blank.state, .unknown)

        // The question is announced once and keeps waiting while steps advance under it.
        var asked = SessionState(id: "q", agent: .dsh)
        asked.consumeDsh(running, modified: Date())
        expectEqual(asked.question?.id, "call-1")
        expectEqual(asked.awaitingAnswer, true)
        asked.consumeDsh(running, modified: Date().addingTimeInterval(2))
        expectEqual(asked.question?.id, "call-1")
        expectEqual(asked.awaitingAnswer, true)
        asked.consumeDsh(cache(running: true, steps: 80, question: "call-1"), modified: Date().addingTimeInterval(3))
        expectEqual(asked.awaitingAnswer, true)
        // The answer arrives: the next cache write no longer lists the call.
        asked.consumeDsh(cache(running: true, steps: 81), modified: Date().addingTimeInterval(4))
        expectEqual(asked.awaitingAnswer, false)
    }

    func storeAndMonitor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-abc.json")
        try cache(running: true).write(to: file)
        // Unrelated cache files are not sessions.
        try Data("{}".utf8).write(to: root.appendingPathComponent("session_projcache.json"))

        let since = Date().addingTimeInterval(-60)
        let sessions = DshStore.read(at: root, since: since)
        expectEqual(sessions.map(\.id), ["session-abc"])
        expectEqual(DshStore.read(at: root, since: Date().addingTimeInterval(60)).count, 0)

        var received: MonitorSnapshot?
        let monitor = SessionMonitor(sources: [SessionSource(agent: .dsh, path: root.path)]) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.count, 1)
        expectEqual(received?.sessions.first?.agent, .dsh)
        expectEqual(received?.sessions.first?.state, .running)
        expectEqual(received?.finished.count, 0)

        try cache(running: false).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        monitor.poll()
        expectEqual(received?.finished.map(\.agent), [.dsh])
        expectEqual(received?.sessions.first?.state, .completed)
        monitor.poll()
        expectEqual(received?.finished.count, 0, "Polling must not repeat the completion")
    }

    /// The harness rewrites the cache of every session it lists, including old ones. A cache that
    /// only now enters the two-day window must not announce a finish the monitor never watched.
    func rewrittenOldCacheDoesNotNotify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-old.json")
        var received: MonitorSnapshot?
        let monitor = SessionMonitor(sources: [SessionSource(agent: .dsh, path: root.path)]) { received = $0 }
        monitor.poll()
        expectEqual(received?.sessions.count, 0)

        // An old, already finished session whose cache was just rewritten: new to the monitor.
        try cache(running: false).write(to: file)
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .completed)
        expectEqual(received?.finished.count, 0, "A cache the monitor never saw running cannot finish")

        // A turn the monitor did watch: running first, then finished.
        try cache(running: true).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        monitor.poll()
        expectEqual(received?.sessions.first?.state, .running)
        try cache(running: false).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: file.path)
        monitor.poll()
        expectEqual(received?.finished.map(\.agent), [.dsh])
        monitor.poll()
        expectEqual(received?.finished.count, 0, "Polling must not repeat the completion")
    }

    /// A projection cache document shaped like DSH's: `{version, record: {identity, rows}}`, with
    /// versioned `{ver, seq, val}` row wrappers.
    private func cache(running: Bool, turns: Int = 3, steps: Int = 77, tokens: Bool = true,
                       question: String? = nil) -> Data {
        let active: [[String: Any]] = question.map { [["callId": $0, "state": "open",
                                                      "questions": [["id": "q1", "question": "继续吗"]]]] } ?? []
        let stats: [String: Any] = ["turns": turns, "steps": steps, "llmMs": 1_169_959, "toolMs": 166_795,
                                    "ttftMs": 657_349, "ttftSteps": 74, "decodeMs": 512_610, "decodeTokens": 144_040,
                                    "lastTurn": turns,
                                    "openStep": running ? ["turn": turns, "step": steps + 1,
                                                           "startTime": 1_792_326_495_377, "firstTokenTime": NSNull()] : NSNull(),
                                    "pendingCalls": [String: Any]()]
        let boundary: [String: Any] = ["openTurnStartSeq": running ? 5 : NSNull(), "lastStepStartSeq": 54,
                                       "lastStepBoundary": ["kind": running ? "start" : "end", "seq": 54], "lastTurn": turns]
        let totals: [String: Any] = ["uncachedInputTokens": tokens ? 445_506 : 0, "outputTokens": tokens ? 144_040 : 0,
                                     "cacheReadTokens": tokens ? 10_501_809 : 0, "cacheWriteTokens": 0]
        let record: [String: Any] = [
            "identity": ["formatVersion": 4, "createdAt": 1_790_406_308_423, "cwd": "/Users/example/seacoffee",
                         "isSeeded": false, "inheritedEventCount": 0],
            "rows": [
                "tokenUsage": ["ver": 2, "seq": 54, "val": ["totals": totals, "last": [String: Any]()]],
                "sessionStats": ["ver": 1, "seq": 54, "val": stats],
                "turnBoundary": ["ver": 2, "seq": 54, "val": boundary],
                "modelSelection": ["ver": 2, "seq": 54,
                                   "val": ["lastUsed": ["provider": "cline-pass", "model": "cline-pass/deepseek-v4.1-flash",
                                                        "reasoningEffort": "max"], "pending": NSNull()]],
                "userQuestions": ["ver": 2, "seq": 54, "val": ["timed": false, "questions": ["active": active, "settled": []]]],
                "sessionListMetadata": ["ver": 1, "seq": 54, "val": ["blank": false, "lastPromptAt": 1_792_326_472_748]]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: ["version": 7, "record": record])) ?? Data()
    }

    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure("expected a value") }
        return value
    }
    private struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
}
