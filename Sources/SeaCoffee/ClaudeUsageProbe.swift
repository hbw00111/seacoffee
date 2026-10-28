import Darwin
import Foundation
import IslandCore

/// Opens Claude Code in a pseudo-terminal, types `/usage` and reads the screen. Claude Code
/// renews its own expired login while starting up, so Sea Coffee never touches the token.
/// No prompt is ever sent: the session has no tools, hooks or MCP servers, runs in its own
/// folder, and that folder's transcript directory is removed afterwards.
///
/// Like CodexBar, the CLI is never cut off while it may be renewing: a refresh rotates the
/// refresh token on the server, so killing Claude Code before it writes the new one back
/// leaves a stale token in the Keychain that the server later revokes. Startup therefore has
/// a long limit, and every exit starts with `/exit` before any signal.
enum ClaudeUsageProbe {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeaIsland/ClaudeProbe", isDirectory: true)
    }

    /// Waiting for the input prompt, which is when Claude Code renews an expired login.
    static let startupLimit: TimeInterval = 90
    /// Reading `/usage` once the prompt is up and the login is settled.
    static let readLimit: TimeInterval = 30

    static func run() -> UsageSnapshot? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Apps launched from Finder do not inherit the shell's PATH.
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
        guard let binary = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }),
              (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        defer { removeTranscripts() }

        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        defer { close(master) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--allowed-tools", "", "--strict-mcp-config",
                             "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        do { try process.run() } catch { close(slave); return nil }
        close(slave)

        var output = Data()
        // Keeps draining the terminal so Claude Code never blocks on a full buffer, including while it exits.
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while Date() < end {
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 200) > 0 else { continue }
                let count = read(master, &buffer, buffer.count)
                if count <= 0 { return }
                output.append(buffer, count: count)
            }
        }
        func screen(from offset: Int = 0) -> String { String(decoding: output.dropFirst(offset), as: UTF8.self) }
        func type(_ text: String) { _ = text.utf8CString.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count - 1) } }
        defer { stop(process, type: type, pump: pump) }

        // Wait for the input prompt; the folder-trust question only appears in this probe folder.
        let start = Date()
        var trusted = false, ready = false
        while Date().timeIntervalSince(start) < startupLimit, process.isRunning {
            pump(0.5)
            let text = screen().lowercased()
            if !trusted, text.contains("trust"), text.contains("folder") { type("\r"); trusted = true; continue }
            if text.contains("❯"), Date().timeIntervalSince(start) > 2 { ready = true; break }
        }
        guard ready, process.isRunning else { return nil }
        type("/usage"); pump(0.6); type("\r")
        let mark = output.count

        // Keep reading a little after the first numbers so the weekly windows can load too.
        let reading = Date()
        var settledAt: Date?
        var usage: UsageSnapshot?
        while Date().timeIntervalSince(reading) < readLimit, process.isRunning {
            pump(0.5)
            if let parsed = ClaudeUsageScreen.usage(screen(from: mark)) {
                usage = parsed
                settledAt = settledAt ?? Date()
            }
            if let settledAt, Date().timeIntervalSince(settledAt) > 2.5 { break }
        }
        return usage
    }

    /// CodexBar's order: close `/usage`, ask Claude Code to `/exit` and let it finish writing,
    /// then SIGTERM the whole process tree, and SIGKILL only what is still running after that.
    private static func stop(_ process: Process, type: (String) -> Void, pump: (TimeInterval) -> Void) {
        let root = process.processIdentifier
        var tree = descendants(of: root)
        if process.isRunning {
            type("\u{1B}"); pump(0.3)
            type("/exit\r")
            wait(for: process, seconds: 5, pump: pump)
        }
        guard process.isRunning || tree.contains(where: isAlive) else { return }
        tree = Array(Set(tree + descendants(of: root)))
        // An exited root's pid may already belong to someone else.
        signal((process.isRunning ? [root] : []) + tree, SIGTERM)
        wait(for: process, seconds: 2, pump: pump)
        signal((process.isRunning ? [root] : []) + tree, SIGKILL)
    }

    private static func wait(for process: Process, seconds: TimeInterval, pump: (TimeInterval) -> Void) {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < end { pump(0.1) }
    }

    /// Children are listed before signalling so that ones reparented after the CLI exits are still reached.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(count) + 16)
        let found = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        let direct = children.prefix(Int(max(found, 0))).filter { $0 > 0 }
        return direct + direct.flatMap { descendants(of: $0) }
    }

    private static func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    private static func signal(_ pids: [pid_t], _ signal: Int32) {
        for pid in pids where isAlive(pid) { kill(pid, signal) }
    }

    /// Claude Code names a project's transcript folder after its path with every other
    /// character replaced by "-". Only the probe folder's own entry is removed.
    private static func removeTranscripts() {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let name = String(directory.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        try? FileManager.default.removeItem(at: config.appendingPathComponent("projects/\(name)", isDirectory: true))
    }
}
