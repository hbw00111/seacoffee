import Foundation

/// A local coding agent whose task state Sea Coffee follows from its own session files.
extension SessionState {
    /// Model name without a routing prefix: `deepseek/deepseek-v4.1-flash` → `deepseek-v4.1-flash`.
    public var modelName: String? {
        model.flatMap { $0.split(separator: "/").last.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum Agent: String, CaseIterable, Sendable {
    case codex, claude, grok, cline
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        case .cline: return "Cline"
        }
    }
}

// Each agent writes a different format. Only event metadata, the project folder name and
// timestamps are kept; prompts and answers are inspected transiently and never stored.
extension SessionState {
    private mutating func transition(_ next: RunState, _ key: String, at time: Date) {
        // Split records of one message repeat the same terminal event.
        if state == next && transitionID == key { return }
        state = next; transitionID = key; updatedAt = time
    }
    private mutating func activity(at time: Date) {
        if state == .running { updatedAt = time }
    }

    /// Claude Code: `~/.claude/projects/<project>/<session>.jsonl`.
    public mutating func consumeClaude(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let time = UsageDecoder.date(object["timestamp"]), time >= updatedAt else { return }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { project = URL(fileURLWithPath: cwd).lastPathComponent }
        let message = object["message"] as? [String: Any]
        switch object["type"] as? String {
        case "user":
            let blocks = message?["content"] as? [[String: Any]]
            let texts = blocks?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                ?? [message?["content"] as? String].compactMap { $0 }
            if texts.contains(where: { $0.hasPrefix("[Request interrupted by user") }) {
                transition(.interrupted, "interrupted:\(time.timeIntervalSince1970)", at: time)
            } else if blocks?.contains(where: { $0["type"] as? String == "tool_result" }) == true {
                activity(at: time)
            } else if !texts.isEmpty || blocks?.isEmpty == false {
                transition(.running, "prompt:\(time.timeIntervalSince1970)", at: time)
            }
        case "assistant":
            // Error placeholders are written as "<synthetic>", not a real model.
            if let name = message?["model"] as? String, !name.isEmpty, !name.hasPrefix("<") { model = name }
            let id = message?["id"] as? String ?? "\(time.timeIntervalSince1970)"
            switch message?["stop_reason"] as? String {
            case "end_turn", "stop_sequence": transition(.completed, "end_turn:\(id)", at: time)
            case "refusal": transition(.failed, "refusal:\(id)", at: time)
            default:
                // Tool calls and streamed blocks mean work is still in progress.
                if state == .running { updatedAt = time } else { transition(.running, "assistant:\(id)", at: time) }
            }
        default: break
        }
    }

    /// Grok CLI: `~/.grok/sessions/<encoded cwd>/<session>/events.jsonl`.
    public mutating func consumeGrok(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = object["type"] as? String,
              let time = UsageDecoder.date(object["ts"]), time >= updatedAt else { return }
        let key = "\(kind):\(time.timeIntervalSince1970)"
        switch kind {
        case "turn_started":
            if let name = object["model_id"] as? String, !name.isEmpty { model = name }
            transition(.running, key, at: time)
        case "turn_ended":
            switch object["outcome"] as? String {
            case "completed": transition(.completed, key, at: time)
            case "cancelled": transition(.interrupted, key, at: time)
            case "error", "failed": transition(.failed, key, at: time)
            default: transition(.unknown, key, at: time)
            }
        default: activity(at: time)
        }
    }

    /// Cline CLI: `~/.cline/data/sessions/<id>/<id>.json`, rewritten whole on each change.
    public mutating func consumeCline(_ data: Data, modified: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { project = URL(fileURLWithPath: cwd).lastPathComponent }
        if let name = object["model"] as? String, !name.isEmpty { model = name }
        let time = max(modified, updatedAt)
        let next: RunState
        switch status {
        case "starting", "running", "pending", "stopping": next = .running
        case "completed": next = .completed
        // An interactive session returns to idle after each answer.
        case "idle": next = state == .running ? .completed : state
        case "cancelled": next = .interrupted
        case "failed", "error": next = .failed
        default: next = .unknown
        }
        if next != state { transition(next, "\(status):\(time.timeIntervalSince1970)", at: time) }
        else { activity(at: time) }
    }
}
