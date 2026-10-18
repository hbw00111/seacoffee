import Foundation

public struct ModelPrice: Sendable, Equatable {
    public let modelID: String
    public let input, output, cacheRead, cacheWrite: Decimal   // USD per million tokens
    public init(modelID: String, input: Decimal, output: Decimal, cacheRead: Decimal, cacheWrite: Decimal) {
        self.modelID = modelID; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct CostBreakdown: Sendable, Equatable { public let input, output, cacheRead, cacheWrite, total: Decimal }

/// Port of CC Switch v4.0.6 `services/usage_stats.rs` pricing lookup and `proxy/usage/calculator.rs`.
/// String work is done on UTF-8 bytes to match Rust's byte-oriented `str` operations.
public enum ModelPricing {
    private typealias Bytes = [UInt8]
    private static let dash = UInt8(ascii: "-")

    public static func candidates(for model: String) -> [String] {
        let cleaned = clean(model)
        if isPlaceholder(cleaned) { return [] }
        var found: [Bytes] = []
        var stack: [Bytes] = [Bytes(cleaned.utf8)]
        while let candidate = stack.popLast() {
            if candidate.isEmpty || found.contains(candidate) { continue }
            found.append(candidate)
            if let s = stripNamespace(candidate) { stack.append(s) }
            if let s = stripDesktopPrefix(candidate) { stack.append(s) }
            if let s = stripBedrockVersion(candidate) { stack.append(s) }
            if let s = stripDate(candidate) { stack.append(s) }
            if let s = stripEffort(candidate) { stack.append(s) }
            if candidate.starts(with: Bytes("claude-".utf8)) && candidate.contains(UInt8(ascii: ".")) {
                stack.append(candidate.map { $0 == UInt8(ascii: ".") ? dash : $0 })
            }
        }
        return found.map { String(decoding: $0, as: UTF8.self) }
    }

    public static func isPlaceholder(_ model: String) -> Bool {
        let normalized = asciiLowercased(trimmed(model))
        return normalized.isEmpty || ["unknown", "null", "none"].contains(normalized)
    }

    public static func pricingKey(pricingModel: String?, model: String, requestModel: String?) -> String? {
        if let pricingModel, !isPlaceholder(pricingModel) { return pricingModel }
        if !isPlaceholder(model) { return model }
        guard let requestModel, requestModel != model, !isPlaceholder(requestModel) else { return nil }
        return requestModel
    }

    public static func find(_ model: String, in table: [String: ModelPrice]) -> ModelPrice? {
        let candidates = candidates(for: model)
        for candidate in candidates { if let price = table[candidate] { return price } }
        for candidate in candidates where shouldTryPrefix(Bytes(candidate.utf8)) {
            let pattern = Array((candidate + "-%").unicodeScalars)
            // SQLite leaves the order of equal-length rows unspecified; take the smallest model_id for determinism.
            let hit = table.filter { like(pattern, Array($0.key.unicodeScalars)) }.min {
                let (a, b) = ($0.key.unicodeScalars.count, $1.key.unicodeScalars.count)
                return a != b ? a < b : $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
            }
            if let hit { return hit.value }
        }
        return nil
    }

    public static func cost(app: String, semantics: Int, input: Decimal, output: Decimal, cacheRead: Decimal, cacheWrite: Decimal, price: ModelPrice, multiplier: Decimal) -> CostBreakdown {
        let inclusive = ["codex", "gemini", "grokbuild"].contains(app)
        let billable: Decimal
        if !inclusive || semantics == 2 { billable = input }
        else if semantics == 1 { billable = max(0, max(0, input - cacheRead) - cacheWrite) }
        else { billable = max(0, input - cacheRead) }
        let million = Decimal(1_000_000)
        let inputCost = billable * price.input / million
        let outputCost = output * price.output / million
        let readCost = cacheRead * price.cacheRead / million
        let writeCost = cacheWrite * price.cacheWrite / million
        return CostBreakdown(input: inputCost, output: outputCost, cacheRead: readCost, cacheWrite: writeCost,
                             total: (inputCost + outputCost + readCost + writeCost) * multiplier)
    }

    // MARK: - Cleaning

    private static func trimmed(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, f.properties.isWhitespace { scalars.removeFirst() }
        while let l = scalars.last, l.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    private static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }

    private static func clean(_ model: String) -> String {
        var s = Substring(model).unicodeScalars
        if let slash = s.lastIndex(of: "/") { s = s[s.index(after: slash)...] }
        if let colon = s.firstIndex(of: ":") { s = s[..<colon] }
        var bytes = Bytes(asciiLowercased(trimmed(String(s)).replacingOccurrences(of: "@", with: "-")).utf8)
        let marker = Bytes("[1m]".utf8)
        while bytes.count >= marker.count, bytes.suffix(marker.count).elementsEqual(marker) { bytes.removeLast(marker.count) }
        return trimmed(String(decoding: bytes, as: UTF8.self))
    }

    // MARK: - Candidate expansion (Bytes helpers)

    private static func lastRange(of needle: String, in b: Bytes) -> Int? {
        let n = Bytes(needle.utf8)
        guard b.count >= n.count else { return nil }
        for i in stride(from: b.count - n.count, through: 0, by: -1) where b[i..<(i + n.count)].elementsEqual(n) { return i }
        return nil
    }

    private static func stripNamespace(_ b: Bytes) -> Bytes? {
        if let pos = lastRange(of: "claude-", in: b), pos > 0 { return Bytes(b[pos...]) }
        for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.", "bedrock.", "global."] {
            let m = Bytes(marker.utf8)
            if b.starts(with: m) { return Bytes(b[m.count...]) }
        }
        return nil
    }

    private static let nonAnthropicMarkers = [
        "abab", "ark-code", "arctic", "astron", "codex", "command-r", "deepseek", "doubao", "ernie", "gemini", "gemma", "glm", "gpt",
        "grok", "hermes", "hy3", "hunyuan", "jamba", "kimi", "lfm", "llama", "longcat", "mercury", "mimo", "minimax", "mistral",
        "mixtral", "moonshot", "nemotron", "nova-", "openai", "qianfan", "qwen", "seed-", "solar", "stepfun",
    ].map { Bytes($0.utf8) }

    private static func stripDesktopPrefix(_ b: Bytes) -> Bytes? {
        let prefix = Bytes("claude-".utf8)
        guard b.starts(with: prefix) else { return nil }
        let rest = Bytes(b[prefix.count...])
        return nonAnthropicMarkers.contains { rest.starts(with: $0) } ? rest : nil
    }

    private static func isDigits(_ b: some Collection<UInt8>) -> Bool { b.allSatisfy { $0 >= 48 && $0 <= 57 } }

    private static func stripBedrockVersion(_ b: Bytes) -> Bytes? {
        guard let pos = lastRange(of: "-v", in: b) else { return nil }
        let base = Bytes(b[..<pos]), suffix = b[(pos + 2)...]
        return !base.isEmpty && !suffix.isEmpty && isDigits(suffix) ? base : nil
    }

    private static func stripDate(_ b: Bytes) -> Bytes? {
        if b.count > 11 {
            let s = Bytes(b[(b.count - 11)...])
            let isoDate = s[0] == dash && isDigits(s[1..<5]) && s[5] == dash && isDigits(s[6..<8]) && s[8] == dash && isDigits(s[9..<11])
            if isoDate { return Bytes(b[..<(b.count - 11)]) }
        }
        guard let pos = b.lastIndex(of: dash) else { return nil }
        let base = Bytes(b[..<pos]), suffix = Bytes(b[(pos + 1)...])
        guard !base.isEmpty, isDigits(suffix) else { return nil }
        if suffix.count == 8 { return base }
        if suffix.count == 6 {
            let month = Int(String(decoding: suffix[2..<4], as: UTF8.self)) ?? 0
            let day = Int(String(decoding: suffix[4..<6], as: UTF8.self)) ?? 0
            if (1...12).contains(month) && (1...31).contains(day) { return base }
        }
        return nil
    }

    private static func stripEffort(_ b: Bytes) -> Bytes? {
        for suffix in ["-minimal", "-low", "-medium", "-high", "-xhigh"] {
            let s = Bytes(suffix.utf8)
            if b.count > s.count, b.suffix(s.count).elementsEqual(s) { return Bytes(b[..<(b.count - s.count)]) }
        }
        return nil
    }

    private static func shouldTryPrefix(_ b: Bytes) -> Bool {
        let dashes = b.filter { $0 == dash }.count
        func has(_ p: String) -> Bool { b.starts(with: Bytes(p.utf8)) }
        if has("claude-") { return dashes >= 3 }
        if ["o1", "o3", "o4", "o5"].contains(where: has) { return dashes >= 1 }
        return ["gpt-", "gemini-", "deepseek-", "qwen-", "glm-", "kimi-", "minimax-"].contains(where: has) && dashes >= 2
    }

    // MARK: - SQLite LIKE (default: ASCII case-insensitive, `%` any run, `_` any one character, no ESCAPE)

    private static func fold(_ s: Unicode.Scalar) -> Unicode.Scalar {
        s.value >= 65 && s.value <= 90 ? Unicode.Scalar(s.value + 32)! : s
    }

    private static func like(_ p: [Unicode.Scalar], _ t: [Unicode.Scalar]) -> Bool {
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "%" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == "_" || fold(p[pi]) == fold(t[ti]) { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "%" { pi += 1 }
        return pi == p.count
    }
}
