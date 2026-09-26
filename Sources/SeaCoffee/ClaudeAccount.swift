import Foundation
import IslandCore

/// Reads Claude Code's existing login. Nothing is written back to Claude Code's
/// Keychain item or file, and the token is kept in memory only.
@MainActor
final class ClaudeAccount: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var enabled: Bool
    @Published private(set) var plan: String?
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    private var credentials: ClaudeCredentials?
    private var lastAttempt = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var task: Task<Void, Never>?
    // The usage endpoint rate-limits aggressive polling; two minutes keeps the ring fresh enough.
    private let minimumInterval: TimeInterval = 120
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.bool(forKey: "claudeEnabled")
    }

    /// User action: may show the macOS Keychain dialog for Claude Code's item.
    func connect() {
        enabled = true
        UserDefaults.standard.set(true, forKey: "claudeEnabled")
        credentials = nil
        refresh(allowInteraction: true)
    }

    func disconnect() {
        task?.cancel()
        enabled = false; credentials = nil; plan = nil
        UserDefaults.standard.set(false, forKey: "claudeEnabled")
        onDisconnect?()
        onStatus?("已停止读取 Claude Code 登录")
    }

    func refresh(allowInteraction: Bool = false) {
        guard enabled, !busy else { return }
        let now = Date()
        if !allowInteraction {
            guard now >= blockedUntil, now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        }
        lastAttempt = now; busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                var current = try await loadCredentials(allowInteraction: allowInteraction)
                do { try await fetchUsage(current) }
                catch ClaudeError.signedOut {
                    // Claude Code may have rotated the token since we cached it.
                    credentials = nil
                    current = try await loadCredentials(allowInteraction: allowInteraction)
                    try await fetchUsage(current)
                }
            } catch is CancellationError {
            } catch let error as ClaudeError {
                if case .rateLimited(let until) = error { blockedUntil = until ?? Date().addingTimeInterval(300) }
                if error == .signedOut || error == .expired { credentials = nil }
                onStatus?(error.localizedDescription)
            } catch {
                onStatus?(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    private func loadCredentials(allowInteraction: Bool) async throws -> ClaudeCredentials {
        if let credentials, !credentials.isExpired { return credentials }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try Self.readClaudeCode(allowInteraction: allowInteraction)
        }.value
        try Task.checkCancellation()
        guard !loaded.isExpired else { throw ClaudeError.expired }
        credentials = loaded; plan = loaded.plan
        return loaded
    }

    nonisolated private static func readClaudeCode(allowInteraction: Bool) throws -> ClaudeCredentials {
        // Linux-style installs keep a file; the macOS CLI keeps it in the login Keychain.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let parsed = try? ClaudeCredentials.parse(data), !parsed.isExpired {
            return parsed
        }
        // Claude Code writes its item with /usr/bin/security, which the item therefore trusts:
        // reading through it needs no grant and keeps working after Sea Coffee is rebuilt.
        if let data = SecureStore.readViaSecurityTool(service: ClaudeProtocol.keychainService),
           let parsed = try? ClaudeCredentials.parse(data) {
            return parsed
        }
        guard let data = try SecureStore.readForeign(service: ClaudeProtocol.keychainService,
                                                     allowInteraction: allowInteraction) else {
            throw ClaudeError.missingCredentials
        }
        return try ClaudeCredentials.parse(data)
    }

    private func fetchUsage(_ credentials: ClaudeCredentials) async throws {
        var request = URLRequest(url: ClaudeProtocol.usageURL)
        request.timeoutInterval = 25
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeProtocol.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(ClaudeProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        try ClaudeProtocol.validate(status: http?.statusCode ?? 0, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        let snapshot = try ClaudeProtocol.usage(data)
        try Task.checkCancellation()
        onUsage?(snapshot)
        onStatus?("已连接 Claude\(plan.map { " · \($0)" } ?? "")")
    }
}
