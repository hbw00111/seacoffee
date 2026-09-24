public enum QuotaLevel: Sendable, Equatable {
    case unknown, healthy, warning, low

    public init(fraction: Double?) {
        guard let fraction, fraction.isFinite else { self = .unknown; return }
        // Match the rounded percentage shown inside the ring at the boundaries.
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        self = percent >= 50 ? .healthy : percent >= 20 ? .warning : .low
    }
}
