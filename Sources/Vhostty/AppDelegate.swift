import AppKit
import SwiftUI
import UserNotifications
import GhosttyC
import VhosttyRemote

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, GhosttyRuntimeDelegate,
    UNUserNotificationCenterDelegate, NSMenuDelegate, NSMenuItemValidation {
    let store = AppStore.shared
    var window: NSWindow!
    private lazy var sleepProtection = SleepProtection(store: store)
    private lazy var displayAwake = DisplayAwake(store: store)
    private lazy var remoteServer = RemoteServer(store: store)
    private var pendingScheduleURL: URL?
    private var hookServer: HookServer?
    private var debugSnapshot: DebugSnapshot?
    private var fileMenu: NSMenu?
    private var appMenu: NSMenu?
    /// See updateRemoteInfoItems.
    private let remoteInfoItems: [NSMenuItem] = (0..<2).map { _ in
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        item.isEnabled = false
        item.isHidden = true
        return item
    }
    private var newSessionItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            ShellEnvironment.load()
            ShellEnvironment.loadInteractive()
            DispatchQueue.main.async {
                AppStore.shared.shellEnvironmentLoaded()
                // VHOSTTY_REMOTE_PORT comes from the login shell.
                self.remoteServer.startIfEnabled()
            }
        }

        guard GhosttyRuntime.shared.start() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Failed to start the terminal engine")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        GhosttyRuntime.shared.delegate = self
        if let bg = GhosttyRuntime.shared.backgroundColor { store.terminalBackground = Color(nsColor: bg) }

        ClaudeLauncher.writeSettings()
        hookServer = HookServer(socketPath: AppPaths.hookSocket) { [weak self] event in
            self?.store.handleHook(event)
        }
        hookServer?.onScheduleRequest = { [weak self] request in
            self?.store.handleScheduleRequest(request) ?? ["ok": false, "error": "Vhostty is quitting."]
        }
        hookServer?.start()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        store.load()
        buildMenu()
        createWindow()
        sleepProtection.window = window
        store.window = window
        store.activateSelection()
        if let url = pendingScheduleURL {
            pendingScheduleURL = nil
            openScheduleURL(url)
        }

        if let dir = ProcessInfo.processInfo.environment["VHOSTTY_DEBUG_SNAPSHOT"] {
            // Test instances stay in the background so they don't steal the user's typing.
            debugSnapshot = DebugSnapshot(directory: dir, window: window, store: store)
            window.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { self.sleepProtection.start() }
        displayAwake.start()
    }

    @objc private func toggleSleepProtection() { sleepProtection.toggle() }
    @objc private func toggleDisplayAwake() { displayAwake.setEnabled(!displayAwake.enabled) }
    @objc private func toggleRemoteConnections() { remoteServer.setEnabled(!remoteServer.enabled) }

    @objc private func setNewProjectAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AgentKind(rawValue: raw) else { return }
        store.setNewProjectKind(kind)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setNewProjectAgent(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == store.globalDefaultKind.rawValue ? .on : .off
        } else if menuItem.action == #selector(toggleSidebar) {
            menuItem.title = store.sidebarVisible ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        } else if menuItem.action == #selector(toggleDisplayAwake) {
            menuItem.state = displayAwake.enabled ? .on : .off
        } else if menuItem.action == #selector(toggleRemoteConnections) {
            menuItem.state = remoteServer.enabled ? .on : .off
        } else if menuItem.action == #selector(toggleShell) {
            menuItem.title = store.selectedTab?.shellVisible == true ? String(localized: "Hide Terminal") : String(localized: "Show Terminal")
            // Remote windows have no bottom shell.
            return store.selectedTab != nil && RemoteWindowController.key == nil
        }
        return true
    }

    private func createWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Vhostty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(store.terminalBackground)
        window.isOpaque = true
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView(store: store))
        window.center()
        window.setFrameAutosaveName("VhosttyMainWindow")
        if ProcessInfo.processInfo.environment["VHOSTTY_DEBUG_SNAPSHOT"] == nil {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openScheduleURL(url) }
    }

    func openScheduleURL(_ url: URL) {
        guard let id = ScheduleTask.id(from: url) else { return }
        guard window != nil else { pendingScheduleURL = url; return }
        guard store.schedules.task(id) != nil else { return }
        // The panel opens beside whatever is on screen, without switching to
        // the task page; the same link again closes it.
        store.toggleScheduledTask(id)
        if ProcessInfo.processInfo.environment["VHOSTTY_DEBUG_SNAPSHOT"] == nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = store.workingAgentCount
        if working > 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit Vhostty?")
            alert.informativeText = String(localized: "\(working) agents are working. Quitting will interrupt their current tasks.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.save()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepProtection.stop()
        displayAwake.stop()
        store.save()
        unlink(AppPaths.hookSocket)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let tab = store.selectedTab, tab.attention {
            tab.attention = false
            store.updateDockBadge()
        }
        store.terminalContainer?.focusCurrent()
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Vhostty"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let agentMenu = NSMenu()
        for kind in AgentKind.allCases {
            let choice = item(kind == .claude ? "Claude Code" : "Codex", #selector(setNewProjectAgent(_:)), "")
            choice.representedObject = kind.rawValue
            agentMenu.addItem(choice)
        }
        addSubmenu(appMenu, "Default Agent for New Projects", agentMenu)
        appMenu.addItem(.separator())
        let sleepItem = item("Closed-Lid Sleep Protection While Tasks Run: Not Authorized…", #selector(toggleSleepProtection), "")
        sleepProtection.menuItem = sleepItem
        appMenu.addItem(sleepItem)
        appMenu.addItem(item("Don’t Let the Display Turn Off", #selector(toggleDisplayAwake), ""))
        appMenu.addItem(item("Allow Remote Connections", #selector(toggleRemoteConnections), ""))
        for info in remoteInfoItems { appMenu.addItem(info) }
        appMenu.delegate = self
        self.appMenu = appMenu
        appMenu.addItem(item("Open Ghostty Config", #selector(openGhosttyConfig), ""))
        appMenu.addItem(item("Reload Config", #selector(reloadConfig), "r", [.command, .shift]))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Vhostty"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Vhostty"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(main, "Vhostty", appMenu)

        let file = NSMenu()
        newSessionItems = [
            item("New Claude Session", #selector(newSession), "t"),
            item("New Codex Session", #selector(newOtherSession), ""),
        ]
        newSessionItems.forEach(file.addItem)
        file.addItem(item("Add Project…", #selector(addProject), "o", [.command, .shift]))
        file.addItem(item("Connect to Remote Computer…", #selector(connectRemote), "k", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Close Session", #selector(closeTab), "w"))
        addSubmenu(main, "File", file)
        fileMenu = file
        file.delegate = self

        let edit = NSMenu()
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(main, "Edit", edit)

        let view = NSMenu()
        view.addItem(item("Hide Sidebar", #selector(toggleSidebar), "s", [.command, .control]))
        view.addItem(item("Show Terminal", #selector(toggleShell), "j"))
        // Second shortcut (VS Code's ⌃`): a hidden item that still answers its key.
        let altToggle = item("Show Terminal", #selector(toggleShell), "`", [.control])
        altToggle.isHidden = true
        altToggle.allowsKeyEquivalentWhenHidden = true
        view.addItem(altToggle)
        view.addItem(item("Focus Agent", #selector(focusAgentPane), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        view.addItem(item("Focus Terminal", #selector(focusShellPane), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Increase Font Size", #selector(fontBigger), "="))
        view.addItem(item("Decrease Font Size", #selector(fontSmaller), "-"))
        view.addItem(item("Actual Size", #selector(fontReset), "0"))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        addSubmenu(main, "View", view)

        let win = NSMenu()
        win.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(item("Next Session", #selector(nextTab), "]", [.command, .shift]))
        win.addItem(item("Previous Session", #selector(previousTab), "[", [.command, .shift]))
        for i in 1...9 {
            let it = item("Session \(i)", #selector(selectTabByTag(_:)), "\(i)")
            it.tag = i
            win.addItem(it)
        }
        win.addItem(.separator())
        win.addItem(item("Main Window", #selector(showMainWindow), ""))
        addSubmenu(main, "Window", win)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func item(_ title: String.LocalizationValue, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    private func addSubmenu(_ main: NSMenu, _ key: String.LocalizationValue, _ menu: NSMenu) {
        let title = String(localized: key)
        menu.title = title
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    @objc private func newSession() {
        if let remote = RemoteWindowController.key {
            if let p = remote.store.currentProject { remote.store.newSession(in: p, kind: nil) }
            return
        }
        store.newSession()
    }
    @objc private func newOtherSession() {
        if let remote = RemoteWindowController.key {
            if let p = remote.store.currentProject { remote.store.newSession(in: p, kind: remote.store.kindsDefaultFirst(p)[1]) }
            return
        }
        guard let p = store.currentProject else { return store.newSession() }
        store.newSession(in: p, kind: store.kindsDefaultFirst(p)[1])
    }
    @objc private func connectRemote() { RemoteWindowController.connectViaPrompt() }

    /// Gray lines under "Allow Remote Connections" while it's on, like the
    /// details under the Wi-Fi network in the menu bar: the port and who is
    /// connected, or why the service couldn't start.
    private func updateRemoteInfoItems() {
        let (first, second) = (remoteInfoItems[0], remoteInfoItems[1])
        switch remoteServer.status {
        case .off:
            first.isHidden = true
            second.isHidden = true
        case .failed(let reason):
            first.title = String(localized: "Failed to start: \(reason)")
            first.isHidden = false
            second.isHidden = true
        case .starting(let port), .listening(let port):
            first.title = String(localized: "Port: \(String(port))")
            let client = remoteServer.client.map { c in
                let name = c.deviceName.isEmpty ? Self.deviceKind(c.platform) : c.deviceName
                return String(localized: "\(name), connected since \(c.since.formatted(date: .omitted, time: .shortened))")
            } ?? String(localized: "Not connected")
            second.title = String(localized: "Remote client: \(client)")
            first.isHidden = false
            second.isHidden = false
        }
    }

    private static func deviceKind(_ platform: Remote.ClientPlatform) -> String {
        switch platform {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        default: "Mac"
        }
    }

    /// The File menu's first "New … Session" (⌘T) is the current project's default kind.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === appMenu { return updateRemoteInfoItems() }
        guard menu === fileMenu else { return }
        let kinds = store.currentProject.map(store.kindsDefaultFirst) ?? AgentKind.allCases
        for (item, kind) in zip(newSessionItems, kinds) {
            item.title = String(localized: kind == .claude ? "New Claude Session" : "New Codex Session")
        }
    }

    @objc private func addProject() { store.addProjectViaPanel() }
    /// In a remote window, ⌘W closes the window (never a session here).
    @objc private func closeTab() {
        if let remote = RemoteWindowController.key { return remote.window.performClose(nil) }
        store.closeSelected()
    }
    @objc private func nextTab() { gotoTab(.next) }
    @objc private func previousTab() { gotoTab(.previous) }
    @objc private func selectTabByTag(_ sender: NSMenuItem) {
        if let remote = RemoteWindowController.key { return remote.store.selectCard(at: sender.tag - 1) }
        store.selectTab(at: sender.tag - 1)
    }

    private func gotoTab(_ target: GhosttyGotoTab) {
        if let remote = RemoteWindowController.key { remote.store.gotoCard(target) } else { store.gotoTab(target) }
    }

    /// The terminal font size actions apply to: the remote window's, else the selected session's.
    private var fontTarget: TerminalSurfaceView? {
        RemoteWindowController.key.map { $0.terminal.view } ?? store.selectedTab?.surface
    }
    @objc private func showMainWindow() { window.makeKeyAndOrderFront(nil) }
    @objc private func reloadConfig() { GhosttyRuntime.shared.reloadConfig() }
    @objc private func openGhosttyConfig() {
        if let app = GhosttyRuntime.shared.app { ghostty_app_open_config(app) }
    }
    @objc private func toggleSidebar() {
        store.toggleSidebar()
    }
    @objc private func toggleShell() {
        guard RemoteWindowController.key == nil else { return }
        store.toggleShell()
    }
    @objc private func focusAgentPane() { store.focusPane(shell: false) }
    @objc private func focusShellPane() { store.focusPane(shell: true) }
    @objc private func fontBigger() { fontTarget?.perform(action: "increase_font_size:1") }
    @objc private func fontSmaller() { fontTarget?.perform(action: "decrease_font_size:1") }
    @objc private func fontReset() { fontTarget?.perform(action: "reset_font_size") }

    // MARK: - GhosttyRuntimeDelegate

    func ghosttyNewTab(from surface: TerminalSurfaceView?) {
        if let remote = RemoteWindowController.owner(of: surface) ?? (surface == nil ? RemoteWindowController.key : nil) {
            if let p = remote.store.currentProject { remote.store.newSession(in: p, kind: nil) }
            return
        }
        if let surface, let tab = store.tab(for: surface), let p = store.project(tab.projectID) {
            store.newSession(in: p)
        } else {
            store.newSession()
        }
    }

    func ghosttyCloseTab(_ surface: TerminalSurfaceView) {
        if let remote = RemoteWindowController.owner(of: surface) { return remote.window.performClose(nil) }
        if let tab = store.tab(for: surface) { store.requestClose(tab) }
    }

    func ghosttyGotoTab(_ target: GhosttyGotoTab) { gotoTab(target) }

    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_UP: store.focusPane(shell: false)
        case GHOSTTY_GOTO_SPLIT_DOWN: store.focusPane(shell: true)
        case GHOSTTY_GOTO_SPLIT_PREVIOUS, GHOSTTY_GOTO_SPLIT_NEXT: store.focusPane(shell: nil)
        default: break
        }
    }

    func ghosttySurfaceRequestedClose(_ surface: TerminalSurfaceView, processAlive: Bool) {
        store.surfaceRequestedClose(surface, processAlive: processAlive)
    }

    func ghosttyDesktopNotification(_ surface: TerminalSurfaceView?, title: String, body: String) {
        // Claude Code reports through hooks; plain OSC 9/777 notifications only
        // matter when the tab isn't in front.
        // Claude Code's own notification (it detects Ghostty via TERM_PROGRAM).
        // Like Ghostty, only show it when that session isn't what you're looking at.
        guard let surface, let tab = store.tab(for: surface) else { return }
        NSLog("Vhostty: desktop notification from tab %@: %@ / %@", tab.id.uuidString, title, body)
        // The remote client decides for itself whether it's looking at the card.
        remoteServer.notify(tab, title: title, body: body)
        if tab.id == store.selectedTabID && NSApp.isActive && window.isKeyWindow { return }
        // The idle reminder fires 60s after the turn ended. If you saw the reply
        // (the card isn't unread), switching away since doesn't make it news.
        if AppStore.isIdleReminder(title + " " + body) && !tab.attention { return }
        tab.attention = true
        store.updateDockBadge()
        store.notify(tab, body: body.isEmpty ? title : body)
    }

    func ghosttyBell(_ surface: TerminalSurfaceView) {
        guard let tab = store.tab(for: surface), tab.id != store.selectedTabID || !NSApp.isActive else { return }
        tab.attention = true
        store.updateDockBadge()
    }

    // MARK: - Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let idString = info["tab"] as? String
        if let storeID = info["remoteStore"] as? String, let cardID = info["remoteCard"] as? String {
            DispatchQueue.main.async {
                guard let remote = RemoteWindowController.withStore(storeID) else { return }
                if let card = remote.store.card(UUID(uuidString: cardID)) { remote.store.select(card) }
                remote.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return completionHandler()
        }
        DispatchQueue.main.async {
            if let idString, let id = UUID(uuidString: idString), let tab = self.store.tab(withID: id) {
                self.store.select(tab)
            }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
