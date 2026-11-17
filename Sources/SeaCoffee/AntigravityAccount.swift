import Foundation
import IslandCore

/// Asks the running Antigravity desktop app for its quota over loopback, as CodexBar does.
/// Sea Coffee holds no Antigravity login, sends nothing to Google and never starts Antigravity:
/// with the app closed the last numbers stay, which is also when the quota cannot move.
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
    private var lastAttempt = Date.distantPast
    private var task: Task<Void, Never>?
    private let minimumInterval: TimeInterval = 120
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: LoopbackTrust(), delegateQueue: nil)
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
        enabled = false; plan = nil; email = nil
        SeaCoffeePreferences.shared.set(false, forKey: "antigravityEnabled")
        onDisconnect?()
        onStatus?("已停止读取 Antigravity 额度")
    }

    func refresh(force: Bool = false) {
        guard enabled, !busy else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        lastAttempt = now; busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                let hubs = await Task.detached(priority: .userInitiated) { Self.runningHubs() }.value
                guard !hubs.isEmpty else { throw AntigravityError.notRunning }
                let (snapshot, endpoint, hub) = try await fetchUsage(hubs)
                try Task.checkCancellation()
                onUsage?(snapshot)
                // The account and plan are optional enrichment; they must not hide usage we already have.
                if let data = try? await post(endpoint, AntigravityProtocol.statusMethod, AntigravityProtocol.statusBody, hub, timeout: 3) {
                    let identity = AntigravityProtocol.identity(data)
                    email = identity.email ?? email; plan = identity.plan ?? plan
                }
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

    /// Antigravity's own discovery files, kept only for processes that are still alive.
    nonisolated private static func runningHubs() -> [AntigravityHub] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
            .compactMap(AntigravityHub.parse)
            // Signal 0 only asks whether the process exists; a crashed app leaves its file behind.
            .filter { kill($0.pid, 0) == 0 }
    }

    /// The first endpoint that answers; the last refusal is the one reported.
    private func fetchUsage(_ hubs: [AntigravityHub]) async throws -> (UsageSnapshot, URL, AntigravityHub) {
        var failure: Error = AntigravityError.notRunning
        for hub in hubs {
            for endpoint in hub.endpoints {
                do {
                    let data = try await post(endpoint, AntigravityProtocol.summaryMethod, AntigravityProtocol.summaryBody, hub)
                    return (try AntigravityProtocol.usage(data), endpoint, hub)
                } catch is CancellationError { throw CancellationError()
                } catch { failure = error }
            }
        }
        throw failure
    }

    private func post(_ endpoint: URL, _ method: String, _ body: Data, _ hub: AntigravityHub, timeout: TimeInterval = 8) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(hub.csrfToken, forHTTPHeaderField: AntigravityProtocol.csrfHeader)
        let (data, response) = try await session.data(for: request)
        try AntigravityProtocol.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        return data
    }
}

/// Antigravity's local server presents a self-signed certificate. It is accepted for 127.0.0.1
/// only; every other host keeps the system's checks, and redirects are refused.
private final class LoopbackTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == "127.0.0.1",
              let trust = space.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
