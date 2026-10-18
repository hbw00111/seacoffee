import Foundation

/// One DSH session, read from the harness's own projection cache.
///
/// DSH (`dsh web`, `dsh headless`) keeps the compressed event log under
/// `~/.dsh/sessions/--<cwd>--/session-<id>/session.v4.jsonl.zstd` and rewrites a plain JSON
/// projection of each session to `~/.dsh/storages/session_projcache/sessions/session-<id>.json`.
/// The projection is throttled (`writeEveryEvents: 200`, `writeIntervalMs: 5000`), so the numbers
/// can trail the event log by a few seconds. Only counters, timings and labels are read; the
/// projection carries prompt text, which is never touched here.
public struct DshSession: Sendable, Identifiable, Equatable {
    public let id: String
    public let project: String
    public let provider: String?
    /// As DSH records it, routing prefix included (`cline-pass/deepseek-v4.1-flash`).
    public let model: String?
    public let createdAt: Date
    /// The last prompt the harness recorded, not the file's modification time: a cold cache read
    /// rewrites old rows without meaning the session ran again.
    public let lastPromptAt: Date
    /// A turn is open in the harness right now.
    public let running: Bool
    /// The step in flight while `running`.
    public let openStep: Int?
    public let turns: Int
    public let steps: Int
    public let uncachedInput: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    /// Model time, tool time and first-token time are DSH's own whole-session folds.
    public let llmMs: Double
    public let toolMs: Double
    public let ttftMs: Double
    public let ttftSteps: Int
    /// Output tokens and the decode span they were produced in.
    public let decodeMs: Double
    public let decodeTokens: Double
    /// Call id of an `ask_user_question` batch still waiting for an answer.
    public let question: String?

    public var tokens: Double { uncachedInput + output + cacheRead + cacheWrite }
    /// Output tokens per second over the measured decode span.
    public var tokensPerSecond: Double? {
        decodeMs >= 100 && decodeTokens > 0 ? decodeTokens / (decodeMs / 1000) : nil
    }
    public var averageFirstTokenMs: Double? { ttftSteps > 0 ? ttftMs / Double(ttftSteps) : nil }
    /// Model name without its routing prefix, for display.
    public var displayModel: String? {
        model.flatMap { $0.split(separator: "/").last.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum DshStore {
    public static var defaultRoot: URL {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        return home.appendingPathComponent("storages/session_projcache/sessions")
    }

    /// Sessions whose cache was written since `since`, newest activity first.
    public static func read(at root: URL = defaultRoot, since: Date) -> [DshSession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var sessions: [DshSession] = []
        for name in names where name.hasPrefix("session-") && name.hasSuffix(".json") {
            let url = root.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified >= since,
                  (values.fileSize ?? 0) < 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let session = parse(data, id: String(name.dropLast(5)), modified: modified) else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.lastPromptAt > $1.lastPromptAt }
    }

    /// One `record` document. Rows are versioned `{ver, seq, val}` wrappers; only `val` is read.
    public static func parse(_ data: Data, id: String, modified: Date) -> DshSession? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else { return nil }
        func value(_ key: String) -> [String: Any]? { (rows[key] as? [String: Any])?["val"] as? [String: Any] }
        func count(_ value: Any?) -> Int { Int(UsageDecoder.number(value) ?? 0) }
        func millis(_ value: Any?) -> Date? {
            guard let ms = UsageDecoder.number(value), ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        let identity = record["identity"] as? [String: Any] ?? [:]
        let stats = value("sessionStats") ?? [:]
        let tokenUsage = value("tokenUsage")
        let totals = tokenUsage?["totals"] as? [String: Any] ?? [:]
        let boundary = value("turnBoundary") ?? [:]
        let lastUsed = value("modelSelection")?["lastUsed"] as? [String: Any]
        let active = ((value("userQuestions")?["questions"] as? [String: Any])?["active"] as? [[String: Any]])?.first
        let openStep = stats["openStep"] as? [String: Any]
        let created = millis(identity["createdAt"]) ?? modified
        let prompt = millis(value("sessionListMetadata")?["lastPromptAt"]) ?? created
        let cwd = identity["cwd"] as? String ?? ""

        return DshSession(
            id: id,
            project: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            provider: lastUsed?["provider"] as? String,
            model: lastUsed?["model"] as? String,
            createdAt: created,
            lastPromptAt: max(created, prompt),
            // A turn stays open until `turn/end`; a step stays open until its message assembles.
            running: UsageDecoder.number(boundary["openTurnStartSeq"]) != nil || openStep != nil,
            openStep: openStep.flatMap { UsageDecoder.number($0["step"]).map { Int($0) } },
            turns: count(stats["turns"]),
            steps: count(stats["steps"]),
            uncachedInput: UsageDecoder.number(totals["uncachedInputTokens"]) ?? 0,
            output: UsageDecoder.number(totals["outputTokens"]) ?? 0,
            cacheRead: UsageDecoder.number(totals["cacheReadTokens"]) ?? 0,
            cacheWrite: UsageDecoder.number(totals["cacheWriteTokens"]) ?? 0,
            llmMs: UsageDecoder.number(stats["llmMs"]) ?? 0,
            toolMs: UsageDecoder.number(stats["toolMs"]) ?? 0,
            ttftMs: UsageDecoder.number(stats["ttftMs"]) ?? 0,
            ttftSteps: count(stats["ttftSteps"]),
            decodeMs: UsageDecoder.number(stats["decodeMs"]) ?? 0,
            decodeTokens: UsageDecoder.number(stats["decodeTokens"]) ?? 0,
            question: active?["callId"] as? String
        )
    }
}
