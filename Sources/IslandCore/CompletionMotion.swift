import Foundation

/// Shared frame clock for the live island and the exported preview.
public struct CompletionMotion: Sendable {
    public static let duration: TimeInterval = 3.3
    public static let reducedDuration: TimeInterval = 1.35
    public let elapsed: Double
    public let reduced: Bool
    public init(elapsed: Double, reduced: Bool = false) {
        self.elapsed = max(0, elapsed); self.reduced = reduced
    }
    private func progress(_ start: Double, _ duration: Double) -> Double {
        min(1, max(0, (elapsed - start) / duration))
    }
    private func smooth(_ start: Double, _ duration: Double) -> Double {
        let p = progress(start, duration)
        return p * p * (3 - 2 * p)
    }
    public var returning: Bool { !reduced && elapsed >= 2.85 }
    public var mergeProgress: Double { reduced ? 1 : smooth(0, 0.62) * (1 - smooth(2.85, 0.45)) }
    public var contentOpacity: Double { reduced ? 0 : returning ? smooth(3.06, 0.24) : 1 - smooth(0, 0.16) }
    public var glyphOpacity: Double { reduced ? 1 : smooth(0.48, 0.18) * (1 - smooth(2.83, 0.16)) }
    /// Y-axis rotation, never a flat rotation around the screen's Z axis.
    public var rotation: Double {
        guard !reduced else { return 0 }
        let p = progress(0.78, 1.12)
        return 720 * (1 - pow(1 - p, 2))
    }
    public var spinningOpacity: Double { reduced ? 0 : smooth(0.48, 0.16) * (1 - smooth(1.76, 0.18)) }
    public var checkProgress: Double { reduced ? 1 : smooth(1.84, 0.26) }
    public var settled: Bool { reduced || elapsed >= 2.10 }
    public var scale: Double {
        reduced ? 1 : 1 + sin(progress(1.90, 0.40) * .pi) * 0.045
    }
}
