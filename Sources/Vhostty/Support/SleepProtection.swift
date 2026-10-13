import AppKit

/// Only an explicit refusal is persisted. Authorization is checked on every launch.
final class SleepProtection {
    weak var menuItem: NSMenuItem? { didSet { updateMenuTitle() } }
    private(set) var hasFailed = false { didSet { updateMenuTitle() } }
    private let store: AppStore
    private var timer: Timer?
    private var helper: Process?
    private var input: FileHandle?
    private var checking = false
    private let queue = DispatchQueue(label: "vhostty.sleep")
    private var declined: URL { AppPaths.support.appendingPathComponent("sleep-declined") }
    private var isTest: Bool { ProcessInfo.processInfo.environment["VHOSTTY_DEBUG_SNAPSHOT"] != nil }
    private var fixture: URL? {
        guard isTest, ProcessInfo.processInfo.environment["VHOSTTY_SUPPORT_DIR"] != nil,
              let path = ProcessInfo.processInfo.environment["VHOSTTY_SLEEP_TEST_DIR"] else { return nil }
        return URL(fileURLWithPath: path)
    }
    init(store: AppStore) { self.store = store }

    func start() {
        // Ordinary debug instances must never touch real power settings or authorization.
        guard !isTest || fixture != nil else { return }
        guard !FileManager.default.fileExists(atPath: declined.path) else { return }
        checkPermission()
    }
    func configure() {
        guard !checking, !isTest || fixture != nil else { return }
        if hasFailed { retry(); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep tasks running with the lid closed?")
        alert.informativeText = String(localized: "Your Mac stays awake with the lid closed while tasks run, then returns to normal sleep when they finish. Administrator authorization allows this Mac’s administrator accounts to run only these two commands without a password:\n\n/usr/bin/pmset -a disablesleep 1 — prevent sleep\n/usr/bin/pmset -a disablesleep 0 — restore sleep")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        let answer = alert.runModal()
        if answer == .alertSecondButtonReturn {
            do { try Data().write(to: declined, options: .atomic); stop(); hasFailed = false }
            catch { markFailed() }
        } else if answer == .alertFirstButtonReturn {
            // A previous refusal no longer applies, including when authorization is cancelled.
            try? FileManager.default.removeItem(at: declined)
            authorize()
        }
    }
    private func checkPermission() {
        checking = true
        queue.async {
            let allowed = self.hasPermission()
            DispatchQueue.main.async {
                self.checking = false
                if allowed { self.launchHelper() } else { self.configure() }
            }
        }
    }
    private static var ruleURL: URL {
        URL(fileURLWithPath: "/private/etc/sudoers.d/vhostty_sleep")
    }
    private static var ruleResourceURL: URL? {
        Bundle.main.url(forResource: "vhostty-sleep", withExtension: "sudoers")
    }
    static var authorizationRule: String {
        guard let url = ruleResourceURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    /// Check our own root-owned rule, never a permission supplied by another app.
    static func hasInstalledRule(at url: URL, owner: uid_t = 0) -> Bool {
        guard !authorizationRule.isEmpty else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              info.st_size == authorizationRule.utf8.count,
              let data = try? file.readToEnd() else { return false }
        return String(data: data, encoding: .utf8) == authorizationRule
    }
    private func hasPermission() -> Bool {
        if let fixture { return FileManager.default.fileExists(atPath: fixture.appendingPathComponent("authorized").path) }
        guard Self.hasInstalledRule(at: Self.ruleURL) else { return false }
        // Also verify that sudo loads the rule; a timestamp is not lasting authorization.
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l"]; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let text = String(decoding: data, as: UTF8.self)
        // sudo wraps long rules; join continuation lines. Only accept the narrow rule we install.
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }
    private func authorize() {
        checking = true
        queue.async {
            var success = false
            var cancelled = false
            if self.hasPermission() {
                success = true
            } else if let fixture = self.fixture {
                let outcome = (try? String(contentsOf: fixture.appendingPathComponent("authorization-result"))) ?? "cancel"
                success = outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "success"
                cancelled = outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "cancel"
                if success { try? Data().write(to: fixture.appendingPathComponent("authorized")) }
            } else if let source = Self.ruleResourceURL {
                // Copy the bundled static rule, validate, then install atomically.
                let target = Self.ruleURL.path
                let command = "umask 077; /bin/mkdir -p /private/etc/sudoers.d; t=$(/usr/bin/mktemp /private/etc/sudoers.d/.vhostty.XXXXXX) || exit 1; trap '/bin/rm -f \"$t\"' EXIT; /bin/cp " + Self.quote(source.path) + " \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/sbin/chown root:wheel \"$t\" && /bin/chmod 0444 \"$t\" && /bin/mv -f \"$t\" " + Self.quote(target)
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
                var error: NSDictionary?
                let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
                script?.executeAndReturnError(&error)
                cancelled = (error?[NSAppleScript.errorNumber] as? Int) == -128
                success = error == nil && script != nil && self.hasPermission()
            }
            let ok = success, cancel = cancelled
            DispatchQueue.main.async {
                self.checking = false
                if ok { self.launchHelper() } else if !cancel { self.markFailed() }
            }
        }
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func updateMenuTitle() {
        menuItem?.title = hasFailed
            ? String(localized: "Closed-Lid Sleep Protection: Not Active…")
            : String(localized: "Closed-Lid Sleep Protection…")
    }
    private func markFailed() {
        stop()
        hasFailed = true
    }
    func retry() {
        guard !checking, !isTest || fixture != nil else { return }
        authorize()
    }
    private func launchHelper() {
        guard helper == nil else { return }
        try? FileManager.default.removeItem(at: AppPaths.support.appendingPathComponent("sleep-status"))
        let p = Process(), pipe = Pipe()
        p.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vhostty-sleep")
        p.arguments = [AppPaths.support.path]
        if let fixture { p.arguments! += ["--test-dir", fixture.path] }
        p.standardInput = pipe; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { markFailed(); return }
        helper = p; input = pipe.fileHandleForWriting
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
        tick()
    }
    private func tick() {
        guard helper?.isRunning == true else { markFailed(); return }
        let status = try? String(contentsOf: AppPaths.support.appendingPathComponent("sleep-status"))
        if status == "error" { markFailed(); return }
        if status == "idle" || status == "active" || status == "external" { hasFailed = false }
        let busy = store.tabs.contains { $0.isLaunched && ($0.status == .working || $0.status == .starting) }
            || !store.schedulePreparing.isEmpty
        do { try input?.write(contentsOf: Data((busy ? "1\n" : "0\n").utf8)) }
        catch { markFailed() }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        try? input?.close(); input = nil
        helper = nil // Watchdog receives EOF and restores its setting independently.
    }
}
