import Foundation
import IslandCore

final class UsageFormatTests {
    func formatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func later(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }

        // countdown: floor to minutes, days only when hours > 24 (so exactly 24h is "24h0m")
        expectNil(UsageFormat.countdown(to: now, now: now))
        expectNil(UsageFormat.countdown(to: later(-1), now: now))
        expectEqual(UsageFormat.countdown(to: later(0.001), now: now), "0m", "countdown 1ms")
        expectEqual(UsageFormat.countdown(to: later(59.999), now: now), "0m", "countdown just under 1m")
        expectEqual(UsageFormat.countdown(to: later(60), now: now), "1m", "countdown 1m")
        expectEqual(UsageFormat.countdown(to: later(45 * 60), now: now), "45m", "countdown 45m")
        expectEqual(UsageFormat.countdown(to: later(2 * 3600 + 30 * 60), now: now), "2h30m", "countdown 2h30m")
        expectEqual(UsageFormat.countdown(to: later(24 * 3600), now: now), "24h0m", "countdown exactly 24h")
        expectEqual(UsageFormat.countdown(to: later(25 * 3600), now: now), "1d1h", "countdown 25h")
        expectEqual(UsageFormat.countdown(to: later(48 * 3600), now: now), "2d0h", "countdown 48h")
        expectEqual(UsageFormat.countdown(to: later(3 * 86400 + 12 * 3600 + 59), now: now), "3d12h", "countdown 3d12h (seconds dropped)")

        // resetText: "<countdown>后重置"
        expectNil(UsageFormat.resetText(now, now: now))
        expectEqual(UsageFormat.resetText(later(2 * 3600 + 30 * 60), now: now), "2h30m后重置", "resetText 2h30m")
        expectEqual(UsageFormat.resetText(later(3 * 86400 + 12 * 3600), now: now), "3d12h后重置", "resetText 3d12h")

        // relative: seconds-based, "刚刚" below one minute, a space before the unit
        expectEqual(UsageFormat.relative(now, now: now), "刚刚", "relative 0s")
        expectEqual(UsageFormat.relative(later(-30), now: now), "刚刚", "relative future date")
        expectEqual(UsageFormat.relative(later(-59.9), now: now), "刚刚", "relative 59.9s")
        expectEqual(UsageFormat.relative(later(-60), now: now), "1 分钟前", "relative 1m")
        expectEqual(UsageFormat.relative(later(-3599), now: now), "59 分钟前", "relative 59m59s")
        expectEqual(UsageFormat.relative(later(-3600), now: now), "1 小时前", "relative 1h")
        expectEqual(UsageFormat.relative(later(-86399), now: now), "23 小时前", "relative 23h59m")
        expectEqual(UsageFormat.relative(later(-86400), now: now), "1 天前", "relative 1d")
        expectEqual(UsageFormat.relative(later(-3 * 86400 - 5), now: now), "3 天前", "relative 3d")

        // updatedText: "<relative>更新" with no space
        expectEqual(UsageFormat.updatedText(now, now: now), "刚刚更新", "updatedText now")
        expectEqual(UsageFormat.updatedText(later(-120), now: now), "2 分钟前更新", "updatedText 2m")

        // tokens: full grouped number below 10,000 (Math.round, halves up), else 3 significant digits
        expectEqual(UsageFormat.tokens(0), "0", "tokens 0")
        expectEqual(UsageFormat.tokens(999), "999", "tokens 999")
        expectEqual(UsageFormat.tokens(1234), "1,234", "tokens grouping")
        expectEqual(UsageFormat.tokens(9999.4), "9,999", "tokens 9999.4")
        expectEqual(UsageFormat.tokens(9999.5), "10,000", "tokens half rounds up into grouping")
        expectEqual(UsageFormat.tokens(10_000), "10K", "tokens 10K")
        expectEqual(UsageFormat.tokens(12_345), "12.3K", "tokens 12.345K")
        expectEqual(UsageFormat.tokens(12_250), "12.3K", "tokens exact tie rounds up")
        expectEqual(UsageFormat.tokens(11_350), "11.3K", "tokens 11.35K is binary-below half")
        expectEqual(UsageFormat.tokens(48_200), "48.2K", "tokens 48.2K")
        expectEqual(UsageFormat.tokens(100_000), "100K", "tokens 100K")
        expectEqual(UsageFormat.tokens(189_000), "189K", "tokens 189K")
        expectEqual(UsageFormat.tokens(999_400), "999K", "tokens 999.4K")
        expectEqual(UsageFormat.tokens(999_949), "1M", "tokens 999.949K carries into M")
        expectEqual(UsageFormat.tokens(1_000_000), "1M", "tokens 1M")
        expectEqual(UsageFormat.tokens(1_500_000), "1.5M", "tokens 1.5M")
        expectEqual(UsageFormat.tokens(18_200_000), "18.2M", "tokens 18.2M")
        expectEqual(UsageFormat.tokens(1_000_000_000), "1B", "tokens 1B")
        expectEqual(UsageFormat.tokens(999_999_999), "1B", "tokens 999.999M carries into B")
        expectEqual(UsageFormat.tokens(1_234_567_890), "1.23B", "tokens 1.23B")

        // tokensPerSecond: "—" for nil or <= 0; one decimal below 1; integer from 1; "≈ " when estimated
        expectEqual(UsageFormat.tokensPerSecond(nil), "—", "tps nil")
        expectEqual(UsageFormat.tokensPerSecond(0), "—", "tps zero")
        expectEqual(UsageFormat.tokensPerSecond(-3), "—", "tps negative")
        expectEqual(UsageFormat.tokensPerSecond(nil, estimated: true), "—", "tps nil estimated has no prefix")
        expectEqual(UsageFormat.tokensPerSecond(0.04), "0.0 tok/s", "tps 0.04")
        expectEqual(UsageFormat.tokensPerSecond(0.25), "0.3 tok/s", "tps tie rounds up")
        expectEqual(UsageFormat.tokensPerSecond(0.95), "0.9 tok/s", "tps 0.95 is binary-below half")
        expectEqual(UsageFormat.tokensPerSecond(1), "1 tok/s", "tps 1")
        expectEqual(UsageFormat.tokensPerSecond(1.5), "2 tok/s", "tps 1.5 rounds up")
        expectEqual(UsageFormat.tokensPerSecond(2.5), "3 tok/s", "tps 2.5 rounds up")
        expectEqual(UsageFormat.tokensPerSecond(42), "42 tok/s", "tps 42")
        expectEqual(UsageFormat.tokensPerSecond(123.4), "123 tok/s", "tps 123.4")
        expectEqual(UsageFormat.tokensPerSecond(12.34, estimated: true), "≈ 12 tok/s", "tps estimated")

        // rate: clamp to 0...100, 0 decimals from 99.95%, otherwise 1 decimal; nil is "—"
        expectEqual(UsageFormat.rate(nil), "—", "rate nil")
        expectEqual(UsageFormat.rate(.nan), "—", "rate nan")
        expectEqual(UsageFormat.rate(0), "0.0%", "rate 0")
        expectEqual(UsageFormat.rate(-0.1), "0.0%", "rate clamps below 0")
        expectEqual(UsageFormat.rate(0.5), "50.0%", "rate 50%")
        expectEqual(UsageFormat.rate(0.0625), "6.3%", "rate 6.25 tie rounds up")
        expectEqual(UsageFormat.rate(0.99), "99.0%", "rate 99%")
        expectEqual(UsageFormat.rate(0.9949), "99.5%", "rate 99.49 rounds to 99.5")
        expectEqual(UsageFormat.rate(0.9996), "100%", "rate 99.96 switches to 0 decimals")
        expectEqual(UsageFormat.rate(1), "100%", "rate 100%")
        expectEqual(UsageFormat.rate(1.2), "100%", "rate clamps above 100%")

        // usd: "$" + toFixed, no grouping; non-finite falls back to "--"
        expectEqual(UsageFormat.usd(1.5, decimals: 2), "$1.50", "usd 2 decimals")
        expectEqual(UsageFormat.usd(0.1, decimals: 2), "$0.10", "usd pads zeros")
        expectEqual(UsageFormat.usd(0.125, decimals: 2), "$0.13", "usd exact tie rounds up")
        expectEqual(UsageFormat.usd(0.005, decimals: 2), "$0.01", "usd 0.005 is binary-above half")
        expectEqual(UsageFormat.usd(12.3456, decimals: 0), "$12", "usd 0 decimals")
        expectEqual(UsageFormat.usd(1234.5, decimals: 2), "$1234.50", "usd no grouping")
        expectEqual(UsageFormat.usd(.nan, decimals: 2), "--", "usd nan")
    }
}
