import Foundation

/// App-owned secrets in a user-only JSON file. Unlike Keychain ACLs, file access does not
/// depend on the binary's code signature, so rebuilding the app keeps its credentials.
public struct CredentialFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var applicationSupport: CredentialFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CredentialFile(url: base.appendingPathComponent("SeaIsland/credentials.json"))
    }

    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var secrets: [String: String] = [:]
        /// Accounts whose legacy Keychain item was already imported or confirmed absent.
        public var migrated: Set<String> = []
        public init() {}
    }

    public func read() throws -> Contents {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return Contents() }
            throw CredentialFileError.unreadable(errno)
        }
        // Refuse links and anything that is not a plain file we own.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw CredentialFileError.unsafe }
        if info.st_mode & 0o077 != 0 { chmod(path, 0o600) }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Contents.self, from: data)
    }

    public func value(_ account: String) throws -> String? { try read().secrets[account] }

    public func update(_ change: (inout Contents) -> Void) throws {
        var contents = try read()
        change(&contents)
        try write(contents)
    }

    /// Stage in a private sibling directory, fsync, then rename so readers never see a partial file.
    public func write(_ contents: Contents) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(url.lastPathComponent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(contents)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CredentialFileError.unwritable(errno) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd)
        close(fd)
        guard written == data.count, synced == 0 else { throw CredentialFileError.unwritable(errno) }
        guard rename(temporary.path, url.path) == 0 else { throw CredentialFileError.unwritable(errno) }
    }
}

public enum CredentialFileError: LocalizedError, Equatable {
    case unreadable(Int32), unwritable(Int32), unsafe
    public var errorDescription: String? {
        switch self {
        case .unreadable(let code): return "无法读取本地凭据文件（\(code)）。"
        case .unwritable(let code): return "无法写入本地凭据文件（\(code)），请检查磁盘空间与权限。"
        case .unsafe: return "本地凭据文件不是当前用户的普通文件，已拒绝读取。"
        }
    }
}
