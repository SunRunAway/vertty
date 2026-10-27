import AppKit
import GhosttyC
import UserNotifications
import VerttyRemote
import VerttyTailnet

/// Development aid: with VERTTY_DEBUG_SNAPSHOT=<dir>, periodically writes a PNG of
/// the window and a text dump of the app state and visible terminal text, so the
/// UI can be checked without screen-recording permission.
final class DebugSnapshot {
    private let directory: URL
    private weak var window: NSWindow?
    private let store: AppStore
    private var timer: Timer?
    /// Window images are taken and PNGs encoded off the main thread: either
    /// can take seconds on a busy machine and would stall the app it watches.
    private let imageQueue = DispatchQueue(label: "vertty.debug-snapshot.images")
    private var shots: [(CGWindowID, String)] = []
    private var shooting = false

    init(directory: String, window: NSWindow, store: AppStore) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.window = window
        self.store = store
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.capture() }
        // Keep driving while an alert is up.
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    /// Commands from <dir>/input.txt (consumed on read), one per line. Input only
    /// ever goes to a tab named explicitly with `to <tab uuid>`, never to "whatever
    /// is selected", so a test can't type into a real session by accident.
    ///   to <uuid> / toshell <uuid> · text <s> · enter · down · up · esc ·
    ///   select <uuid> · new · notify · toggleshell · focus claude|shell ·
    ///   post <ctrl|cmd|none> <char> · postclick|postscroll <x> <y> ·
    ///   remotepostclick|remotepostscroll <x> <y> · schedules · schedule <task uuid> ·
    ///   runschedule <task uuid> · tickschedules · newschedule · closepanel ·
    ///   panelsave · panelcancel · windowclick <number> <x> <y> · windowtext <number> <text> ·
    ///   sheetkey return|escape (the open sheet or alert)
    /// The app menu's Remote Connections submenu.
    private static var remoteMenu: NSMenu? {
        NSApp.mainMenu?.items.first?.submenu?.items.compactMap(\.submenu).first {
            $0.items.contains { $0.action == NSSelectorFromString("toggleRemoteMode:") }
        }
    }

    /// postclick|postscroll <x> <y>, in window-local points from the top left.
    private static func postMouse(_ line: String, in window: NSWindow) {
        let parts = line.split(separator: " ")
        guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]),
              let view = window.contentView else { return }
        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        guard view.bounds.contains(local) else { return }
        let point = view.convert(local, to: nil)
        if parts[0] == "postscroll" {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0) else { return }
            let screen = window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            // Field 51 is the event's window number (NSEvent.windowNumber).
            cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
            return
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func drive() {
        let url = directory.appendingPathComponent("input.txt")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        var target: TabSession?
        var targetShell = false
        for line in content.split(separator: "\n").map(String.init) {
            if line == "checkupdates", let menu = NSApp.mainMenu?.items.first?.submenu,
               let index = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("checkForUpdates:") }) {
                RunLoop.main.perform(inModes: [.default, .modalPanel]) { menu.performActionForItem(at: index) }
                continue
            }
            if line.hasPrefix("windowbutton ") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count == 3, let number = Int(parts[1]),
                   let targetWindow = NSApp.windows.first(where: { $0.windowNumber == number && $0.isVisible }),
                   let view = targetWindow.contentView,
                   let button = Self.buttons(in: view).first(where: { $0.title == parts[2] && $0.isEnabled }) {
                    // An install action may synchronously enter the quit confirmation's
                    // modal loop. Let this timer return so it can keep driving that loop.
                    RunLoop.main.perform(inModes: [.default, .modalPanel]) { button.performClick(nil) }
                }
                continue
            }
            // Window-local points from the top left; never clicks another app.
            if line.hasPrefix("click ") || line.hasPrefix("cmdclick "), let window {
                let parts = line.split(separator: " ")
                if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]),
                   let view = window.contentView {
                    let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
                    guard view.bounds.contains(local) else { continue }
                    let point = view.convert(local, to: nil)
                    window.makeKey()
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: line.hasPrefix("cmdclick ") ? [.command] : [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: 1) {
                            if type == .leftMouseDown {
                                view.hitTest(local)?.mouseMoved(with: event)
                                view.hitTest(local)?.mouseDown(with: event)
                            } else {
                                view.hitTest(local)?.mouseUp(with: event)
                            }
                        }
                    }
                }
                continue
            }
            // postclick|postscroll <x> <y>: queue a real click or scroll at a
            // window-local point, dispatched by AppKit like hardware input.
            if line.hasPrefix("postclick ") || line.hasPrefix("postscroll "), let window {
                Self.postMouse(line, in: window)
                continue
            }
            // Auxiliary controls (e.g. a popover), confined to this test instance.
            if line.hasPrefix("windowclick ") || line.hasPrefix("windowtext ") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count == 3, let number = Int(parts[1]),
                   let targetWindow = NSApp.windows.first(where: { $0.windowNumber == number && $0.isVisible }) {
                    if parts[0] == "windowclick" {
                        Self.postMouse("postclick " + parts[2], in: targetWindow)
                    } else if let input = targetWindow.firstResponder as? NSTextView, input.isFieldEditor {
                        input.insertText(parts[2], replacementRange: NSRange(location: 0, length: input.string.utf16.count))
                    }
                }
                continue
            }
            if line.hasPrefix("remotepostclick ") || line.hasPrefix("remotepostscroll "),
               let remote = RemoteWindowController.all.last {
                Self.postMouse(String(line.dropFirst(6)), in: remote.window)
                continue
            }
            if line.hasPrefix("alertbutton "), let index = Int(line.dropFirst(12)),
               let modal = window?.attachedSheet ?? NSApp.modalWindow {
                let buttons = modal.contentView.map { Self.buttons(in: $0) } ?? []
                if buttons.indices.contains(index) { buttons[index].performClick(nil) }
                continue
            }
            if line.hasPrefix("toggleagent "),
               let menu = NSApp.mainMenu?.items.first?.submenu?.items.compactMap(\.submenu).first(where: {
                   $0.items.contains { $0.action == NSSelectorFromString("toggleAgent:") }
               }), let index = menu.items.firstIndex(where: {
                   ($0.representedObject as? String) == String(line.dropFirst(12))
               }) {
                // Like a click: a disabled item does nothing.
                menu.update()
                if menu.items[index].isEnabled { menu.performActionForItem(at: index) }
                continue
            }
            if line.hasPrefix("addproject ") {
                store.addProject(at: URL(fileURLWithPath: String(line.dropFirst(11))))
                continue
            }
            if line.hasPrefix("to ") {
                target = UUID(uuidString: String(line.dropFirst(3))).flatMap { store.tab(withID: $0) }
                targetShell = false
                continue
            }
            if line.hasPrefix("toshell ") {
                target = UUID(uuidString: String(line.dropFirst(8))).flatMap { store.tab(withID: $0) }
                targetShell = true
                continue
            }
            if line.hasPrefix("menukey ") {
                // menukey <ctrl|cmd> <char>: route a shortcut through the main menu.
                let parts = line.split(separator: " ").map(String.init)
                if parts.count == 3, let window = window {
                    let mods: NSEvent.ModifierFlags = parts[1] == "ctrl" ? [.control] : [.command]
                    if let ev = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: parts[2],
                        charactersIgnoringModifiers: parts[2], isARepeat: false, keyCode: parts[2] == "`" ? 0x32 : 0x26) {
                        _ = NSApp.mainMenu?.performKeyEquivalent(with: ev)
                    }
                }
                continue
            }
            if line.hasPrefix("post ") {
                // post <ctrl|cmd|none> <char>: queue a real key press, dispatched by
                // AppKit like hardware input (key equivalents, then first responder).
                let parts = line.split(separator: " ").map(String.init)
                if parts.count == 3, let window = window {
                    window.makeKey()
                    let mods: NSEvent.ModifierFlags = parts[1] == "ctrl" ? [.control] : parts[1] == "cmd" ? [.command] : []
                    let ch = parts[2]
                    let code: UInt16 = ch == "`" ? 0x32 : ch == "j" ? 0x26 : ch == "x" ? 0x07 : ch == "q" ? 0x0C : 0x00
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let ev = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: ch,
                            charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(ev, atStart: false)
                        }
                    }
                }
                continue
            }
            if line == "cmdj-through-terminal", let window = window, let surface = store.selectedTab?.surface {
                // Mirror AppKit's key-equivalent routing: the window's view tree
                // first (our terminal), then the main menu.
                window.makeFirstResponder(surface)
                if let ev = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "j",
                    charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 0x26) {
                    let byView = window.performKeyEquivalent(with: ev)
                    let byMenu = byView ? false : (NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false)
                    try? "terminalConsumed=\(byView) menuHandled=\(byMenu)".write(
                        to: directory.appendingPathComponent("keyequiv.txt"), atomically: true, encoding: .utf8)
                }
                continue
            }
            if line == "toggleshell" {
                store.toggleShell()
                continue
            }
            if line.hasPrefix("focus ") {
                store.focusPane(shell: line.hasSuffix("shell"))
                continue
            }
            if line.hasPrefix("select "), let id = UUID(uuidString: String(line.dropFirst(7))), let tab = store.tab(withID: id) {
                store.select(tab)
                continue
            }
            if line == "new" || line == "new claude" || line == "new codex" || line == "new deepseek_claude" {
                let kind: AgentKind? = line == "new" ? nil
                    : (line.hasSuffix("codex") ? .codex : line.hasSuffix("deepseek_claude") ? .deepseekClaude : .claude)
                store.newSession(kind: kind)
                continue
            }
            if line == "search" || line.hasPrefix("search "), let project = store.currentProject ?? store.projects.first {
                // search [text]: open the current project's session search with this query.
                store.openSearch(project)
                store.setSearchQuery(String(line.dropFirst(7)), for: project)
                continue
            }
            if line == "endsearch", let project = store.currentProject ?? store.projects.first {
                store.closeSearch(project)
                continue
            }
            if line == "morehistory", let project = store.currentProject ?? store.projects.first {
                store.showMoreHistory(project)
                continue
            }
            if line == "toggleproject", let project = store.currentProject ?? store.projects.first {
                store.toggleExpanded(project)
                continue
            }
            if line.hasPrefix("openurl "), let url = URL(string: String(line.dropFirst(8))) {
                (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [url])
                continue
            }
            if line == "schedules" {
                store.showSchedules()
                continue
            }
            if line.hasPrefix("schedule "), let id = UUID(uuidString: String(line.dropFirst(9))) {
                store.showScheduledTask(id)
                continue
            }
            if line.hasPrefix("runschedule "), let id = UUID(uuidString: String(line.dropFirst(12))) {
                store.runScheduleNow(id)
                continue
            }
            if line == "tickschedules" {
                store.runDueSchedules()
                continue
            }
            if line == "newschedule" {
                store.newScheduledTask()
                continue
            }
            if line == "sheetkey return" || line == "sheetkey escape", let sheet = window?.attachedSheet ?? NSApp.modalWindow {
                // A real key press on the open sheet, as the user would type it.
                let ret = line.hasSuffix("return")
                sheet.makeKey()
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let ev = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: sheet.windowNumber, context: nil, characters: ret ? "\r" : "\u{1b}",
                        charactersIgnoringModifiers: ret ? "\r" : "\u{1b}", isARepeat: false, keyCode: ret ? 0x24 : 0x35) {
                        NSApp.postEvent(ev, atStart: false)
                    }
                }
                continue
            }
            if line == "closepanel" {
                store.schedulePanel = nil
                continue
            }
            if line.hasPrefix("panelname ") {
                store.schedulePanel?.draft.name = String(line.dropFirst(10))
                continue
            }
            if line == "panelsave" {
                if let problem = store.saveSchedulePanel() { NSLog("Vertty debug: panel not saved: %@", problem) }
                continue
            }
            if line == "panelcancel" {
                store.cancelSchedulePanel()
                continue
            }
            if line == "refreshhistory" {
                store.refreshHistory()
                continue
            }
            // Remote windows: connect, open a card, type into its terminal.
            if line.hasPrefix("remote "), let url = URL(string: String(line.dropFirst(7))) {
                RemoteWindowController.open(.url(url))
                RemoteWindowController.all.last?.window.orderBack(nil)
                continue
            }
            if line == "tailnetlogout" {
                Tailnet.shared.logout()
                continue
            }
            // Same as clicking Via Tailscale (tailscale) or Listen on
            // 127.0.0.1 Only (direct) in the Remote Connections submenu:
            // turns it on or off.
            if line.hasPrefix("remotemode "), let menu = Self.remoteMenu,
               let index = menu.items.firstIndex(where: {
                   $0.action == NSSelectorFromString("toggleRemoteMode:")
                       && ($0.representedObject as? String) == String(line.dropFirst(11))
               }) {
                menu.performActionForItem(at: index)
                continue
            }
            // Same as picking the computer with this name on the tailnet (its
            // unique DNS label) in the connect window's Tailscale list; does
            // nothing until it's listed there.
            if line.hasPrefix("remotetailnet ") {
                let name = String(line.dropFirst(14))
                Tailnet.shared.activateClient()
                if let computer = Tailnet.shared.computers.first(where: { $0.dnsName == name && $0.online }) {
                    RemoteWindowController.open(computer)
                    RemoteWindowController.all.last?.window.orderBack(nil)
                }
                continue
            }
            if let remote = RemoteWindowController.all.last {
                let store = remote.store
                if line.hasPrefix("remoteopen "), let i = Int(line.dropFirst(11)) {
                    store.selectCard(at: i)
                    continue
                }
                if line.hasPrefix("remotetext ") {
                    remote.terminal.view.sendText(String(line.dropFirst(11)))
                    continue
                }
                if line == "remoteenter" {
                    remote.terminal.view.debugPress(keyCode: 0x24, chars: "\r")
                    continue
                }
                if line == "remotenew" {
                    if let p = store.currentProject { store.newSession(in: p, kind: nil) }
                    continue
                }
                if line.hasPrefix("remotesearch "), let p = store.currentProject ?? store.projects.first {
                    store.openSearch(p)
                    store.setSearchQuery(String(line.dropFirst(13)), for: p)
                    continue
                }
            }
            guard let tab = target, let surface = targetShell ? tab.shellSurface : tab.surface else { continue }
            switch line {
            case "enter": surface.debugPress(keyCode: 0x24, chars: "\r")
            case "down": surface.debugPress(keyCode: 0x7D, chars: "\u{F701}")
            case "up": surface.debugPress(keyCode: 0x7E, chars: "\u{F700}")
            case "esc": surface.debugPress(keyCode: 0x35, chars: "\u{1b}")
            case "notify":
                store.notify(tab, body: "Vertty test notification")
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let text = "authorization=\(settings.authorizationStatus.rawValue)"
                    try? text.write(to: self.directory.appendingPathComponent("notify.txt"), atomically: true, encoding: .utf8)
                }
            default:
                if line.hasPrefix("text ") { surface.sendText(String(line.dropFirst(5))) }
            }
        }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? buttons(in: child)
        }
    }

    private func capture() {
        drive()
        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: {
            $0.items.contains { $0.action == NSSelectorFromString("toggleSidebar") }
        }) {
            menu.update()
            let items = menu.items.filter {
                $0.action == NSSelectorFromString("toggleSidebar") || $0.action == NSSelectorFromString("toggleShell")
            }
            let text = items.map { "\($0.title) enabled=\($0.isEnabled)" }.joined(separator: "\n")
            try? text.write(to: directory.appendingPathComponent("view-menu.txt"), atomically: true, encoding: .utf8)
        }
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let item = menu.items.first(where: { $0.action == NSSelectorFromString("toggleSleepProtection") }) {
            try? item.title.write(to: directory.appendingPathComponent("sleep-menu.txt"), atomically: true, encoding: .utf8)
        }
        // The Remote Connections submenu: its ways, then the visible details.
        if let menu = Self.remoteMenu {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            let lines = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map { item in
                item.action == NSSelectorFromString("toggleRemoteMode:")
                    ? item.title + (item.state == .on ? " [on]" : " [off]") : "  " + item.title
            }
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("remote-menu.txt"), atomically: true, encoding: .utf8)
        }
        let modal = window?.attachedSheet ?? NSApp.modalWindow
        let titles = modal?.contentView.map { Self.buttons(in: $0).map(\.title).joined(separator: "\n") } ?? ""
        try? titles.write(to: directory.appendingPathComponent("alert.txt"), atomically: true, encoding: .utf8)
        if let modal { shots.append((CGWindowID(modal.windowNumber), "alert.png")) }
        defer { takeShots() }
        guard let window, let view = window.contentView else { return }

        // Window server image (includes the Metal terminal layer).
        shots.append((CGWindowID(window.windowNumber), "window.png"))
        if let sheet = window.attachedSheet { shots.append((CGWindowID(sheet.windowNumber), "sheet.png")) }
        // AppKit rendering (SwiftUI chrome only, no terminal pixels).
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            writeLater(rep, "chrome.png")
        }

        var lines: [String] = ["windowSize=\(view.bounds.width),\(view.bounds.height)"]
        lines.append("pid=\(getpid()) version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")")
        for auxiliary in NSApp.windows where auxiliary.isVisible && auxiliary !== window {
            lines.append("window=\(auxiliary.windowNumber) class=\(type(of: auxiliary)) size=\(auxiliary.contentView?.bounds.size ?? .zero)")
            if let content = auxiliary.contentView {
                for button in Self.buttons(in: content) where !button.title.isEmpty {
                    lines.append("windowbutton=\(auxiliary.windowNumber) enabled=\(button.isEnabled) title=\(button.title)")
                }
            }
            shots.append((CGWindowID(auxiliary.windowNumber), "window-\(auxiliary.windowNumber).png"))
        }
        lines.append("sidebarVisible=\(store.sidebarVisible) sidebarWidth=\(store.sidebarWidth)")
        if let menu = NSApp.mainMenu?.items.first?.submenu?.items.compactMap(\.submenu).first(where: {
            $0.items.contains { $0.action == NSSelectorFromString("toggleAgent:") }
        }) {
            menu.update()
            lines.append("enabled-agents-menu: " + menu.items.map {
                "\($0.title)=\($0.state == .on)\($0.isEnabled ? "" : " (locked)")"
            }.joined(separator: ", "))
        }
        if let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.action == NSSelectorFromString("newSessionOfKind:") } == true })?.submenu {
            file.delegate?.menuNeedsUpdate?(file)
            let new = ["newSession", "newSessionOfKind:"].map(NSSelectorFromString)
            lines.append("new-session-menu: " + file.items.filter { !$0.isHidden && $0.action.map(new.contains) == true }
                .map { "\($0.title)\($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent.uppercased())" }.joined(separator: ", "))
        }
        lines.append("projects: " + store.projects.map { "\($0.name)=\($0.path)" }.joined(separator: ", "))
        lines.append("selected: \(store.selectedTabID?.uuidString ?? "-")")
        lines.append("firstResponder: \(String(describing: window.firstResponder.map { type(of: $0) }))")
        for tab in store.tabs {
            lines.append("--- tab \(tab.id) kind=\(tab.kind) status=\(tab.status) attention=\(tab.attention) hooks=\(tab.hooksActive)")
            lines.append("    title=\(tab.title) | terminalTitle=\(tab.terminalTitle ?? "-")")
            lines.append("    session=\(tab.sessionID) codexThread=\(tab.codexThreadID ?? "-") cwd=\(tab.cwd)")
            lines.append("    branch=\(tab.branch ?? "-") worktree=\(tab.worktree ?? "-") pr=\(tab.prNumber.map(String.init) ?? "-") \(tab.prState ?? "")")
            if let sh = tab.shellSurface {
                lines.append("    shell: visible=\(tab.shellVisible) focused=\(tab.shellFocused) cwd=\(tab.shellCwd ?? "-") frame=\(sh.frame) inWindow=\(sh.window != nil)")
                lines.append(sh.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { "    s| " + $0 }.joined(separator: "\n"))
            }
            if let s = tab.surface {
                let grid = s.gridSize
                lines.append("    frame=\(s.frame) inWindow=\(s.window != nil) grid=\(grid.columns)x\(grid.rows) remoteGrid=\(s.remoteGrid.map { "\($0.columns)x\($0.rows)" } ?? "-")")
                lines.append(s.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    | " + $0 }.joined(separator: "\n"))
            }
        }
        lines.append("schedulesShown=\(store.showingSchedules) panel=\(store.schedulePanel.map { $0.taskID?.uuidString ?? "new" } ?? "-") dirty=\(store.schedulePanelDirty) draft=\(store.schedulePanel?.draft.name ?? "-")")
        if let timing = store.schedulePanel?.draft.timing {
            lines.append("draftTiming=\(timing.hour):\(timing.minute) date=\(timing.year ?? 0)-\(timing.month ?? 0)-\(timing.day ?? 0) timezone=\(timing.timeZoneID ?? "local")")
        }
        if self.window?.attachedSheet != nil || NSApp.modalWindow != nil { lines.append("sheet=open") }
        for task in store.schedules.tasks {
            lines.append("=== task \(task.id) \(task.name) kind=\(task.kind) enabled=\(task.enabled) deleted=\(task.isDeleted) session=\(task.sessionID ?? "-") next=\(task.nextPlan.map { "\($0)" } ?? "-")")
            for run in store.schedules.runs(of: task.id) {
                lines.append("    run \(run.id) \(run.trigger) \(run.state) phase=\(run.phase?.rawValue ?? "-") planned=\(run.plannedAt.map { "\($0)" } ?? "-") session=\(run.sessionID ?? "-") reason=\(run.reason ?? "-")")
            }
        }
        for (pid, items) in store.history {
            let name = store.project(pid)?.name ?? "?"
            lines.append("history[\(name)]: " + items.prefix(5).map(\.title).joined(separator: " / "))
        }
        for project in store.projects {
            let closed = store.closedHistory(for: project)
            let count = store.historyVisibleCount(for: project)
            lines.append("pagination[\(project.name)]: visible=\(min(count, closed.count)) more=\(closed.count > count) expanded=\(project.expanded)")
        }
        for (pid, items) in store.searchHistory {
            let name = store.project(pid)?.name ?? "?"
            lines.append("search[\(name)]: " + items.prefix(5).map(\.title).joined(separator: " / "))
        }
        for (pid, matches) in store.promptMatches {
            let name = store.project(pid)?.name ?? "?"
            lines.append("prompts[\(name)] \(matches.query): " + matches.sessions.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.before)[\($0.value.match)]\($0.value.after.prefix(40))" }.joined(separator: " / "))
        }
        let tailnet = Tailnet.shared
        lines.append("tailnet state=\(tailnet.state) signedIn=\(!tailnet.account.isEmpty) name=\(tailnet.name) computers=\(tailnet.computers.map { "\($0.dnsName):\($0.online ? "online" : "offline")" }.joined(separator: ","))")
        for remote in RemoteWindowController.all {
            let store = remote.store
            lines.append("=== remote \(store.client.endpoint.detail) status=\(store.client.status) server=\(store.client.serverName) open=\(store.selectedCardID?.uuidString ?? "-")")
            for card in store.allCards {
                lines.append("    card \(card.id) \(card.title) status=\(card.status) attention=\(card.attention) pr=\(card.prURL ?? "-")")
            }
            for p in store.projects {
                let shown = store.shownHistory(of: p).map { s in
                    s.title + (store.promptMatch(p, sessionID: s.id).map { "[\($0.match)]" } ?? "")
                }
                lines.append("    history \(p.name) query=\(store.query(for: p) ?? "-"): " + shown.joined(separator: " / "))
            }
            if store.selectedCardID != nil, let t = remote.terminal.view {
                let grid = t.gridSize, own = t.naturalGrid
                lines.append("    terminal grid=\(grid.columns)x\(grid.rows) own=\(own.columns)x\(own.rows) inWindow=\(t.window != nil)")
                lines.append(t.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    r| " + $0 }.joined(separator: "\n"))
            }
            shots.append((CGWindowID(remote.window.windowNumber), "remote.png"))
        }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    /// Takes this tick's window images, unless the last tick's are still being taken.
    private func takeShots() {
        let pending = shots
        shots = []
        guard !shooting, !pending.isEmpty else { return }
        shooting = true
        imageQueue.async { [weak self] in
            for (id, name) in pending {
                if let cg = vertty_window_image(id) { self?.write(NSBitmapImageRep(cgImage: cg), name) }
            }
            DispatchQueue.main.async { self?.shooting = false }
        }
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) {
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent(name))
        }
    }

    /// Encodes and writes off the main thread, which a big PNG would stall.
    private func writeLater(_ rep: NSBitmapImageRep, _ name: String) {
        imageQueue.async { [weak self] in self?.write(rep, name) }
    }
}
