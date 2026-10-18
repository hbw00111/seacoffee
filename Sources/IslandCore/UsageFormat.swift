import Foundation

/// Display formatters ported from CC Switch v4.0.6:
/// - countdown / resetText: src/components/quota/quotaRules.ts `countdownStr`, zh.json `subscription.resetsIn`
/// - relative / updatedText: src/components/quota/quotaRules.ts `formatRelativeTime`, zh.json `usage.*Ago`, `quota.updatedAt`
/// - tokens: src/components/usage/format.ts `formatTokensCompact`
/// - tokensPerSecond: src/components/usage/format.ts `formatTokensPerSecond`, zh.json `speedValue` / `speedEstimatedValue`
/// - rate: src/components/usage/statsColumns.tsx and UsageHero.tsx `toFixed(x >= 99.95 ? 0 : 1)`
/// - usd: src/components/usage/... `fmtUsd` style `$${num.toFixed(digits)}`
public enum UsageFormat {
    private static let hour = 3_600_000.0
    private static let minute = 60_000.0

    /// "3d12h" / "2h30m" / "45m", or nil when the date is missing or not in the future.
    /// Mirrors `countdownStr`: floors to whole minutes; days only when hours > 24, so exactly 24h shows "24h0m".
    public static func countdown(to date: Date, now: Date = Date()) -> String? {
        let diffMs = date.timeIntervalSince(now) * 1000
        guard diffMs.isFinite, diffMs > 0 else { return nil }
        let hours = Int(floor(diffMs / hour))
        let minutes = Int(floor(diffMs.truncatingRemainder(dividingBy: hour) / minute))
        if hours > 24 { return "\(hours / 24)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    /// "2h30m后重置"; nil when `countdown` is nil.
    public static func resetText(_ date: Date, now: Date = Date()) -> String? {
        countdown(to: date, now: now).map { "\($0)后重置" }
    }

    /// "刚刚" / "N 分钟前" / "N 小时前" / "N 天前". Seconds-based like quotaRules' `formatRelativeTime`;
    /// a future date (negative diff) reads as "刚刚".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let diff = Int(floor(now.timeIntervalSince(date)))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60) 分钟前" }
        if diff < 86400 { return "\(diff / 3600) 小时前" }
        return "\(diff / 86400) 天前"
    }

    /// "<relative>更新", e.g. "2 分钟前更新" (zh.json `quota.updatedAt`).
    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        relative(date, now: now) + "更新"
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// `formatTokensCompact`: below 10,000 the full number with "," grouping (Math.round, halves up);
    /// otherwise three significant digits with B / M / K ("48.2K", "189K", "1.5M").
    /// A value that rounds up to 1000 of a unit moves to the next unit ("999.95K" -> "1M").
    /// Negative values round halves toward +infinity like Math.round, but are not otherwise tested.
    public static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let abs = Swift.abs(value)
        if abs < 10_000 {
            let rounded = floor(value + 0.5)
            return grouping.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded))"
        }
        let units: [(size: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (index, unit) in units.enumerated() where abs >= unit.size {
            let scaled = sig3(value / unit.size)
            if Swift.abs(scaled) >= 1000 && index > 0 {
                let bigger = units[index - 1]
                return plain(sig3(value / bigger.size)) + bigger.suffix
            }
            return plain(scaled) + unit.suffix
        }
        return plain(value)
    }

    /// `formatTokensPerSecond` with the "tok/s" suffix from zh.json: "—" for nil or <= 0,
    /// one decimal below 1, integer (halves up) from 1. Estimated values get the "≈ " prefix
    /// from `speedEstimatedValue`.
    public static func tokensPerSecond(_ value: Double?, estimated: Bool = false) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        let number = value >= 1 ? toFixed(value, 0) : toFixed(value, 1)
        return estimated ? "≈ \(number) tok/s" : "\(number) tok/s"
    }

    /// Success / cache-hit rate. `fraction` is 0...1 and is clamped to 0...100%, as in UsageHero.
    /// Shows 0 decimals from 99.95% (so 99.96% reads "100%"), otherwise 1. nil or non-finite is "—".
    public static func rate(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        let percent = min(100, max(0, fraction * 100))
        return toFixed(percent, percent >= 99.95 ? 0 : 1) + "%"
    }

    /// "$" + `toFixed(decimals)`, no grouping. Non-finite values are "--" like `fmtUsd`'s fallback.
    public static func usd(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "--" }
        return "$" + toFixed(value, decimals)
    }

    /// JS `Number.prototype.toFixed` on the exact binary value. Halves round up in magnitude
    /// (JS picks the larger n on an exact tie), so 0.125 -> "0.13" and 0.25 -> "0.3" with one decimal.
    /// Values >= 1e21 are not handled (JS switches to exponent form there).
    static func toFixed(_ value: Double, _ digits: Int) -> String {
        // %.100f prints the exact decimal expansion of the double, so the digit after `digits` is exact.
        let text = String(format: "%.100f", Swift.abs(value))
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = Array(String(parts[1]))
        var digitsValue = Array((whole + String(fraction.prefix(digits))).utf8).map { Int($0) - 48 }
        if fraction[digits] >= "5" {
            var index = digitsValue.count - 1
            while index >= 0 && digitsValue[index] == 9 {
                digitsValue[index] = 0
                index -= 1
            }
            if index >= 0 { digitsValue[index] += 1 } else { digitsValue.insert(1, at: 0) }
        }
        let body = digitsValue.map(String.init).joined()
        let integerCount = body.count - digits
        let integerPart = body.prefix(integerCount)
        let sign = value < 0 ? "-" : ""
        return digits > 0 ? sign + integerPart + "." + body.suffix(digits) : sign + integerPart
    }

    /// `Number(x.toPrecision(3))`: three significant digits from the exact binary value, ties rounded up.
    /// Works on the decimal string (not on x * 10^k) so 11.35 (binary 11.349999...) gives 11.3 as in JS.
    private static func sig3(_ x: Double) -> Double {
        guard x != 0 else { return 0 }
        let text = String(format: "%.100e", Swift.abs(x))   // exact expansion: d.ddd...e+XX
        let parts = text.split(separator: "e")
        var exponent = Int(parts[1]) ?? 0
        var digits = parts[0].replacingOccurrences(of: ".", with: "").map { Int(String($0)) ?? 0 }
        var kept = Array(digits.prefix(3))
        if digits[3] >= 5 {
            var index = 2
            while index >= 0 && kept[index] == 9 {
                kept[index] = 0
                index -= 1
            }
            if index >= 0 { kept[index] += 1 } else { kept = [1, 0, 0]; exponent += 1 }
        }
        digits = kept
        let value = Double("\(digits[0]).\(digits[1])\(digits[2])e\(exponent)") ?? 0
        return x < 0 ? -value : value
    }

    /// JS number-to-string for values this file produces: integers without ".0".
    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
