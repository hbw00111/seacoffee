import Foundation
import Darwin

public struct QuotaHistoryPoint: Codable, Identifiable, Sendable {
    public struct Window: Codable, Sendable {
        public let id: String, label: String
        public let remaining: Double, limit: Double
        public let resetsAt: Date?
        public var percent: Double { min(100, max(0, remaining / limit * 100)) }
    }
    public let provider: String
    public let date: Date
    public let balance: Double?
    public let windows: [Window]
    public var id: String { "\(provider):\(Int(date.timeIntervalSince1970 / 900))" }
    public init(provider: String, usage: UsageSnapshot) {
        self.provider = provider; date = usage.fetchedAt; balance = usage.balance
        windows = usage.quotas.filter { $0.limit.isFinite && $0.limit > 0 && $0.remaining.isFinite }.map {
            Window(id: $0.id, label: $0.label, remaining: $0.remaining, limit: $0.limit, resetsAt: $0.resetsAt)
        }
    }
}

/// Stores numeric quota snapshots only. Each 15-minute bucket keeps its latest observation.
public actor QuotaHistoryStore {
    private let url: URL
    public static var defaultURL: URL { CredentialFile.applicationSupport.url.deletingLastPathComponent().appendingPathComponent("quota-history.json") }
    public init(url: URL = defaultURL) { self.url = url }
    public func read() throws -> [QuotaHistoryPoint] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([QuotaHistoryPoint].self, from: Data(contentsOf: url))
    }
    public func record(provider: String, usage: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Standalone app and Droppy may briefly overlap while restarting.
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        let point = QuotaHistoryPoint(provider: provider, usage: usage)
        var points = try read().filter { $0.date >= usage.fetchedAt.addingTimeInterval(-31 * 86400) }
        if let index = points.firstIndex(where: { $0.id == point.id }) {
            guard points[index].date < point.date else { return }
            points[index] = point
        } else { points.append(point) }
        points.sort { $0.date < $1.date }
        let data = try JSONEncoder().encode(points)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
