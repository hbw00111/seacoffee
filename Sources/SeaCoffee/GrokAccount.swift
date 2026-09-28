import Foundation
import IslandCore

/// Reads the Grok Build CLI's login from `~/.grok/auth.json`. Nothing is written back;
/// the CLI refreshes its own short-lived token whenever it runs.
@MainActor
final class GrokAccount: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var enabled: Bool
    @Published private(set) var plan: String?
    @Published private(set) var email: String?
    /// Outcome of the latest refresh, for the settings button's check or shake.
    @Published private(set) var lastSucceeded: Bool?
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    private var lastAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let minimumInterval: TimeInterval = 120
    /// At most one background CLI refresh per ten minutes, so a broken login is not retried every poll.
    private var lastCLIRefresh = Date.distantPast
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.bool(forKey: "grokEnabled")
    }

    func connect() {
        enabled = true
        UserDefaults.standard.set(true, forKey: "grokEnabled")
        refresh(force: true)
    }

    func disconnect() {
        task?.cancel()
        enabled = false; plan = nil; email = nil
        UserDefaults.standard.set(false, forKey: "grokEnabled")
        onDisconnect?()
        onStatus?("已停止读取 Grok 登录")
    }

    func refresh(force: Bool = false) {
        guard enabled, !busy else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        lastAttempt = now; busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                var credentials = try await Task.detached(priority: .userInitiated) { try Self.readCLI() }.value
                try Task.checkCancellation()
                if credentials.isExpired, Date().timeIntervalSince(lastCLIRefresh) > 600 {
                    // The CLI refreshes and rewrites its own login; Sea Coffee still never writes it.
                    lastCLIRefresh = Date()
                    onStatus?("Grok 登录已过期，正在让 Grok CLI 自动续期…")
                    if await Task.detached(priority: .utility, operation: { Self.refreshThroughCLI() }).value {
                        credentials = try await Task.detached(priority: .userInitiated) { try Self.readCLI() }.value
                    }
                    try Task.checkCancellation()
                }
                guard !credentials.isExpired else { throw GrokError.expired }
                email = credentials.email
                let snapshot = try GrokProtocol.usage(try await get(GrokProtocol.billingURL, credentials))
                try Task.checkCancellation()
                onUsage?(snapshot)
                // The tier is optional enrichment; it must not hide usage we already have.
                if plan == nil, let data = try? await get(GrokProtocol.settingsURL, credentials, timeout: 5) {
                    plan = GrokProtocol.plan(data)
                }
                onStatus?("已连接 Grok\(plan.map { " · \($0)" } ?? "")")
                lastSucceeded = true
            } catch is CancellationError {
            } catch {
                lastSucceeded = false
                onStatus?(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    /// `grok models` lists models and exits: it needs a valid login, so the CLI refreshes an expired
    /// token itself, without starting a conversation, spending credits or writing a session.
    nonisolated private static func refreshThroughCLI() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Apps launched from Finder do not inherit the shell's PATH.
        let candidates = ["\(home)/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["models"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        guard done.wait(timeout: .now() + 40) == .success else { process.terminate(); return false }
        return process.terminationStatus == 0
    }

    nonisolated private static func readCLI() throws -> GrokCredentials {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else {
            throw GrokError.missingCredentials
        }
        return try GrokCredentials.parse(data)
    }

    private func get(_ url: URL, _ credentials: GrokCredentials, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(GrokProtocol.tokenAuthHeader, forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SeaCoffee", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try GrokProtocol.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return data
    }
}
