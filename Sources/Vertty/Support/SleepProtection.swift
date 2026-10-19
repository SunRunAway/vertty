import AppKit
import CoreServices

/// A menu toggle. Launch asks only until the user has decided once (Don't Allow, or a
/// successful authorization); authorization itself is checked on every launch.
final class SleepProtection: NSObject {
    weak var menuItem: NSMenuItem? { didSet { updateMenu() } }
    private weak var continuousMenuItem: NSMenuItem?
    private weak var untilItem: NSMenuItem?
    weak var window: NSWindow?
    private(set) var authorized = false { didSet { updateMenu() } }
    private(set) var on = false { didSet { updateMenu() } }
    /// nil is off; zero is indefinite; positive values are seconds from selection.
    private(set) var continuousDuration: TimeInterval?
    private(set) var continuousUntil: Date?
    private let now: () -> Date
    private let store: AppStore
    private var timer: Timer?
    /// The running lease; closing `input` ends it and restores sleep.
    private var lease: Process?
    private var input: FileHandle?
    /// Either task activity or a manual session needs a lease.
    private var active = false
    private var checking = false { didSet { updateMenu() } }
    private let queue = DispatchQueue(label: "vertty.sleep")
    /// The user has decided once: never ask at launch again.
    private var asked: URL { AppPaths.support.appendingPathComponent("sleep-asked") }
    /// Turned off from the menu.
    private var off: URL { AppPaths.support.appendingPathComponent("sleep-off") }
    private var isTest: Bool { ProcessInfo.processInfo.environment["VERTTY_DEBUG_SNAPSHOT"] != nil }
    private var fixture: URL? {
        guard isTest, ProcessInfo.processInfo.environment["VERTTY_SUPPORT_DIR"] != nil,
              let path = ProcessInfo.processInfo.environment["VERTTY_SLEEP_TEST_DIR"] else { return nil }
        return URL(fileURLWithPath: path)
    }
    init(store: AppStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        super.init()
    }

    func makeContinuousMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Continuous Closed-Lid Sleep Protection"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let until = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        until.isEnabled = false
        submenu.addItem(until)
        untilItem = until
        let choices: [(String.LocalizationValue, Int)] = [
            ("Off", -1), ("15 Minutes", 900), ("30 Minutes", 1800),
            ("1 Hour", 3600), ("2 Hours", 7200), ("3 Hours", 10800),
            ("6 Hours", 21600), ("12 Hours", 43200), ("24 Hours", 86400),
            ("Indefinitely", 0)
        ]
        for (title, seconds) in choices {
            let choice = NSMenuItem(title: String(localized: title), action: #selector(selectContinuous(_:)), keyEquivalent: "")
            choice.tag = seconds
            choice.target = self
            submenu.addItem(choice)
            if seconds == -1 { submenu.addItem(.separator()) }
        }
        submenu.addItem(.separator())
        let note = NSMenuItem(title: String(localized: "Ends when Vertty quits"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        parent.submenu = submenu
        continuousMenuItem = parent
        updateMenu()
        return parent
    }

    @objc private func selectContinuous(_ sender: NSMenuItem) {
        guard !checking, !isTest || fixture != nil else { return }
        if sender.tag < 0 {
            continuousDuration = nil
            continuousUntil = nil
            monitor()
        } else if authorized {
            enableContinuous(TimeInterval(sender.tag))
        } else {
            configure(continuousDuration: TimeInterval(sender.tag))
        }
    }

    private func enableContinuous(_ duration: TimeInterval) {
        authorized = true
        continuousDuration = duration
        continuousUntil = duration > 0 ? now().addingTimeInterval(duration) : nil
        monitor()
    }

    func start() {
        // Ordinary debug instances must never touch real power settings or authorization.
        guard !isTest || fixture != nil else { return }
        authorized = hasPermission()
        if authorized {
            try? Data().write(to: asked, options: .atomic)
            if !FileManager.default.fileExists(atPath: off.path) { enable() }
        } else if !FileManager.default.fileExists(atPath: asked.path) {
            configure()
        }
    }
    /// The menu item: turn off, turn on, or ask for authorization first.
    func toggle() {
        guard !checking, !isTest || fixture != nil else { return }
        if on {
            try? Data().write(to: off, options: .atomic)
            on = false
            monitor()
        } else if authorized {
            try? FileManager.default.removeItem(at: off)
            enable()
        } else {
            configure()
        }
    }
    private func configure(continuousDuration: TimeInterval? = nil) {
        let alert = NSAlert()
        if continuousDuration != nil {
            alert.messageText = String(localized: "Keep your Mac awake with the lid closed?")
            alert.informativeText = String(localized: "Your Mac stays awake with the lid closed for the selected duration, even when no tasks are running. Protection ends when you turn it off or quit Vertty. Administrator authorization allows this Mac’s administrator accounts to run only these two commands without a password:\n\n/usr/bin/pmset -a disablesleep 1 — prevent sleep\n/usr/bin/pmset -a disablesleep 0 — restore sleep")
        } else {
            alert.messageText = String(localized: "Keep tasks running with the lid closed?")
            alert.informativeText = String(localized: "Your Mac stays awake with the lid closed while tasks run, then returns to normal sleep when they finish. Administrator authorization allows this Mac’s administrator accounts to run only these two commands without a password:\n\n/usr/bin/pmset -a disablesleep 1 — prevent sleep\n/usr/bin/pmset -a disablesleep 0 — restore sleep")
        }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        let handle = { [self] (answer: NSApplication.ModalResponse) in
            checking = false
            if answer == .alertSecondButtonReturn {
                try? Data().write(to: asked, options: .atomic)
            } else if answer == .alertFirstButtonReturn {
                authorize(continuousDuration: continuousDuration)
            }
        }
        // A sheet on the window doesn't bring Vertty to the front and take focus.
        if let window, window.isVisible {
            checking = true
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
    private static var ruleURL: URL {
        URL(fileURLWithPath: "/private/etc/sudoers.d/vertty_sleep")
    }
    private static var ruleResourceURL: URL? {
        Bundle.main.url(forResource: "vertty-sleep", withExtension: "sudoers")
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
    func authorize(continuousDuration: TimeInterval? = nil) {
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
                let command = "umask 077; /bin/mkdir -p /private/etc/sudoers.d; t=$(/usr/bin/mktemp /private/etc/sudoers.d/.vertty.XXXXXX) || exit 1; trap '/bin/rm -f \"$t\"' EXIT; /bin/cp " + Self.quote(source.path) + " \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/sbin/chown root:wheel \"$t\" && /bin/chmod 0444 \"$t\" && /bin/mv -f \"$t\" " + Self.quote(target)
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
                var error: NSDictionary?
                let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
                script?.executeAndReturnError(&error)
                success = error == nil && script != nil && self.hasPermission()
            }
            let ok = success
            DispatchQueue.main.async {
                self.checking = false
                // A cancelled or failed authorization records nothing.
                if ok {
                    try? Data().write(to: self.asked, options: .atomic)
                    if let continuousDuration {
                        // Authorizing the manual mode must not enable task protection on
                        // the next launch if it was off before authorization.
                        if !self.on { try? Data().write(to: self.off, options: .atomic) }
                        self.enableContinuous(continuousDuration)
                    } else {
                        try? FileManager.default.removeItem(at: self.off)
                        self.enable()
                    }
                }
            }
        }
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func updateMenu() {
        menuItem?.title = authorized
            ? String(localized: "Closed-Lid Sleep Protection While Tasks Run")
            : String(localized: "Closed-Lid Sleep Protection While Tasks Run: Not Authorized…")
        menuItem?.state = on ? .on : .off
        continuousMenuItem?.state = continuousDuration == nil ? .off : .on
        for item in continuousMenuItem?.submenu?.items ?? [] where item.action == #selector(selectContinuous(_:)) {
            item.state = (continuousDuration.map { $0 == TimeInterval(item.tag) } ?? (item.tag == -1)) ? .on : .off
            item.isEnabled = !checking
        }
        untilItem?.isHidden = continuousUntil == nil
        if let continuousUntil {
            let end = DateFormatter.localizedString(from: continuousUntil, dateStyle: .short, timeStyle: .short)
            untilItem?.title = String(format: String(localized: "Until %@"), end)
        }
    }
    /// Authorization is in place: start following task activity.
    private func enable() {
        authorized = true
        on = true
        monitor()
    }
    private func monitor() {
        if on || continuousDuration != nil {
            if timer == nil {
                requestAmphetamineConsent()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
            }
        } else {
            timer?.invalidate(); timer = nil
        }
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
        if let continuousUntil, now() >= continuousUntil {
            continuousDuration = nil
            self.continuousUntil = nil
            if !on { timer?.invalidate(); timer = nil }
        }
        updateMenu()
        if continuousDuration != nil || (on && store.workingAgentCount > 0) {
            // Both modes share one lease. Wait for a previous helper to finish restoring
            // before starting another, including rapid Off -> On menu selections.
            if !active { active = true; if lease == nil { spawn() } }
        } else if active {
            active = false
            endLease()
        }
    }
    private func spawn() {
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vertty-sleep")
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
                guard self.lease === p else { return }
                let wasEnding = self.input == nil
                self.lease = nil; try? self.input?.close(); self.input = nil
                if p.terminationStatus != 0 { self.recheck() }
                if wasEnding && self.active { self.spawn() }
            }
        }
        do { try p.run() } catch { recheck(); return }
        lease = p; input = stdin.fileHandleForWriting
    }
    private func endLease() {
        try? input?.close(); input = nil
        // Keep the process until it exits, so its restore cannot race a new lease.
    }
    func stop() {
        on = false
        continuousDuration = nil
        continuousUntil = nil
        updateMenu()
        timer?.invalidate(); timer = nil
        active = false
        endLease()
    }
}
