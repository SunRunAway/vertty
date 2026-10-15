import AppKit
import GhosttyC
import UserNotifications

/// Development aid: with VHOSTTY_DEBUG_SNAPSHOT=<dir>, periodically writes a PNG of
/// the window and a text dump of the app state and visible terminal text, so the
/// UI can be checked without screen-recording permission.
final class DebugSnapshot {
    private let directory: URL
    private weak var window: NSWindow?
    private let store: AppStore
    private var timer: Timer?
    /// Window images are taken and PNGs encoded off the main thread: either
    /// can take seconds on a busy machine and would stall the app it watches.
    private let imageQueue = DispatchQueue(label: "vhostty.debug-snapshot.images")
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
    ///   post <ctrl|cmd|none> <char> · schedules · schedule <task uuid> ·
    ///   runschedule <task uuid> · tickschedules · newschedule · closepanel ·
    ///   panelsave · panelcancel ·
    ///   sheetkey return|escape (the open sheet or alert)
    private func drive() {
        let url = directory.appendingPathComponent("input.txt")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        var target: TabSession?
        var targetShell = false
        for line in content.split(separator: "\n").map(String.init) {
            // Window-local points from the top left; never clicks another app.
            if line.hasPrefix("click "), let window {
                let parts = line.split(separator: " ")
                if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]),
                   let view = window.contentView {
                    let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
                    guard view.bounds.contains(local) else { continue }
                    let point = view.convert(local, to: nil)
                    window.makeKey()
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: 1) {
                            if type == .leftMouseDown {
                                view.hitTest(local)?.mouseDown(with: event)
                            } else {
                                view.hitTest(local)?.mouseUp(with: event)
                            }
                        }
                    }
                }
                continue
            }
            if line.hasPrefix("alertbutton "), let index = Int(line.dropFirst(12)),
               let modal = window?.attachedSheet ?? NSApp.modalWindow {
                let buttons = modal.contentView.map { Self.buttons(in: $0) } ?? []
                if buttons.indices.contains(index) { buttons[index].performClick(nil) }
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
            if line == "new" || line == "new claude" || line == "new codex" {
                store.newSession(kind: line == "new" ? nil : (line.hasSuffix("codex") ? .codex : .claude))
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
            if line == "panelsave" {
                if let problem = store.saveSchedulePanel() { NSLog("Vhostty debug: panel not saved: %@", problem) }
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
                RemoteWindowController.open(url)
                RemoteWindowController.all.last?.window.orderBack(nil)
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
                store.notify(tab, body: "Vhostty test notification")
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
        // "Allow Remote Connections" and the visible lines under it.
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let toggle = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("toggleRemoteConnections") }) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            let lines = [menu.items[toggle].title + (menu.items[toggle].state == .on ? " [on]" : " [off]")]
                + menu.items[(toggle + 1)...].prefix { $0.indentationLevel > 0 }.filter { !$0.isHidden }.map { "  " + $0.title }
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

        var lines: [String] = []
        lines.append("sidebarVisible=\(store.sidebarVisible) sidebarWidth=\(store.sidebarWidth)")
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
        for remote in RemoteWindowController.all {
            let store = remote.store
            lines.append("=== remote \(store.client.url) status=\(store.client.status) server=\(store.client.serverName) open=\(store.selectedCardID?.uuidString ?? "-")")
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
                if let cg = vhostty_window_image(id) { self?.write(NSBitmapImageRep(cgImage: cg), name) }
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
