import AppKit
import CoreServices

/// A menu toggle. Off by the user's choice (Don't Allow, or turned off from the menu)
/// is persisted; authorization is checked on every launch.
final class SleepProtection {
    weak var menuItem: NSMenuItem? { didSet { updateMenu() } }
    weak var window: NSWindow?
    private(set) var authorized = false { didSet { updateMenu() } }
    private(set) var on = false { didSet { updateMenu() } }
    private let store: AppStore
    private var timer: Timer?
    /// The running lease; closing `input` ends it and restores sleep.
    private var lease: Process?
    private var input: FileHandle?
    /// Tasks are running and a lease is held.
    private var active = false
    private var checking = false
    private let queue = DispatchQueue(label: "vhostty.sleep")
    /// The user turned it off (Don't Allow, or from the menu): don't ask at launch.
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
        authorized = hasPermission()
        guard !FileManager.default.fileExists(atPath: declined.path) else { return }
        if authorized { enable() } else { configure() }
    }
    /// The menu item: turn off, turn on, or ask for authorization first.
    func toggle() {
        guard !checking, !isTest || fixture != nil else { return }
        if on {
            try? Data().write(to: declined, options: .atomic)
            stop()
        } else if authorized {
            try? FileManager.default.removeItem(at: declined)
            enable()
        } else {
            configure()
        }
    }
    private func configure() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep tasks running with the lid closed?")
        alert.informativeText = String(localized: "Your Mac stays awake with the lid closed while tasks run, then returns to normal sleep when they finish. Administrator authorization allows this Mac’s administrator accounts to run only these two commands without a password:\n\n/usr/bin/pmset -a disablesleep 1 — prevent sleep\n/usr/bin/pmset -a disablesleep 0 — restore sleep")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        let handle = { [self] (answer: NSApplication.ModalResponse) in
            checking = false
            if answer == .alertSecondButtonReturn {
                try? Data().write(to: declined, options: .atomic)
            } else if answer == .alertFirstButtonReturn {
                // A previous refusal no longer applies, including when authorization is cancelled.
                try? FileManager.default.removeItem(at: declined)
                authorize()
            }
        }
        // A sheet on the window doesn't bring Vhostty to the front and take focus.
        if let window, window.isVisible {
            checking = true
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
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
    /// Our own rule file, never a permission supplied by another app.
    static func hasInstalledRule(at url: URL) -> Bool {
        !authorizationRule.isEmpty && (try? String(contentsOf: url, encoding: .utf8)) == authorizationRule
    }
    private func hasPermission() -> Bool {
        if let fixture { return FileManager.default.fileExists(atPath: fixture.appendingPathComponent("authorized").path) }
        return Self.hasInstalledRule(at: Self.ruleURL)
    }
    /// What Allow does: install the rule (or confirm it), then enable.
    func authorize() {
        checking = true
        queue.async {
            var success = false
            if self.hasPermission() {
                success = true
            } else if let fixture = self.fixture {
                let outcome = (try? String(contentsOf: fixture.appendingPathComponent("authorization-result"))) ?? "cancel"
                success = outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "success"
                if success { try? Data().write(to: fixture.appendingPathComponent("authorized")) }
            } else if let source = Self.ruleResourceURL {
                // Copy the bundled static rule, validate, then install atomically.
                let target = Self.ruleURL.path
                let command = "umask 077; /bin/mkdir -p /private/etc/sudoers.d; t=$(/usr/bin/mktemp /private/etc/sudoers.d/.vhostty.XXXXXX) || exit 1; trap '/bin/rm -f \"$t\"' EXIT; /bin/cp " + Self.quote(source.path) + " \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/sbin/chown root:wheel \"$t\" && /bin/chmod 0444 \"$t\" && /bin/mv -f \"$t\" " + Self.quote(target)
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
                var error: NSDictionary?
                let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
                script?.executeAndReturnError(&error)
                success = error == nil && script != nil && self.hasPermission()
            }
            let ok = success
            DispatchQueue.main.async {
                self.checking = false
                if ok { self.enable() }
            }
        }
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func updateMenu() {
        menuItem?.title = authorized
            ? String(localized: "Closed-Lid Sleep Protection While Tasks Run")
            : String(localized: "Closed-Lid Sleep Protection While Tasks Run: Not Authorized…")
        menuItem?.state = on ? .on : .off
    }
    /// Authorization is in place: start following task activity.
    private func enable() {
        authorized = true
        on = true
        guard timer == nil else { return }
        requestAmphetamineConsent()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
        tick()
    }
    /// The helper failed. Show the actual state: unauthorized if the rule is gone.
    private func recheck() {
        if !hasPermission() { stop(); authorized = false }
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
        if store.workingAgentCount > 0 {
            // Each busy period starts one lease.
            if !active { active = true; spawn() }
        } else if active {
            active = false
            endLease()
        }
    }
    private func spawn() {
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vhostty-sleep")
        if let fixture { p.arguments = ["--test-dir", fixture.path] }
        p.standardError = FileHandle.nullDevice
        // Only the helper may hold the lease pipe, or a crash would not end the lease.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        p.standardInput = stdin; p.standardOutput = stdout
        // The helper reports "active" once applied, then "active"/"error" on re-applying.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard String(decoding: data, as: UTF8.self).split(separator: "\n").last == "error" else { return }
            DispatchQueue.main.async { self?.recheck() }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.lease === p { self.lease = nil; try? self.input?.close(); self.input = nil }
                if p.terminationStatus != 0 { self.recheck() }
            }
        }
        do { try p.run() } catch { recheck(); return }
        lease = p; input = stdin.fileHandleForWriting
    }
    private func endLease() {
        try? input?.close(); input = nil
        lease = nil // The helper sees EOF and restores sleep on its own.
    }
    func stop() {
        on = false
        timer?.invalidate(); timer = nil
        active = false
        endLease()
    }
}
