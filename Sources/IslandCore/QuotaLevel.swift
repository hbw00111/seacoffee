public enum QuotaLevel: Sendable, Equatable {
    case unknown, healthy, warning, low

    public init(fraction: Double?) {
        guard let fraction, fraction.isFinite else { self = .unknown; return }
        // CC Switch: normal above 20% left, orange below, red once used up. Boundaries follow the
        // rounded percentage shown next to the ring.
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        self = percent >= 20 ? .healthy : percent > 0 ? .warning : .low
    }
}
