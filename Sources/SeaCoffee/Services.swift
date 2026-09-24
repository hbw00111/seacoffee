import AppKit
import Foundation
import Security
import LocalAuthentication
import IslandCore

enum SecureStore {
    private static let service = "com.seacoffee.SeaIsland"
    private static let lock = NSLock()
    private static var cached: [String: String] = [:]
    private static var absent: Set<String> = []

    private static func authentication(_ interactive: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        return context
    }
    // LAContext controls modern authentication, but login-keychain ACLs also use the
    // legacy process-wide interaction switch. All our Keychain calls share this lock.
    private static func beginInteraction(_ allowed: Bool) throws -> Bool {
        var previous = DarwinBoolean(true)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { throw error(readStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
        guard setStatus == errSecSuccess else { throw error(setStatus) }
        return previous.boolValue
    }
    // Inspect existence without returning the credential or triggering a password dialog.
    static func containsKey() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previous = try beginInteraction(false)
        defer { SecKeychainSetUserInteractionAllowed(previous) }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "sub2api",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw error(status) }
        return true
    }

    static func writeAndVerify(_ key: String) throws {
        try write(key, allowInteraction: true)
        let stored = try read(allowInteraction: true, useCache: false)
        guard key.isEmpty ? stored == nil : stored == key else {
            throw NSError(domain: "SeaCoffee.Keychain", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "写入后未能确认密钥，请重试保存。"])
        }
    }
    static func read(account: String = "sub2api", allowInteraction: Bool = false, useCache: Bool = true) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if useCache {
            if let value = cached[account] { return value }
            if absent.contains(account) { return nil }
        }
        let previous = try beginInteraction(allowInteraction)
        defer { SecKeychainSetUserInteractionAllowed(previous) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication(allowInteraction)]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { cached[account] = nil; absent.insert(account); return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw error(status) }
        cached[account] = value; absent.remove(account)
        return value
    }
    static func write(_ key: String, account: String = "sub2api", allowInteraction: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try beginInteraction(allowInteraction)
        defer { SecKeychainSetUserInteractionAllowed(previous) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authentication(allowInteraction)]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
            cached[account] = nil; absent.insert(account)
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if updated == errSecItemNotFound {
            var insert = query.merging(value) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw error(status) }
        } else if updated != errSecSuccess { throw error(updated) }
        // Verify callers bypass the cache; successful writes invalidate all older values.
        cached[account] = nil; absent.remove(account)
    }
    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: "SeaCoffee.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "已暂停读取凭据（\(status)），请在设置中点击“授权读取已存凭据”；后台不会弹出密码框。"])
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum BalanceClient {
    static func fetch(site: String, key: String, baseline: Double) async throws -> UsageSnapshot {
        var request = URLRequest(url: try UsageDecoder.endpoint(site))
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw TelemetryError.invalidKey }
        guard code == 200 else { throw TelemetryError.http(code) }
        return try UsageDecoder.sub2API(data, baseline: baseline)
    }
}

@MainActor
final class OfficialAccount {
    var onStatus: ((String) -> Void)?
    var onUsage: ((UsageSnapshot) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var initialized = false
    private var bootActions: [() -> Void] = []
    var binaryPath = ""

    func connect() { boot { [weak self] in self?.login() } }
    func refresh() {
        boot { [weak self] in
            self?.request("account/read", ["refreshToken": false]) { result in
                switch result {
                case .success(let value):
                    guard let account = value["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                        self?.onStatus?("请在设置中连接官方账号"); return
                    }
                    self?.readLimits()
                case .failure(let error): self?.onStatus?(error.localizedDescription)
                }
            }
        }
    }
    func stop() {
        initialized = false
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        input = nil
        process?.terminate(); process = nil
        pending.removeAll(); bootActions.removeAll(); buffer.removeAll()
    }
    private func boot(_ action: @escaping () -> Void) {
        if initialized { action(); return }
        bootActions.append(action)
        if process != nil { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [binaryPath, "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let binary = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            bootActions.removeAll(); onStatus?("未找到 Codex CLI，请在设置中指定路径"); return
        }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SeaIsland/OfficialAccount", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let p = Process(); let stdin = Pipe(); let stdout = Pipe()
            p.executableURL = URL(fileURLWithPath: binary); p.arguments = ["app-server"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = support.path
            for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY"] { environment.removeValue(forKey: key) }
            p.environment = environment
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty { Task { @MainActor in self?.receive(data) } }
            }
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.stop(); self.onStatus?("Codex 连接已断开，请重试")
                }
            }
            try p.run(); process = p; input = stdin.fileHandleForWriting
            request("initialize", ["clientInfo": ["name": "seaisland", "title": "Sea Coffee", "version": "0.1.0"]]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.send(["method": "initialized"]); self.initialized = true
                    let actions = self.bootActions; self.bootActions.removeAll(); actions.forEach { $0() }
                case .failure(let error): self.stop(); self.onStatus?(error.localizedDescription)
                }
            }
        } catch { stop(); onStatus?("无法启动 Codex CLI：\(error.localizedDescription)") }
    }
    private func login() {
        onStatus?("请在浏览器中完成登录…")
        request("account/login/start", ["type": "chatgpt"]) { [weak self] result in
            switch result {
            case .success(let data):
                if let string = data["authUrl"] as? String, let url = URL(string: string), url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                } else { self?.onStatus?("登录链接不可用，请检查 Codex CLI 版本") }
            case .failure(let error): self?.onStatus?(error.localizedDescription)
            }
        }
    }
    private func readLimits() {
        request("account/rateLimits/read", [:]) { [weak self] result in
            do { let snapshot = try UsageDecoder.official(result.get()); self?.onUsage?(snapshot); self?.onStatus?("已连接官方账号") }
            catch { self?.onStatus?("官方额度暂不可用：\(error.localizedDescription)") }
        }
    }
    private func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextID; nextID += 1; pending[id] = completion
        send(["id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.pending.removeValue(forKey: id)?(.failure(NSError(domain: "SeaCoffee", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Codex 响应超时，请重试"])))
        }
    }
    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10); try? input?.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let completion = pending.removeValue(forKey: id) {
                if object["error"] != nil {
                    completion(.failure(NSError(domain: "SeaCoffee", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex 拒绝了请求，请检查登录状态与 CLI 版本"])))
                } else { completion(.success(object["result"] as? [String: Any] ?? [:])) }
            }
            if object["method"] as? String == "account/login/completed", let params = object["params"] as? [String: Any] {
                if params["success"] as? Bool == true { readLimits() }
                else { onStatus?("登录未完成，可重新连接") }
            }
            if object["method"] as? String == "account/rateLimits/updated", let params = object["params"] as? [String: Any],
               let snapshot = try? UsageDecoder.official(params) { onUsage?(snapshot) }
        }
        if buffer.count > 2 * 1024 * 1024 { buffer.removeAll() }
    }
}
