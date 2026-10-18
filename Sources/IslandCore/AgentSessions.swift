import Foundation

/// A local coding agent whose task state Sea Coffee follows from its own session files.
extension SessionState {
    /// Model name without a routing prefix: `deepseek/deepseek-v4.1-flash` → `deepseek-v4.1-flash`.
    public var modelName: String? {
        model.flatMap { $0.split(separator: "/").last.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// A subscription the model was routed through, when its prefix names one Sea Coffee tracks
    /// (Pi records Cline Pass models as `cline-pass/glm-5.3-flash`).
    public var channelName: String? {
        guard let model, let slash = model.firstIndex(of: "/") else { return nil }
        switch model[..<slash].lowercased() {
        case "cline-pass", "clinepass": return "Cline Pass"
        default: return nil
        }
    }
}

public enum Agent: String, CaseIterable, Sendable {
    case codex, claude, grok, cline, pi, dsh
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        case .cline: return "Cline"
        case .pi: return "Pi"
        case .dsh: return "DSH"
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
        // A new turn or an ended one leaves nobody waiting on an earlier question.
        question?.answered = true
    }
    private mutating func activity(at time: Date) {
        if state == .running { updatedAt = time }
    }
    /// Records a question once; split records of one call repeat the same id.
    mutating func ask(_ id: String, at time: Date, blocking: Bool) {
        guard question?.id != id else { return }
        question = Question(id: id, askedAt: time, blocking: blocking)
    }

    /// Lines Claude Code writes for local slash commands (`/context`, `/compact`) and `!` shell
    /// commands. They are recorded as user messages but never start a model turn.
    private static let claudeLocalCommandPrefixes = ["<command-name>", "<command-message>", "<command-args>",
        "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]

    /// Claude Code: `~/.claude/projects/<project>/<session>.jsonl`. A subagent's own transcript
    /// (`<session>/subagents/*.jsonl`) is read with `sidechain: true`, since all its lines are sidechain.
    public mutating func consumeClaude(_ line: Data, sidechain: Bool = false) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              sidechain || object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              // `/compact` writes its summary as a user message; it never starts a turn.
              object["isCompactSummary"] as? Bool != true,
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
                if let asked = question?.id, blocks?.contains(where: { $0["tool_use_id"] as? String == asked }) == true {
                    question?.answered = true
                }
                activity(at: time)
            } else if !texts.isEmpty, texts.allSatisfy({ text in
                let head = text.drop { $0.isWhitespace }
                return Self.claudeLocalCommandPrefixes.contains { head.hasPrefix($0) }
            }) {
                // A prompt-style command still starts a turn: its first assistant line marks it running.
                break
            } else if !texts.isEmpty || blocks?.isEmpty == false {
                transition(.running, "prompt:\(time.timeIntervalSince1970)", at: time)
            }
        case "assistant":
            // Error placeholders are written as "<synthetic>", not a real model.
            if let name = message?["model"] as? String, !name.isEmpty, !name.hasPrefix("<") { model = name }
            let id = message?["id"] as? String ?? "\(time.timeIntervalSince1970)"
            let tools = (message?["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil } ?? []
            switch message?["stop_reason"] as? String {
            case "end_turn", "stop_sequence": transition(.completed, "end_turn:\(id)", at: time)
            // A subagent ends by handing its report back rather than with end_turn.
            case _ where sidechain && tools.contains("SubagentHandback"): transition(.completed, "handback:\(id)", at: time)
            case "refusal": transition(.failed, "refusal:\(id)", at: time)
            default:
                // Tool calls and streamed blocks mean work is still in progress.
                if state == .running { updatedAt = time } else { transition(.running, "assistant:\(id)", at: time) }
            }
            // Recorded after the state change above, which would mark an earlier question answered.
            if let call = (message?["content"] as? [[String: Any]])?.first(where: {
                $0["type"] as? String == "tool_use" && $0["name"] as? String == "AskUserQuestion" }),
               let callID = call["id"] as? String {
                ask(callID, at: time, blocking: true)
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

    /// Pi (CLI and PI-Desktop): `~/.pi/agent/sessions/--<escaped cwd>--/<time>_<id>.jsonl`.
    public mutating func consumePi(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let time = UsageDecoder.date(object["timestamp"]), time >= updatedAt else { return }
        switch object["type"] as? String {
        case "session":
            if let cwd = object["cwd"] as? String, !cwd.isEmpty { project = URL(fileURLWithPath: cwd).lastPathComponent }
        case "message":
            guard let message = object["message"] as? [String: Any] else { return }
            let key = "\(object["id"] as? String ?? ""):\(time.timeIntervalSince1970)"
            switch message["role"] as? String {
            case "user": transition(.running, "user:" + key, at: time)
            case "assistant":
                if let name = message["model"] as? String, !name.isEmpty { model = name }
                switch message["stopReason"] as? String {
                case "stop", "length": transition(.completed, "stop:" + key, at: time)
                case "aborted": transition(.interrupted, "aborted:" + key, at: time)
                case "error": transition(.failed, "error:" + key, at: time)
                default: if state == .running { updatedAt = time } else { transition(.running, "tool:" + key, at: time) }
                }
            default: activity(at: time) // tool results
            }
        default: break
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

    /// DSH: `~/.dsh/storages/session_projcache/sessions/session-<id>.json`, the harness's own
    /// projection of the session log, rewritten whole every 200 events or 5 seconds.
    public mutating func consumeDsh(_ data: Data, modified: Date) {
        guard let session = DshStore.parse(data, id: "", modified: modified) else { return }
        if !session.project.isEmpty { project = session.project }
        if let name = session.model, !name.isEmpty { model = name }
        let time = max(modified, updatedAt)
        // A turn that ended is a completed one; DSH records no outcome beyond the boundary.
        let next: RunState = session.running ? .running : session.turns > 0 ? .completed : .unknown
        let key = "dsh:\(session.turns):\(session.steps):\(session.running)"
        if next != state { transition(next, key, at: time) } else { activity(at: time) }
        // `transition` above marks an earlier question answered; an open one is still waiting.
        if let call = session.question {
            if question?.id == call { question?.answered = false } else { ask(call, at: time, blocking: true) }
        } else if question?.answered == false {
            // The cache no longer lists the call: it was answered or dismissed while the turn went on.
            question?.answered = true
        }
    }
}
