import AppKit
import CoreServices

/// Only an explicit refusal is persisted. Authorization is checked on every launch.
final class SleepProtection {
    weak var menuItem: NSMenuItem? { didSet { updateMenuTitle() } }
    private(set) var hasFailed = false { didSet { updateMenuTitle() } }
    private let store: AppStore
    private var timer: Timer?
    /// The running lease; closing `input` ends it and restores sleep.
    private var lease: Process?
    private var input: FileHandle?
    /// Inside a busy period (tasks running, or within 15 s after they stopped).
    private var active = false
    private var lastBusy = Date.distantPast
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
            catch { stop(); hasFailed = true }
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
                if allowed { self.enable() } else { self.configure() }
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
                if ok { self.enable() } else if !cancel { self.stop(); self.hasFailed = true }
            }
        }
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func updateMenuTitle() {
        menuItem?.title = hasFailed
            ? String(localized: "Closed-Lid Sleep Protection: Not Active…")
            : String(localized: "Closed-Lid Sleep Protection…")
    }
    func retry() {
        guard !checking, !isTest || fixture != nil else { return }
        authorize()
    }
    /// Authorization is in place: start following task activity.
    private func enable() {
        hasFailed = false
        if timer == nil {
            requestAmphetamineConsent()
            // Restore sleep a crashed helper may have left disabled.
            spawn(release: true)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
            tick()
        } else if active && lease == nil {
            spawn(release: false) // Retry from the menu during a busy period.
        }
    }
    /// The only place that may show the automation consent prompt, so it comes at launch
    /// (or when authorizing) and never from a helper started later.
    private func requestAmphetamineConsent() {
        guard fixture == nil else { return }
        DispatchQueue.global().async {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.if.Amphetamine").first else { return }
            let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
            _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x616d7068, typeWildCard, true) // amph
        }
    }
    private func tick() {
        if store.keepsAwake {
            lastBusy = Date()
            // Each busy period starts one lease; a failed one waits for the next period.
            if !active { active = true; spawn(release: false) }
        } else if active, -lastBusy.timeIntervalSinceNow >= 15 {
            active = false
            endLease()
        }
    }
    private func spawn(release: Bool) {
        let p = Process()
        p.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vhostty-sleep")
        p.arguments = [AppPaths.support.path] + (release ? ["--release"] : [])
        if let fixture { p.arguments! += ["--test-dir", fixture.path] }
        p.standardError = FileHandle.nullDevice
        var stdin: Pipe?, stdout: Pipe?
        if release {
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        } else {
            stdin = Pipe(); stdout = Pipe()
            // Only the helper may hold the lease pipe, or a crash would not end the lease.
            _ = fcntl(stdin!.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(stdin!.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            p.standardInput = stdin; p.standardOutput = stdout
            // The helper reports "active" once applied, then "active"/"error" on re-applying.
            stdout!.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last
                DispatchQueue.main.async { if self?.lease === p { self?.hasFailed = last == "error" } }
            }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.lease === p { self.lease = nil; try? self.input?.close(); self.input = nil }
                if p.terminationStatus != 0 { self.hasFailed = true }
            }
        }
        do { try p.run() } catch { hasFailed = true; return }
        if !release { lease = p; input = stdin?.fileHandleForWriting }
    }
    private func endLease() {
        try? input?.close(); input = nil
        lease = nil // The helper sees EOF and restores sleep on its own.
    }
    func stop() {
        timer?.invalidate(); timer = nil
        active = false
        endLease()
    }
}
