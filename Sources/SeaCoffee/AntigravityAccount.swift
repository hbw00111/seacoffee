import Foundation
import IslandCore

/// Reads Antigravity's login (shared by the `agy` CLI and the desktop app) from its Keychain
/// item. Nothing is written back and Antigravity is never started: its hourly token is renewed
/// by Antigravity itself while it runs, which is also the only time the quota moves.
@MainActor
final class AntigravityAccount: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var enabled: Bool
    @Published private(set) var plan: String?
    @Published private(set) var email: String?
    /// Outcome of the latest refresh, for the settings button's check or shake.
    @Published private(set) var lastSucceeded: Bool?
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    private var project: String?
    private var lastAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let minimumInterval: TimeInterval = 120
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(defaults: UserDefaults = SeaCoffeePreferences.shared) {
        enabled = defaults.bool(forKey: "antigravityEnabled")
    }

    func connect() {
        enabled = true
        SeaCoffeePreferences.shared.set(true, forKey: "antigravityEnabled")
        refresh(force: true)
    }

    func disconnect() {
        task?.cancel()
        enabled = false; plan = nil; email = nil; project = nil
        SeaCoffeePreferences.shared.set(false, forKey: "antigravityEnabled")
        onDisconnect?()
        onStatus?("已停止读取 Antigravity 登录")
    }

    func refresh(force: Bool = false) {
        guard enabled, !busy else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        lastAttempt = now; busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                let credentials = try await Task.detached(priority: .userInitiated) { try Self.readLogin() }.value
                try Task.checkCancellation()
                guard !credentials.isExpired else { throw AntigravityError.expired }
                email = credentials.email
                // The project and tier are optional: the models request also answers without them.
                if project == nil, let data = try? await post(AntigravityProtocol.loadURL, AntigravityProtocol.loadBody, credentials, timeout: 10) {
                    let account = AntigravityProtocol.account(data)
                    project = account.project; plan = account.plan ?? plan
                }
                let body = AntigravityProtocol.modelsBody(project: project)
                let snapshot = try AntigravityProtocol.usage(try await post(AntigravityProtocol.modelsURL, body, credentials))
                try Task.checkCancellation()
                onUsage?(snapshot)
                onStatus?("已连接 Antigravity\(plan.map { " · \($0)" } ?? "")")
                lastSucceeded = true
            } catch is CancellationError {
            } catch {
                lastSucceeded = false
                onStatus?(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    nonisolated private static func readLogin() throws -> AntigravityCredentials {
        // Antigravity writes its item through /usr/bin/security, which the item therefore trusts:
        // reading through it needs no grant and keeps working after Sea Coffee is rebuilt.
        if let data = SecureStore.readViaSecurityTool(service: AntigravityProtocol.keychainService,
                                                      account: AntigravityProtocol.keychainAccount) {
            return try AntigravityCredentials.parse(data)
        }
        // Without a usable Keychain, Antigravity falls back to a file of the same shape.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        guard let data = try? Data(contentsOf: file) else { throw AntigravityError.missingCredentials }
        return try AntigravityCredentials.parse(data)
    }

    private func post(_ url: URL, _ body: Data, _ credentials: AntigravityCredentials, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SeaCoffee", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try AntigravityProtocol.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return data
    }
}
