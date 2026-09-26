import AppKit
import Foundation
import IslandCore

// Serial background access keeps file I/O and any legacy Keychain import off the UI thread.
private actor ClineCredentialStore {
    private let account = "cline-oauth"
    private var pendingRotation: ClineCredentials?
    func read(allowInteraction: Bool = false) throws -> ClineCredentials? {
        if let pendingRotation {
            try write(pendingRotation)
        }
        guard let text = try SecureStore.read(account: account, allowInteraction: allowInteraction) else { return nil }
        return try JSONDecoder().decode(ClineCredentials.self, from: Data(text.utf8))
    }
    func write(_ value: ClineCredentials?, isRotation: Bool = false) throws {
        // A rotated refresh token must survive a persistence failure within this process.
        if isRotation { pendingRotation = value }
        let text = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try SecureStore.write(text, account: account)
        guard try SecureStore.read(account: account) == (text.isEmpty ? nil : text) else {
            throw ClineError.invalidResponse
        }
        pendingRotation = nil
    }
}

@MainActor
final class ClineAccount: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var loggingIn = false
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    @Published private(set) var email: String?
    @Published private(set) var connected = false
    @Published private(set) var hasAPIKey = false
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    var onLogout: (() -> Void)?
    private let store = ClineCredentialStore()
    private var task: Task<Void, Never>?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func connect() {
        run(login: true) { [self] in
            onStatus?("正在申请 Cline 登录授权…")
            let data = try await request(ClineProtocol.workOS + "/user_management/authorize/device",
                                         form: ["client_id": ClineProtocol.clientID])
            let auth = try ClineDeviceAuthorization.parse(data)
            try Task.checkCancellation()
            userCode = auth.userCode; verificationURL = auth.verificationURL
            onStatus?("请在浏览器确认设备码并完成 Cline 登录")
            NSWorkspace.shared.open(auth.verificationURL)
            let deadline = Date().addingTimeInterval(auth.expiresIn)
            var interval = auth.interval
            while Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                guard Date() < deadline else { throw ClineError.expired }
                let (body, status) = try await response(ClineProtocol.workOS + "/user_management/authenticate", form: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": auth.deviceCode, "client_id": ClineProtocol.clientID
                ])
                switch try ClineProtocol.poll(body, status: status) {
                case .pending: continue
                case .slowDown: interval += 1
                case .authorized(let access, let refresh):
                    let registered = try await request(ClineProtocol.api + "/api/v1/auth/register",
                                                       json: ["accessToken": access, "refreshToken": refresh])
                    let credentials = try ClineCredentials.parse(registered)
                    try Task.checkCancellation()
                    try await store.write(credentials)
                    // Once issued, persist rotated tokens even if the view changes during Keychain access.
                    try Task.checkCancellation()
                    connected = true; email = credentials.email
                    loggingIn = false; userCode = nil; verificationURL = nil
                    onStatus?("Cline 登录成功，正在查询配额…")
                    try await fetchUsage(credentials)
                    return
                }
            }
            throw ClineError.expired
        }
    }

    nonisolated static let apiKeyAccount = "cline-apikey"

    /// Saves or removes (empty) an API key. A saved key takes precedence over the OAuth login.
    func setAPIKey(_ key: String) {
        run { [self] in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.detached { try SecureStore.writeAndVerify(trimmed, account: Self.apiKeyAccount) }.value
            hasAPIKey = !trimmed.isEmpty
            if trimmed.isEmpty {
                onLogout?(); onStatus?("已移除 Cline API Key")
            } else {
                onStatus?("正在用 API Key 查询配额…")
                try await fetchUsage(authorization: ClineProtocol.apiKeyHeader(trimmed), label: "API Key")
            }
        }
    }

    func refresh(allowInteraction: Bool = false) {
        run { [self] in
            if let key = try await Task.detached(operation: { try SecureStore.read(account: Self.apiKeyAccount) }).value, !key.isEmpty {
                hasAPIKey = true
                try await fetchUsage(authorization: ClineProtocol.apiKeyHeader(key), label: "API Key")
                return
            }
            hasAPIKey = false
            guard var credentials = try await store.read(allowInteraction: allowInteraction) else {
                connected = false; email = nil
                throw ClineError.notConnected
            }
            try Task.checkCancellation()
            connected = true; email = credentials.email
            if credentials.expiresAt.timeIntervalSinceNow < 300 {
                credentials = try await renew(credentials)
            }
            do { try await fetchUsage(credentials) }
            catch ClineError.signedOut {
                credentials = try await renew(credentials)
                try await fetchUsage(credentials)
            }
        }
    }

    func logout() {
        run { [self] in
            try await store.write(nil)
            connected = false; email = nil
            onLogout?()
            onStatus?("已移除此应用保存的 Cline 登录")
        }
    }

    func stop() { task?.cancel() }

    private func run(login: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; loggingIn = login
        task = Task {
            defer {
                busy = false; loggingIn = false; userCode = nil; verificationURL = nil; task = nil
            }
            do { try await operation() }
            catch is CancellationError { onStatus?("操作已取消") }
            catch ClineError.signedOut {
                connected = false
                onStatus?(ClineError.signedOut.localizedDescription)
            }
            catch {
                if Task.isCancelled { onStatus?("操作已取消") }
                else { onStatus?(error.localizedDescription) }
            }
        }
    }

    private func renew(_ old: ClineCredentials) async throws -> ClineCredentials {
        let data = try await request(ClineProtocol.api + "/api/v1/auth/refresh",
                                     json: ["refreshToken": old.refreshToken, "grantType": "refresh_token"])
        let credentials = try ClineCredentials.parse(data, previous: old)
        try await store.write(credentials, isRotation: true)
        try Task.checkCancellation()
        email = credentials.email
        return credentials
    }

    private func fetchUsage(_ credentials: ClineCredentials) async throws {
        try await fetchUsage(authorization: ClineProtocol.authorizationHeader(credentials.accessToken), label: email)
    }

    private func fetchUsage(authorization: String, label: String?) async throws {
        let (data, status) = try await response(ClineProtocol.api + "/api/v1/users/me/plan/usage-limits", authorization: authorization)
        try ClineProtocol.validateUsageStatus(status)
        let snapshot = try ClineProtocol.usage(data)
        try Task.checkCancellation()
        onUsage?(snapshot)
        onStatus?("已连接 Cline Pass\(label.map { " · \($0)" } ?? "")")
    }

    private func request(_ url: String, form: [String: String]? = nil,
                         json: [String: String]? = nil) async throws -> Data {
        let (data, status) = try await response(url, form: form, json: json)
        if status == 401 { throw ClineError.signedOut }
        guard (200..<300).contains(status) else { throw ClineError.http(status) }
        return data
    }

    private func response(_ url: String, form: [String: String]? = nil,
                          json: [String: String]? = nil, authorization: String? = nil) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ClineProtocol.form(form)
        } else if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
