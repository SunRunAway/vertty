import AppKit
import SwiftUI
import UserNotifications
import GhosttyC

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, GhosttyRuntimeDelegate,
    UNUserNotificationCenterDelegate, NSMenuDelegate, NSMenuItemValidation {
    let store = AppStore.shared
    var window: NSWindow!
    private lazy var sleepProtection = SleepProtection(store: store)
    private var hookServer: HookServer?
    private var debugSnapshot: DebugSnapshot?
    private var fileMenu: NSMenu?
    private var newSessionItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            ShellEnvironment.load()
            ShellEnvironment.loadInteractive()
            DispatchQueue.main.async { AppStore.shared.shellEnvironmentLoaded() }
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
        store.activateSelection()

        if let dir = ProcessInfo.processInfo.environment["VHOSTTY_DEBUG_SNAPSHOT"] {
            // Test instances stay in the background so they don't steal the user's typing.
            debugSnapshot = DebugSnapshot(directory: dir, window: window, store: store)
            window.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { self.sleepProtection.start() }
    }

    @objc private func configureSleepProtection() { sleepProtection.configure() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Once authorized, the sleep protection item is only a checked status line.
        menuItem.action == #selector(configureSleepProtection) ? !sleepProtection.authorized : true
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
        let sleepItem = item("Closed-Lid Sleep Protection While Tasks Run: Not Authorized…", #selector(configureSleepProtection), "")
        sleepProtection.menuItem = sleepItem
        appMenu.addItem(sleepItem)
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
        view.addItem(item("Show/Hide Sidebar", #selector(toggleSidebar), "s", [.command, .control]))
        view.addItem(item("Show/Hide Terminal", #selector(toggleShell), "j"))
        // Second shortcut (VS Code's ⌃`): a hidden item that still answers its key.
        let altToggle = item("Show/Hide Terminal", #selector(toggleShell), "`", [.control])
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

    @objc private func newSession() { store.newSession() }
    @objc private func newOtherSession() {
        guard let p = store.currentProject else { return store.newSession() }
        store.newSession(in: p, kind: store.kindsDefaultFirst(p)[1])
    }

    /// The File menu's first "New … Session" (⌘T) is the current project's default kind.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === fileMenu else { return }
        let kinds = store.currentProject.map(store.kindsDefaultFirst) ?? AgentKind.allCases
        for (item, kind) in zip(newSessionItems, kinds) {
            item.title = String(localized: kind == .claude ? "New Claude Session" : "New Codex Session")
        }
    }

    @objc private func addProject() { store.addProjectViaPanel() }
    @objc private func closeTab() { store.closeSelected() }
    @objc private func nextTab() { store.gotoTab(.next) }
    @objc private func previousTab() { store.gotoTab(.previous) }
    @objc private func selectTabByTag(_ sender: NSMenuItem) { store.selectTab(at: sender.tag - 1) }
    @objc private func showMainWindow() { window.makeKeyAndOrderFront(nil) }
    @objc private func reloadConfig() { GhosttyRuntime.shared.reloadConfig() }
    @objc private func openGhosttyConfig() {
        if let app = GhosttyRuntime.shared.app { ghostty_app_open_config(app) }
    }
    @objc private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { store.sidebarVisible.toggle() }
        store.scheduleSave()
    }
    @objc private func toggleShell() { store.toggleShell() }
    @objc private func focusAgentPane() { store.focusPane(shell: false) }
    @objc private func focusShellPane() { store.focusPane(shell: true) }
    @objc private func fontBigger() { store.selectedTab?.surface?.perform(action: "increase_font_size:1") }
    @objc private func fontSmaller() { store.selectedTab?.surface?.perform(action: "decrease_font_size:1") }
    @objc private func fontReset() { store.selectedTab?.surface?.perform(action: "reset_font_size") }

    // MARK: - GhosttyRuntimeDelegate

    func ghosttyNewTab(from surface: TerminalSurfaceView?) {
        if let surface, let tab = store.tab(for: surface), let p = store.project(tab.projectID) {
            store.newSession(in: p)
        } else {
            store.newSession()
        }
    }

    func ghosttyCloseTab(_ surface: TerminalSurfaceView) {
        if let tab = store.tab(for: surface) { store.requestClose(tab) }
    }

    func ghosttyGotoTab(_ target: GhosttyGotoTab) { store.gotoTab(target) }

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
        let idString = response.notification.request.content.userInfo["tab"] as? String
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
