import Foundation

/// The user's login shell environment, resolved once at startup.
///
/// GUI apps launched from Finder get a minimal PATH, so we ask the login shell
/// for the real one before running git / gh.
enum ShellEnvironment {
    static let shell: String = {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    private static let lock = NSLock()
    private static var _path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static var _codexHome: String?
    private static var _defaultAgent: AgentKind?
    private static var _installedAgents: [AgentKind]?
    private static var _remotePort: String?

    static var path: String {
        lock.lock(); defer { lock.unlock() }
        return _path
    }

    /// CODEX_HOME as set by the user's shell, if at all.
    static var codexHome: String? {
        lock.lock(); defer { lock.unlock() }
        return _codexHome
    }

    /// VHOSTTY_DEFAULT_AGENT ("claude" or "codex") as set by the user's shell.
    static var defaultAgent: AgentKind? {
        lock.lock(); defer { lock.unlock() }
        return _defaultAgent ?? ProcessInfo.processInfo.environment["VHOSTTY_DEFAULT_AGENT"]
            .flatMap { AgentKind(rawValue: $0.lowercased()) }
    }

    /// VHOSTTY_REMOTE_PORT, unparsed: the app's own environment (test
    /// instances), else as set by the user's shell.
    static var remotePort: String? {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.environment["VHOSTTY_REMOTE_PORT"] ?? _remotePort
    }

    /// The agents found by the user's interactive shell; nil until loadInteractive ran.
    static var installedAgents: [AgentKind]? {
        lock.lock(); defer { lock.unlock() }
        return _installedAgents
    }

    static func load() {
        let marker = "__VHOSTTY_PATH__"
        let result = Proc.run(shell, ["-l", "-c", "printf '\(marker)%s' \"$PATH\""], timeout: 8, usePathEnv: false)
        guard let out = result?.stdout, let range = out.range(of: marker) else { return }
        let p = String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        lock.lock()
        _path = p
        lock.unlock()
    }

    /// Codex runs in each tab's interactive login shell (ClaudeLauncher.command), so
    /// read CODEX_HOME, VHOSTTY_DEFAULT_AGENT and VHOSTTY_REMOTE_PORT the same way: they may be set in an
    /// rc file. Also note which agents that shell can find (its PATH, aliases and
    /// functions may differ from the non-interactive PATH above).
    static func loadInteractive() {
        let marker = "__VHOSTTY_ENV__"
        let script = "printf '\(marker)%s\\n%s\\n%s\\n%s\\n%s\\n' \"$CODEX_HOME\" \"$VHOSTTY_DEFAULT_AGENT\" "
            + "\"$(command -v claude)\" \"$(command -v codex)\" \"$VHOSTTY_REMOTE_PORT\""
        let result = Proc.run(shell, ["-l", "-i", "-c", script], timeout: 8, usePathEnv: false)
        guard let out = result?.stdout, let range = out.range(of: marker) else { return }
        let lines = out[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 5 else { return }
        var installed: [AgentKind] = []
        if !lines[2].isEmpty { installed.append(.claude) }
        if !lines[3].isEmpty { installed.append(.codex) }
        lock.lock()
        _codexHome = lines[0].nonEmpty
        _defaultAgent = AgentKind(rawValue: lines[1].lowercased())
        _installedAgents = installed
        _remotePort = lines[4].nonEmpty
        lock.unlock()
    }

    static func which(_ name: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Minimal synchronous subprocess runner. Call from a background queue.
enum Proc {
    struct Result {
        let status: Int32
        let stdout: String
    }

    static func run(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 10,
        usePathEnv: Bool = true
    ) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        if usePathEnv { env["PATH"] = ShellEnvironment.path }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return nil }

        // Read concurrently so a chatty process can't fill the pipe and block.
        var data = Data()
        let reader = DispatchQueue(label: "vhostty.proc.read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}

enum AppPaths {
    static let support: URL = {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["VHOSTTY_SUPPORT_DIR"] {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("Vhostty", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var state: URL { support.appendingPathComponent("state.json") }
    static var claudeSettings: URL { support.appendingPathComponent("claude-settings.json") }

    static var hookSocket: String {
        let p = support.appendingPathComponent("hook.sock").path
        // sockaddr_un.sun_path is 104 bytes.
        return p.utf8.count < 100 ? p : "/tmp/vhostty-\(getuid()).sock"
    }
}

extension String {
    /// Replaces the home directory prefix with "~".
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}
