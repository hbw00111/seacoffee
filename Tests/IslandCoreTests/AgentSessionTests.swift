import Foundation
import IslandCore

final class AgentSessionTests {
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func claude(_ type: String, at time: String, _ message: [String: Any], extra: [String: Any] = [:]) -> Data {
        json(["type": type, "timestamp": time, "cwd": "/Users/example/seacoffee", "message": message].merging(extra) { $1 })
    }

    func claudeTurns() {
        var s = SessionState(id: "c", agent: .claude)
        expectEqual(s.project, "Claude Code")
        s.consumeClaude(claude("user", at: "2026-09-26T03:00:00Z", ["role": "user", "content": "fix the bug"]))
        expectEqual(s.state, .running)
        expectEqual(s.project, "seacoffee")
        s.consumeClaude(claude("assistant", at: "2026-09-26T03:00:05Z", ["id": "m1", "model": "claude-opus-5-5", "stop_reason": "tool_use", "content": [["type": "tool_use"]]]))
        expectEqual(s.modelName, "claude-opus-5-5")
        s.consumeClaude(claude("user", at: "2026-09-26T03:00:09Z", ["content": [["type": "tool_result", "content": "ok"]]]))
        expectEqual(s.state, .running, "tool calls and results keep the turn running")
        expectEqual(s.updatedAt, UsageDecoder.date("2026-09-26T03:00:09Z"))
        // Subagent transcripts and meta lines never end the parent turn.
        s.consumeClaude(claude("assistant", at: "2026-09-26T03:00:10Z", ["id": "side", "stop_reason": "end_turn"], extra: ["isSidechain": true]))
        s.consumeClaude(claude("user", at: "2026-09-26T03:00:10Z", ["content": "<command>"], extra: ["isMeta": true]))
        expectEqual(s.state, .running)
        s.consumeClaude(claude("assistant", at: "2026-09-26T03:00:12Z", ["id": "m2", "stop_reason": "end_turn", "content": [["type": "thinking"]]]))
        expectEqual(s.state, .completed)
        let finished = s.transitionID
        s.consumeClaude(claude("assistant", at: "2026-09-26T03:00:12Z", ["id": "err", "model": "<synthetic>", "stop_reason": "end_turn"]))
        expectEqual(s.modelName, "claude-opus-5-5", "error placeholders are not a model")
        s.consumeClaude(claude("assistant", at: "2026-09-26T03:00:12Z", ["id": "m2", "stop_reason": "end_turn", "content": [["type": "text"]]]))
        expectEqual(s.transitionID, finished, "split blocks of one message complete once")
        s.consumeClaude(claude("user", at: "2026-09-26T03:01:00Z", ["content": [["type": "text", "text": "again"]]]))
        s.consumeClaude(claude("user", at: "2026-09-26T03:01:04Z", ["content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]))
        expectEqual(s.state, .interrupted)
        s.consumeClaude(claude("user", at: "2026-09-26T02:00:00Z", ["content": "older"]))
        expectEqual(s.state, .interrupted, "out-of-order lines are ignored")
        s.consumeClaude(Data("not json".utf8))
        expectEqual(s.state, .interrupted)
    }

    func grokTurns() {
        var s = SessionState(id: "g", agent: .grok)
        s.consumeGrok(json(["type": "turn_started", "ts": "2026-09-25T12:00:00.000Z", "turn_number": 0, "model_id": "grok-4.6"]))
        expectEqual(s.modelName, "grok-4.6")
        expectEqual(s.state, .running)
        s.consumeGrok(json(["type": "tool_started", "ts": "2026-09-25T12:00:03.000Z"]))
        expectEqual(s.updatedAt, UsageDecoder.date("2026-09-25T12:00:03.000Z"))
        s.consumeGrok(json(["type": "turn_ended", "ts": "2026-09-25T12:01:00.000Z", "outcome": "completed"]))
        expectEqual(s.state, .completed)
        s.consumeGrok(json(["type": "turn_started", "ts": "2026-09-25T12:02:00.000Z"]))
        s.consumeGrok(json(["type": "turn_ended", "ts": "2026-09-25T12:02:30.000Z", "outcome": "cancelled", "cancellation_category": "mid_turn_abort"]))
        expectEqual(s.state, .interrupted)
        s.consumeGrok(json(["type": "turn_started", "ts": "2026-09-25T12:03:00.000Z"]))
        s.consumeGrok(json(["type": "turn_ended", "ts": "2026-09-25T12:03:30.000Z", "outcome": "error"]))
        expectEqual(s.state, .failed)
    }

    func piTurns() {
        func pi(_ time: String, _ message: [String: Any]) -> Data {
            json(["type": "message", "id": UUID().uuidString, "timestamp": time, "message": message])
        }
        var s = SessionState(id: "p", agent: .pi)
        s.consumePi(json(["type": "session", "version": 3, "timestamp": "2026-09-22T09:08:58.266Z", "cwd": "/Users/example/notes"]))
        expectEqual(s.project, "notes")
        expectEqual(s.state, .unknown)
        s.consumePi(pi("2026-09-22T09:09:00.000Z", ["role": "user", "content": [["type": "text"]]]))
        expectEqual(s.state, .running)
        s.consumePi(pi("2026-09-22T09:09:05.000Z", ["role": "assistant", "provider": "cline-pass-vmissla",
                                                    "model": "cline-pass/glm-5.3-flash", "stopReason": "toolUse"]))
        s.consumePi(pi("2026-09-22T09:09:09.000Z", ["role": "toolResult", "content": [["type": "text"]]]))
        expectEqual(s.state, .running)
        expectEqual(s.updatedAt, UsageDecoder.date("2026-09-22T09:09:09.000Z"))
        s.consumePi(pi("2026-09-22T09:09:20.000Z", ["role": "assistant", "model": "cline-pass/glm-5.3-flash", "stopReason": "stop"]))
        expectEqual(s.state, .completed)
        expectEqual(s.modelName, "glm-5.3-flash")
        expectEqual(s.channelName, "Cline Pass", "Pi routes Cline Pass models through a cline-pass/ prefix")
        s.consumePi(pi("2026-09-22T09:10:00.000Z", ["role": "user"]))
        s.consumePi(pi("2026-09-22T09:10:03.000Z", ["role": "assistant", "stopReason": "aborted"]))
        expectEqual(s.state, .interrupted)
        s.consumePi(pi("2026-09-22T09:11:00.000Z", ["role": "user"]))
        s.consumePi(pi("2026-09-22T09:11:03.000Z", ["role": "assistant", "model": "gpt-6-sol", "stopReason": "error"]))
        expectEqual(s.state, .failed)
        expectNil(s.channelName)
        var other = SessionState(id: "x", agent: .cline)
        other.model = "deepseek/deepseek-v4.1-flash"
        // Only subscriptions Sea Coffee tracks are named as a channel.
        expectNil(other.channelName)
    }

    func clineStatuses() {
        var s = SessionState(id: "l", agent: .cline)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        s.consumeCline(json(["status": "idle", "cwd": "/Users/example/app", "model": "deepseek/deepseek-v4.1-flash"]), modified: t0)
        expectEqual(s.model, "deepseek/deepseek-v4.1-flash")
        expectEqual(s.modelName, "deepseek-v4.1-flash", "routing prefix is dropped for display")
        expectEqual(s.state, .unknown, "an idle session seen at launch has no known outcome")
        expectEqual(s.project, "app")
        s.consumeCline(json(["status": "running"]), modified: t0 + 5)
        expectEqual(s.state, .running)
        s.consumeCline(json(["status": "pending"]), modified: t0 + 8)
        expectEqual(s.state, .running)
        expectEqual(s.updatedAt, t0 + 8)
        s.consumeCline(json(["status": "idle"]), modified: t0 + 10)
        expectEqual(s.state, .completed, "running back to idle is a finished answer")
        s.consumeCline(json(["status": "running"]), modified: t0 + 20)
        s.consumeCline(json(["status": "cancelled"]), modified: t0 + 21)
        expectEqual(s.state, .interrupted)
        s.consumeCline(json(["status": "error"]), modified: t0 + 30)
        expectEqual(s.state, .failed)
        s.consumeCline(json(["nostatus": true]), modified: t0 + 40)
        expectEqual(s.state, .failed)
    }

    func monitorsAllAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let claudeRoot = root.appendingPathComponent("claude"), grokRoot = root.appendingPathComponent("grok")
        let clineRoot = root.appendingPathComponent("cline")
        let project = claudeRoot.appendingPathComponent("-Users-example-web")
        try fm.createDirectory(at: project.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try (claude("user", at: now, ["content": "hi"]) + Data([10])).write(to: project.appendingPathComponent("s1.jsonl"))
        // A subagent transcript must not count as a separate conversation.
        try (claude("user", at: now, ["content": "sub"]) + Data([10])).write(to: project.appendingPathComponent("s1/subagents/a.jsonl"))
        let grokSession = grokRoot.appendingPathComponent("%2FUsers%2Fexample%2Fapi/0001")
        try fm.createDirectory(at: grokSession, withIntermediateDirectories: true)
        try (json(["type": "turn_started", "ts": now]) + Data([10])).write(to: grokSession.appendingPathComponent("events.jsonl"))
        try Data("{}".utf8).write(to: grokSession.appendingPathComponent("summary.json"))
        let clineSession = clineRoot.appendingPathComponent("session_1")
        try fm.createDirectory(at: clineSession, withIntermediateDirectories: true)
        try json(["status": "running", "cwd": "/Users/example/cli"]).write(to: clineSession.appendingPathComponent("session_1.json"))
        try Data("[]".utf8).write(to: clineSession.appendingPathComponent("session_1.messages.json"))

        var received: MonitorSnapshot?
        let monitor = SessionMonitor(sources: [SessionSource(agent: .claude, path: claudeRoot.path),
                                               SessionSource(agent: .grok, path: grokRoot.path),
                                               SessionSource(agent: .cline, path: clineRoot.path),
                                               SessionSource(agent: .codex, path: root.appendingPathComponent("missing").path)]) { received = $0 }
        monitor.poll()
        let sessions = received?.sessions ?? []
        expectEqual(sessions.count, 3)
        expectEqual(Set(sessions.map(\.agent)), [.claude, .grok, .cline])
        expectEqual(Set(sessions.map(\.state)), [.running])
        // Claude takes the project from each line's cwd; Grok decodes its folder name.
        expectEqual(Set(sessions.map(\.project)), ["seacoffee", "api", "cli"])

        try json(["status": "idle", "cwd": "/Users/example/cli"]).write(to: clineSession.appendingPathComponent("session_1.json"))
        let later = Date().addingTimeInterval(5)
        try fm.setAttributes([.modificationDate: later], ofItemAtPath: clineSession.appendingPathComponent("session_1.json").path)
        monitor.poll()
        expectEqual(received?.finished.map(\.agent), [.cline])
        expectEqual(received?.finished.first?.state, .completed)
    }
}
