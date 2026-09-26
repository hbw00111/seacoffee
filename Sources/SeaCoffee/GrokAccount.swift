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
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    private var lastAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let minimumInterval: TimeInterval = 120
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
                let credentials = try await Task.detached(priority: .userInitiated) { try Self.readCLI() }.value
                try Task.checkCancellation()
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
            } catch is CancellationError {
            } catch {
                onStatus?(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

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
