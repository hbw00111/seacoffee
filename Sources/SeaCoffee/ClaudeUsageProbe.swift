import Darwin
import Foundation
import IslandCore

/// Opens Claude Code in a pseudo-terminal, types `/usage` and reads the screen. Claude Code
/// renews its own expired login while starting up, so Sea Coffee never touches the token.
/// No prompt is ever sent: the session has no tools, hooks or MCP servers, runs in its own
/// folder, and that folder's transcript directory is removed afterwards.
enum ClaudeUsageProbe {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeaIsland/ClaudeProbe", isDirectory: true)
    }

    static func run(timeout: TimeInterval = 30) -> UsageSnapshot? {
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
        defer { stop(process, master: master) }

        var output = Data()
        let start = Date()
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

        // Wait for the input prompt; the folder-trust question only appears in this probe folder.
        var trusted = false
        while Date().timeIntervalSince(start) < 15, process.isRunning {
            pump(0.5)
            let text = screen().lowercased()
            if !trusted, text.contains("trust"), text.contains("folder") { type("\r"); trusted = true; continue }
            if text.contains("❯"), Date().timeIntervalSince(start) > 2 { break }
        }
        guard process.isRunning else { return nil }
        type("/usage"); pump(0.6); type("\r")
        let mark = output.count

        // Keep reading a little after the first numbers so the weekly windows can load too.
        var settledAt: Date?
        var usage: UsageSnapshot?
        while Date().timeIntervalSince(start) < timeout, process.isRunning {
            pump(0.5)
            if let parsed = ClaudeUsageScreen.usage(screen(from: mark)) {
                usage = parsed
                settledAt = settledAt ?? Date()
            }
            if let settledAt, Date().timeIntervalSince(settledAt) > 2.5 { break }
        }
        return usage
    }

    private static func stop(_ process: Process, master: Int32) {
        guard process.isRunning else { return }
        _ = "\u{1B}".utf8CString.withUnsafeBufferPointer { write(master, $0.baseAddress, 1) }
        process.terminate()
        let end = Date().addingTimeInterval(2)
        while process.isRunning, Date() < end { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
