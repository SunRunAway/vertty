import AppKit
import Combine
import SwiftUI
import UserNotifications

/// All app state: projects, tabs, selection, and the glue to terminals and Claude.
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var projects: [Project] = []
    @Published var tabs: [TabSession] = []
    @Published private(set) var selectedTabID: UUID?
    /// Project of the last selected session, kept after that session closes.
    @Published private(set) var lastProjectID: UUID?
    /// The built-in default kind, picked on first launch from which agents are installed.
    @Published private(set) var detectedKind: AgentKind?
    @Published private(set) var newProjectKind: AgentKind?
    @Published var history: [UUID: [SessionSummary]] = [:]
    @Published var historyVisibleCounts: [UUID: Int] = [:]
    /// Per-project session search: present while the search field is open.
    @Published var searchQuery: [UUID: String] = [:]
    /// Every past session of a project being searched (history above is capped).
    @Published var searchHistory: [UUID: [SessionSummary]] = [:]
    /// Sessions of a project whose typed prompts contain the query, by session id.
    @Published private(set) var promptMatches: [UUID: PromptMatches] = [:]
    @Published var sidebarVisible = true
    @Published var sidebarWidth: CGFloat = 300
    /// Height fraction of the bottom shell panel (shared by all sessions).
    @Published var shellFraction: CGFloat = 0.35
    @Published var terminalBackground = Color(red: 0.16, green: 0.17, blue: 0.20)

    /// Set by the AppKit host so the store can move keyboard focus into terminals.
    weak var terminalContainer: TerminalContainerView?

    private var refreshTimer: Timer?
    private var historyTimer: Timer?
    private var historyWatcher: HistoryWatcher?
    private var historyObservers: [NSObjectProtocol] = []
    private var historyRefreshing = false
    private var historyRefreshPending = false
    private var saveWork: DispatchWorkItem?
    let infoQueue = DispatchQueue(label: "vhostty.info", qos: .utility)
    private let searchQueue = DispatchQueue(label: "vhostty.search", qos: .userInitiated)
    private var promptSearchWork: [UUID: DispatchWorkItem] = [:]
    private var refreshing: Set<UUID> = []
    /// The Claude process last seen running in each tab (see refreshLiveSessions).
    private(set) var livePIDs: [UUID: pid_t] = [:]

    let schedules = ScheduleStore()
    /// The scheduled-task page replaces the terminal while shown.
    @Published var showingSchedules = false
    /// The task panel on the right (a task, or a new one).
    @Published var schedulePanel: SchedulePanel?
    var scheduleTimer: Timer?
    /// Since when a scheduled Claude turn has looked idle without a Stop hook.
    var scheduleIdleSince: [UUID: Date] = [:]
    /// Runs not launched yet: their session is being checked, or its card stopped.
    var schedulePreparing: Set<UUID> = []
    /// Cards whose agent a run is stopping: selecting one mustn't start it again.
    var scheduleStoppingTabs: Set<UUID> = []

    var selectedTab: TabSession? { tabs.first { $0.id == selectedTabID } }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    func tabs(of project: Project) -> [TabSession] { tabs.filter { $0.projectID == project.id } }

    /// The project new sessions go to by default: the selected session's, else
    /// the one last worked in. The first project only if neither exists.
    var currentProject: Project? {
        if let tab = selectedTab, let p = project(tab.projectID) { return p }
        if let id = lastProjectID, let p = project(id) { return p }
        return projects.first
    }

    // MARK: - Lifecycle

    func load() {
        if let data = try? Data(contentsOf: AppPaths.state),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            projects = state.projects
            tabs = state.tabs.filter { r in state.projects.contains { $0.id == r.projectID } }.map(TabSession.init(record:))
            selectedTabID = state.selectedTabID ?? tabs.first?.id
            lastProjectID = state.lastProjectID
            detectedKind = state.detectedKind
            newProjectKind = state.newProjectKind
            if let w = state.sidebarWidth { sidebarWidth = CGFloat(w) }
            if let v = state.sidebarVisible { sidebarVisible = v }
            if let f = state.shellFraction { shellFraction = CGFloat(f) }
        }
        if selectedTabID != nil, selectedTab == nil { selectedTabID = tabs.first?.id }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshAllInfo()
        }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.watchHistory()
            self?.refreshHistory()
        }
        watchHistory()
        historyObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.watchHistory()
            self?.refreshHistory()
        })
        historyObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.watchHistory()
            self?.refreshHistory()
            self?.runDueSchedules()
        })
        historyObservers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.schedules.timeZoneChanged()
        })
        refreshHistory()
        refreshAllInfo()
        startSchedules()
    }

    /// Called once the user's shell environment is known (ShellEnvironment.loadInteractive).
    func shellEnvironmentLoaded() {
        if detectedKind == nil, let installed = ShellEnvironment.installedAgents, let first = installed.first {
            detectedKind = first
            scheduleSave()
        }
        freezeProjectDefaults()
        scheduleSave()
        watchHistory()
        refreshHistory()  // Codex's history depends on the shell's CODEX_HOME.
    }

    /// The initial default for projects added from now on.
    var globalDefaultKind: AgentKind { newProjectKind ?? detectedKind ?? .claude }

    /// Legacy projects retain their original detected default.
    func defaultKind(_ project: Project) -> AgentKind { project.defaultKind ?? detectedKind ?? .claude }

    private func freezeProjectDefaults() {
        for index in projects.indices where projects[index].defaultKind == nil {
            projects[index].defaultKind = detectedKind ?? .claude
        }
    }

    func setNewProjectKind(_ kind: AgentKind) {
        freezeProjectDefaults()
        newProjectKind = kind
        scheduleSave()
    }

    @discardableResult
    func addProject(at url: URL) -> Project {
        if let existing = projects.first(where: { $0.path == url.path }) { return existing }
        let project = Project(name: url.lastPathComponent, path: url.path, defaultKind: globalDefaultKind)
        schedules.projectAdded(project.id, path: project.path, known: Set(projects.map(\.id)))
        projects.append(project)
        scheduleSave()
        return project
    }

    /// Called once the window exists: start Claude in the selected tab.
    func activateSelection() {
        if let tab = selectedTab { select(tab) }
    }

    func save() {
        let state = PersistedState(
            projects: projects,
            tabs: tabs.map(\.record),
            selectedTabID: selectedTabID,
            lastProjectID: lastProjectID,
            detectedKind: detectedKind,
            newProjectKind: newProjectKind,
            sidebarWidth: Double(sidebarWidth),
            sidebarVisible: sidebarVisible,
            shellFraction: Double(shellFraction))
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: AppPaths.state, options: .atomic)
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Projects

    func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Project")
        panel.message = String(localized: "Choose a project directory. Sessions will start there.")
        guard panel.runModal() == .OK else { return }
        var last: Project?
        for url in panel.urls {
            last = addProject(at: url)
        }
        scheduleSave()
        refreshHistory()
        if let last, tabs(of: last).isEmpty { newSession(in: last) }
    }

    func renameProject(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Project")
        alert.informativeText = project.path.abbreviatingHome
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let name = field.stringValue.nonEmpty else { return }
        updateProject(project.id) { $0.name = name }
    }

    func changeProjectDirectory(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.path != project.path else { return }
        updateProject(project.id) { $0.path = url.path }
        refreshHistory()
    }

    func removeProject(_ project: Project) {
        let open = tabs(of: project)
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove project “\(project.name)”?")
        alert.informativeText = open.isEmpty
            ? String(localized: "It is only removed from Vhostty. No files are deleted.")
            : String(localized: "Its \(open.count) open sessions will be closed (their history is kept and can be resumed later). No files are deleted.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tab in open { closeTab(tab, force: true) }
        projects.removeAll { $0.id == project.id }
        history.removeValue(forKey: project.id)
        scheduleSave()
    }

    func toggleExpanded(_ project: Project) {
        historyVisibleCounts.removeValue(forKey: project.id)
        updateProject(project.id) { $0.expanded.toggle() }
    }

    func historyVisibleCount(for project: Project) -> Int {
        historyVisibleCounts[project.id] ?? 5
    }

    func showMoreHistory(_ project: Project) {
        historyVisibleCounts[project.id] = historyVisibleCount(for: project) + 10
        refreshHistory()
    }

    func moveProject(_ id: UUID, before target: UUID) {
        guard id != target, let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == target }) else { return }
        let project = projects.remove(at: from)
        projects.insert(project, at: to)
        scheduleSave()
    }

    private func updateProject(_ id: UUID, _ body: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        body(&projects[i])
        scheduleSave()
    }

    // MARK: - Tabs

    func newSession(in project: Project? = nil, kind: AgentKind? = nil) {
        guard let project = project ?? currentProject else {
            addProjectViaPanel()
            return
        }
        let kind = kind ?? defaultKind(project)
        // Codex can't be given a session id; it gets one once its thread shows up.
        let sessionID = kind == .claude ? UUID().uuidString.lowercased() : ""
        let tab = TabSession(projectID: project.id, kind: kind, sessionID: sessionID, cwd: project.path)
        insertAtTopOfProject(tab)
        select(tab)
    }

    /// A new session started for a remote client: shown at the top of its
    /// project, but the local selection stays where it is.
    func newSessionInBackground(in project: Project, kind: AgentKind?) -> TabSession {
        let kind = kind ?? defaultKind(project)
        let sessionID = kind == .claude ? UUID().uuidString.lowercased() : ""
        let tab = TabSession(projectID: project.id, kind: kind, sessionID: sessionID, cwd: project.path)
        insertAtTopOfProject(tab)
        launch(tab)
        return tab
    }

    /// A past session resumed for a remote client, without selecting it here.
    func resumeInBackground(sessionID: String, kind: AgentKind, title: String?, in project: Project) -> TabSession {
        let tab = TabSession(projectID: project.id, kind: kind, sessionID: sessionID, cwd: project.path,
                             title: title ?? String(localized: "New Session"))
        insertAtTopOfProject(tab)
        launch(tab)
        refreshHistory()
        return tab
    }

    /// Starts a card's agent for a remote client if it isn't running.
    func launchInBackground(_ tab: TabSession) {
        launchIfNeeded(tab)
    }

    /// Both kinds, the project's default first (the order of its "New … Session" menu items).
    func kindsDefaultFirst(_ project: Project) -> [AgentKind] {
        let first = defaultKind(project)
        return [first] + AgentKind.allCases.filter { $0 != first }
    }

    func setDefaultKind(_ kind: AgentKind, for project: Project) {
        updateProject(project.id) { $0.defaultKind = kind }
    }

    func resumeSession(_ summary: SessionSummary, in project: Project) {
        if let open = tabs.first(where: { $0.sessionID == summary.id }) {
            select(open)
            return
        }
        let tab = TabSession(projectID: project.id, kind: summary.kind, sessionID: summary.id, cwd: project.path,
                             title: summary.title)
        insertAtTopOfProject(tab)
        select(tab)
    }

    /// New and resumed sessions go to the top of their project's cards, matching
    /// the newest-first order of the history list below them.
    func insertAtTopOfProject(_ tab: TabSession) {
        if let first = tabs.firstIndex(where: { $0.projectID == tab.projectID }) {
            tabs.insert(tab, at: first)
        } else {
            tabs.append(tab)
        }
        scheduleSave()
    }

    func select(_ tab: TabSession) {
        showingSchedules = false
        // A task's panel goes with the page, unless it has changes to keep.
        if schedulePanel != nil, !schedulePanelDirty { schedulePanel = nil }
        launchIfNeeded(tab)
        if tab.shellVisible { launchShellIfNeeded(tab) }
        tab.attention = false
        if selectedTabID != tab.id { selectedTabID = tab.id }
        if lastProjectID != tab.projectID { lastProjectID = tab.projectID }
        showInContainer(tab)
        updateDockBadge()
        scheduleSave()
    }

    /// Tabs in sidebar order (grouped by project, projects in sidebar order).
    var orderedTabs: [TabSession] {
        projects.flatMap { p in tabs.filter { $0.projectID == p.id } }
    }

    func selectTab(at index: Int) {
        let ordered = orderedTabs
        guard ordered.indices.contains(index) else { return }
        let tab = ordered[index]
        if let p = project(tab.projectID), !p.expanded { toggleExpanded(p) }
        select(tab)
    }

    func gotoTab(_ target: GhosttyGotoTab) {
        let ordered = orderedTabs
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedTabID } ?? 0
        switch target {
        case .previous: selectTab(at: (current - 1 + ordered.count) % ordered.count)
        case .next: selectTab(at: (current + 1) % ordered.count)
        case .last: selectTab(at: ordered.count - 1)
        case .index(let i): selectTab(at: min(max(i - 1, 0), ordered.count - 1))
        }
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        scheduleSave()
    }

    /// Closing via UI: ask the terminal to close (it confirms if Claude is still running).
    func requestClose(_ tab: TabSession) {
        if let surface = tab.surface, !surface.processExited {
            surface.requestClose()
        } else {
            closeTab(tab, force: true)
        }
    }

    func closeSelected() {
        if let tab = selectedTab { requestClose(tab) }
    }

    func closeOtherTabs(_ keep: TabSession) {
        let others = tabs.filter { $0 !== keep && $0.isLaunched && !($0.surface?.processExited ?? true) }
        if !others.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Close \(others.count) other running sessions?")
            alert.informativeText = String(localized: "Their history is kept and can be resumed from the sidebar later.")
            alert.addButton(withTitle: String(localized: "Close"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for tab in tabs where tab !== keep { closeTab(tab, force: true) }
    }

    func closeTab(_ tab: TabSession, force: Bool) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = tab.id == selectedTabID
        let ordered = orderedTabs
        let orderedIndex = ordered.firstIndex { $0 === tab } ?? 0
        if wasSelected { showInContainer(nil) }
        tab.surface = nil
        tab.shellSurface = nil
        tabs.remove(at: index)
        if wasSelected {
            // Prefer the neighbour in the same project, then the next card in the sidebar.
            let remaining = ordered.filter { $0 !== tab }
            if remaining.isEmpty {
                selectedTabID = nil
            } else {
                let sameProject = remaining.filter { $0.projectID == tab.projectID }
                let next = sameProject.isEmpty
                    ? remaining[min(orderedIndex, remaining.count - 1)]
                    : (remaining.first { r in ordered.firstIndex { $0 === r }! > orderedIndex && r.projectID == tab.projectID }
                        ?? sameProject.last!)
                select(next)
            }
        }
        updateDockBadge()
        refreshHistory()
        scheduleSave()
    }

    /// Puts a session in the terminal area, unless the scheduled-task page covers it.
    func showInContainer(_ tab: TabSession?) {
        terminalContainer?.show(showingSchedules ? nil : tab)
    }

    func tab(for surface: TerminalSurfaceView) -> TabSession? {
        tabs.first { $0.surface === surface }
    }

    func tab(withID id: UUID) -> TabSession? { tabs.first { $0.id == id } }

    /// Set by the close confirmation's "Don't ask again" checkbox.
    static let skipCloseConfirmKey = "SkipCloseSessionConfirmation"

    /// libghostty asks to close a surface (cmd+w, or the shell exited).
    func surfaceRequestedClose(_ surface: TerminalSurfaceView, processAlive: Bool) {
        if let tab = tabs.first(where: { $0.shellSurface === surface }) {
            if processAlive {
                let alert = NSAlert()
                alert.messageText = String(localized: "Close the bottom terminal?")
                alert.informativeText = String(localized: "A program is still running in the terminal. Closing will end it.")
                alert.addButton(withTitle: String(localized: "Close"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            closeShell(tab)
            return
        }
        guard let tab = tab(for: surface) else { return }
        if processAlive && !UserDefaults.standard.bool(forKey: Self.skipCloseConfirmKey) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Close “\(tab.title)”?")
            alert.informativeText = String(localized: "\(tab.kind.name) is still running. Closing will end it. The history is kept and can be resumed from the sidebar later.")
            alert.addButton(withTitle: String(localized: "Close"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Don’t ask again")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.skipCloseConfirmKey)
            }
        }
        closeTab(tab, force: true)
    }

    // MARK: - Launching Claude

    private func launchIfNeeded(_ tab: TabSession) {
        guard tab.surface == nil, !scheduleStoppingTabs.contains(tab.id) else { return }
        launch(tab)
    }

    /// Starts the card's agent: resumed when its session exists, else new. A
    /// scheduled run hands over its prompt with it.
    func launch(_ tab: TabSession, prompt: String? = nil, scheduleRunID: UUID? = nil) {
        guard let project = project(tab.projectID) else { return }
        var transcript: URL?
        let resume: Bool
        switch tab.kind {
        case .claude:
            transcript = Transcript.locate(sessionID: tab.sessionID, projectPath: project.path)
            resume = transcript != nil
        case .codex:
            resume = !tab.sessionID.isEmpty
            tab.codexThreadID = nil
        }
        let options = TerminalSurfaceView.Options(
            workingDirectory: launchDirectory(project),
            command: ClaudeLauncher.command(kind: tab.kind, sessionID: tab.sessionID, resume: resume, prompt: prompt),
            environment: ClaudeLauncher.environment(tabID: tab.id, scheduleRunID: scheduleRunID))
        let surface = TerminalSurfaceView(options: options)
        surface.onTitleChange = { [weak self, weak tab] title in
            guard let self, let tab else { return }
            self.terminalTitleChanged(tab, title)
        }
        tab.surface = surface
        tab.launchedAt = Date()
        // The previous process's pid would make the new one look exited until it registers.
        livePIDs[tab.id] = nil
        tab.scheduleRunID = scheduleRunID
        tab.transcriptPath = transcript?.path
        tab.status = .starting
        tab.hooksActive = false
        tab.titleBusy = false
        refreshInfo(tab)
    }

    private func launchDirectory(_ project: Project) -> String {
        FileManager.default.fileExists(atPath: project.path) ? project.path : NSHomeDirectory()
    }

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
        scheduleSave()
    }

    // MARK: - Bottom shell panel

    /// ⌘J: show the selected session's shell panel (starting it in Claude's
    /// current directory the first time) or hide it again.
    func toggleShell() {
        guard let tab = selectedTab else { return }
        if tab.shellVisible {
            tab.shellVisible = false
            tab.shellFocused = false
        } else {
            launchShellIfNeeded(tab)
            tab.shellVisible = true
            tab.shellFocused = true
        }
        showInContainer(tab)
        scheduleSave()
    }

    /// Moves focus between Claude (top) and the shell panel (bottom).
    func focusPane(shell: Bool?) {
        guard let tab = selectedTab, tab.shellVisible, tab.shellSurface != nil else { return }
        let target = shell ?? !tab.shellFocused
        terminalContainer?.focusPane(shell: target)
    }

    private func launchShellIfNeeded(_ tab: TabSession) {
        guard tab.shellSurface == nil, let project = project(tab.projectID) else { return }
        let fm = FileManager.default
        let claudeDir = tab.workDir ?? (tab.hooksActive ? tab.cwd : (tab.transcript?.cwd ?? project.path))
        let candidates = [tab.shellCwd, claudeDir, project.path, NSHomeDirectory()]
        let dir = candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0) } ?? NSHomeDirectory()

        // A plain login shell (with Ghostty shell integration); deliberately without
        // VHOSTTY_TAB_ID so a `claude` started here doesn't report as this card.
        let shell = TerminalSurfaceView(options: .init(workingDirectory: dir))
        shell.onPwdChange = { [weak self, weak tab] pwd in
            guard let tab else { return }
            let path = pwd.hasPrefix("file://") ? (URL(string: pwd)?.path ?? pwd) : pwd
            tab.shellCwd = path
            self?.scheduleSave()
        }
        tab.shellSurface = shell
        tab.shellCwd = dir
    }

    func closeShell(_ tab: TabSession) {
        tab.shellVisible = false
        tab.shellFocused = false
        tab.shellCwd = nil
        if tab.id == selectedTabID { showInContainer(tab) }
        tab.shellSurface = nil
        scheduleSave()
    }

    // MARK: - Titles & status

    /// Claude Code prefixes its terminal title with a status glyph: a spinner
    /// while working, "✳" otherwise. This is the only source of working / idle:
    /// it also covers turns that end without a Stop hook (Esc). "✳" also shows
    /// while Claude waits for an answer or a permission, so needing you comes
    /// from the Notification hook.
    /// Codex's title (as set by ClaudeLauncher) is "<spinner> <thread title> | <id>…",
    /// with the spinner (braille dots) only while it works. The id is cut to its
    /// first 29 characters; the thread title is the full id until the thread has one.
    private func terminalTitleChanged(_ tab: TabSession, _ raw: String) {
        var title = raw.trimmingCharacters(in: .whitespaces)
        var glyph: Character?
        if let first = title.first, !first.isLetter, !first.isNumber,
           title.count > 2, title[title.index(after: title.startIndex)] == " " {
            glyph = first
            title = String(title.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // Any glyph other than "✳" (◐◓◑◒, braille dots, ✶✻…) is the spinner.
        let busy: Bool? = tab.kind == .codex ? glyph != nil : glyph.map { $0 != "✳" }
        if let busy {
            let wasBusy = tab.titleBusy
            tab.titleBusy = busy
            if tab.kind == .codex && tab.status == .starting {
                // Codex also spins while it boots or reloads a resumed session;
                // that isn't a turn. It's ready once that first spin stops.
                if !busy && wasBusy { tab.status = .idle }
            } else if busy {
                // The spinner coming back means Claude went on (the question was
                // answered); later frames of the same spin don't undo a question
                // raised by a hook meanwhile.
                if !wasBusy || tab.status != .needsInput { tab.status = .working }
            } else if tab.status == .working {
                tab.status = .idle
                if isBackground(tab) {
                    tab.attention = true
                    updateDockBadge()
                }
                refreshHistory()
            } else if tab.status == .starting {
                tab.status = .idle
            }
        }

        if tab.kind == .codex {
            var parts = title.components(separatedBy: " | ").map(Self.dropNamingSpinner)
            var thread = parts.count > 1 ? Self.codexThreadID(parts.removeLast()) : nil
            let name = parts.joined(separator: " | ")
            if name.count == 36, UUID(uuidString: name) != nil {
                // Not named yet: the title is the full id.
                thread = name.lowercased()
                tab.terminalTitle = nil
            } else {
                // Once Codex quits, the title is the shell's.
                let named = name.contains { $0.isLetter || $0.isNumber }
                tab.terminalTitle = named && tab.status != .exited ? name : nil
            }
            if let thread, tab.codexThreadID != thread, !(tab.codexThreadID ?? "").hasPrefix(thread) {
                tab.codexThreadID = thread
                confirmCodexThreads()
            }
        } else {
            let generic = ["claude", "claude code", ""].contains(title.lowercased())
                || title.hasPrefix("/") || title.hasPrefix("~") || title.contains("@")
            tab.terminalTitle = generic ? nil : title
        }
        updateTitle(tab)
    }

    /// Codex appends a spinner to the thread title and id while it's naming the thread.
    private static func dropNamingSpinner(_ part: String) -> String {
        guard let last = part.last, !last.isLetter, !last.isNumber, last != ".", part.dropLast().hasSuffix(" ")
        else { return part }
        return String(part.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// A thread id from Codex's title, whole or cut short ("01a1177c-18a5-…-2d259...").
    private static func codexThreadID(_ part: String) -> String? {
        let id = part.hasSuffix("...") ? String(part.dropLast(3)) : part
        guard id.count >= 20, id.count <= 36, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id.lowercased()
    }

    /// Claude Code's "waiting for your input" reminder, sent 60s after a turn ends
    /// with no input.
    static func isIdleReminder(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("waiting for your input")
    }

    /// Whether the user isn't looking at the card, so a change earns the unread marker.
    private func isBackground(_ tab: TabSession) -> Bool {
        tab.id != selectedTabID || !NSApp.isActive
    }

    private func updateTitle(_ tab: TabSession) {
        let t = tab.transcript
        let title = t?.customTitle ?? tab.terminalTitle ?? t?.aiTitle ?? t?.summary ?? t?.firstPrompt
        if let title, title != tab.title {
            tab.title = title
            scheduleSave()
        }
    }

    func handleHook(_ event: HookEvent) {
        guard let tab = tab(withID: event.tabID) else { return }
        if tab.kind == .codex {
            // Codex runs no Vhostty hooks; its launcher only reports that it quit.
            if event.name == "SessionEnd" {
                tab.status = .exited
                updateDockBadge()
            }
            return
        }
        tab.hooksActive = true
        if let sid = event.sessionID, sid != tab.sessionID {
            tab.sessionID = sid
            tab.transcriptPath = event.transcriptPath
            scheduleSave()
        }
        if let path = event.transcriptPath { tab.transcriptPath = path }
        if let cwd = event.cwd { tab.cwd = cwd }

        // Working / idle come from the terminal title (terminalTitleChanged); hooks
        // add what the title can't tell: that Claude needs you, and that it exited.
        switch event.name {
        case "SessionStart":
            if tab.status == .starting { tab.status = .idle }
        // System notifications come from Claude Code itself (OSC 9/777 through
        // Ghostty, honoring the user's Claude notification settings). Hooks only
        // drive the status icon and the unread marker.
        case "Notification":
            // "waiting for your input" (idle_prompt) is just idle; anything else
            // (permission prompts, questions) needs you.
            // The idle reminder only repeats a finished turn, whose unread marker
            // was already decided when it finished (terminalTitleChanged).
            if event.notificationType == "idle_prompt" || Self.isIdleReminder(event.message ?? "") {
                if tab.status != .working { tab.status = .idle }
            } else {
                tab.status = .needsInput
                if isBackground(tab) { tab.attention = true }
            }
        case "SessionEnd":
            tab.status = .exited
        default:
            break
        }
        scheduleHook(tab, event)
        updateDockBadge()
        refreshInfo(tab)
    }

    // MARK: - Branch / worktree / PR

    private func refreshAllInfo() {
        evaluateScheduleRuns()
        refreshLiveSessions()
        confirmCodexThreads()
        for tab in tabs { refreshInfo(tab) }
    }

    /// A Codex thread shown in a tab's title becomes the tab's session once Codex
    /// has saved it (on its first message); before that it can't be resumed.
    private func confirmCodexThreads() {
        let pending: [(TabSession, String)] = tabs.compactMap { tab in
            guard tab.kind == .codex, let ref = tab.codexThreadID, !tab.sessionID.hasPrefix(ref) else { return nil }
            return (tab, ref)
        }
        guard !pending.isEmpty else { return }
        infoQueue.async { [weak self] in
            let saved = pending.compactMap { tab, ref in CodexThreads.thread(idPrefix: ref).map { (tab, ref, $0.id) } }
            DispatchQueue.main.async {
                guard let self else { return }
                for (tab, ref, id) in saved where tab.codexThreadID == ref && tab.sessionID != id {
                    tab.sessionID = id
                    self.scheduleSessionKnown(tab)
                    self.scheduleSave()
                    self.refreshInfo(tab)
                }
            }
        }
    }

    /// Follows the session actually running in each tab. This covers a `claude`
    /// typed into the tab's shell after the first one exited (`claude -r <id>`),
    /// which sends no hooks.
    private func refreshLiveSessions() {
        let scanned = Date()
        infoQueue.async { [weak self] in
            let live = LiveSessions.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                // Codex sessions don't show up here (see confirmCodexThreads). A
                // card started since the scan began isn't in it yet.
                for tab in self.tabs where tab.isLaunched && tab.kind == .claude && (tab.launchedAt ?? .distantPast) < scanned {
                    let entry = live[tab.id]
                    let lastPID = self.livePIDs[tab.id]
                    self.livePIDs[tab.id] = entry?.pid
                    guard let entry else {
                        // Its Claude exited (a hooked one already said so with SessionEnd).
                        if lastPID != nil { tab.status = .exited }
                        continue
                    }
                    if entry.pid != lastPID, tab.status == .exited {
                        tab.status = tab.titleBusy ? .working : .idle
                    }
                    guard entry.sessionID != tab.sessionID else { continue }
                    tab.sessionID = entry.sessionID
                    tab.transcriptPath = nil
                    if let cwd = entry.cwd { tab.cwd = cwd }
                    self.scheduleSave()
                    self.refreshInfo(tab)
                }
                self.livePIDs = self.livePIDs.filter { id, _ in self.tabs.contains { $0.id == id } }
            }
        }
    }

    func refreshInfo(_ tab: TabSession) {
        guard !refreshing.contains(tab.id), let project = project(tab.projectID) else { return }
        refreshing.insert(tab.id)
        let sessionID = tab.sessionID
        let knownPath = tab.transcriptPath
        let hookCwd = tab.hooksActive || !tab.isLaunched ? tab.cwd : nil
        let kind = tab.kind

        infoQueue.async { [weak self] in
            var url: URL?
            let info: TranscriptInfo?
            switch kind {
            case .claude:
                // The path reported by hooks can be stale: a session that entered a
                // worktree gets its transcript relocated to that worktree's directory.
                url = knownPath.map { URL(fileURLWithPath: $0) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? Transcript.locate(sessionID: sessionID, projectPath: project.path)
                info = url.flatMap { Transcript.read($0) }
            case .codex:
                info = CodexThreads.thread(id: sessionID).map { t in
                    var info = TranscriptInfo()
                    info.aiTitle = t.title
                    info.firstPrompt = t.firstPrompt
                    info.cwd = t.cwd.nonEmpty
                    info.gitBranch = t.branch
                    info.modified = t.modified
                    return info
                }
            }
            var cwd = hookCwd ?? info?.cwd ?? project.path
            // A resumed session that lives in a worktree reports the launch directory
            // in hooks, but Claude works inside the worktree recorded in the transcript.
            if case .some(.some(let wt)) = info?.worktree,
               FileManager.default.fileExists(atPath: wt.path),
               !cwd.hasPrefix(wt.path) {
                cwd = wt.path
            }
            let git = GitProbe.probe(cwd) ?? (cwd != project.path ? GitProbe.probe(project.path) : nil)
            // HEAD belongs to the checkout, which multiple sessions can share.
            // Only the session's own recorded branch can identify its work; polling
            // HEAD here would move idle/restored cards to another session's PR.
            let branch = info?.gitBranch?.nonEmpty
            // On a feature branch the card shows that branch's PR, or none yet. The
            // transcript's pr-link is a PR the session opened earlier (maybe from
            // another worktree), so it only stands in once the session is off its
            // feature branches, e.g. back on master.
            let featureBranch = branch.flatMap { GitProbe.isFeatureBranch($0) ? $0 : nil }
            let linkedPR = featureBranch == nil ? info?.prNumber : nil
            let pr = featureBranch.flatMap { GitProbe.pullRequest(toplevel: git?.toplevel ?? project.path, branch: $0) }
                ?? linkedPR.flatMap { n in
                    GitProbe.pullRequest(ref: info?.prURL ?? String(n), cwd: git?.toplevel ?? project.path)
                }

            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing.remove(tab.id)
                guard self.tabs.contains(where: { $0 === tab }) else { return }
                // The card moved on to another session meanwhile: this is stale.
                guard tab.sessionID == sessionID else {
                    self.refreshInfo(tab)
                    return
                }
                if let url { tab.transcriptPath = url.path }
                tab.workDir = cwd
                tab.transcript = info
                self.updateTitle(tab)

                if let branch, tab.branch != branch { tab.branch = branch }

                var worktree: String?
                if let git, let linked = git.linkedWorktree {
                    if case .some(.some(let wt)) = info?.worktree, git.toplevel.hasPrefix(wt.path) || wt.path.hasPrefix(git.toplevel) {
                        worktree = wt.name
                    } else {
                        worktree = linked
                    }
                } else if git == nil, case .some(.some(let wt)) = info?.worktree {
                    worktree = wt.name
                }
                if tab.worktree != worktree { tab.worktree = worktree }

                if let pr {
                    tab.prNumber = pr.number
                    tab.prURL = pr.url
                    tab.prState = pr.state
                } else if let n = linkedPR {
                    tab.prNumber = n
                    tab.prURL = info?.prURL
                    tab.prState = nil
                } else if branch != nil {
                    tab.prNumber = nil
                    tab.prURL = nil
                    tab.prState = nil
                }
            }
        }
    }

    private func watchHistory() {
        historyWatcher = HistoryWatcher(paths: [Transcript.projectsDir, CodexThreads.home]) { [weak self] in
            self?.refreshHistory()
        }
    }

    func refreshHistory() {
        guard !historyRefreshing else {
            historyRefreshPending = true
            return
        }
        historyRefreshing = true
        let snapshot = projects
        let searching = Set(searchQuery.keys)
        // Keep one extra closed session so the sidebar knows whether more remain.
        let limits = Dictionary(uniqueKeysWithValues: snapshot.map {
            ($0.id, max(40, historyVisibleCount(for: $0) + tabs.count + 1))
        })
        infoQueue.async { [weak self] in
            var result: [UUID: [SessionSummary]] = [:]
            for p in snapshot {
                result[p.id] = Self.history(projectPath: p.path, limit: searching.contains(p.id) ? .max : limits[p.id]!)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Failed reads preserve the last good normal and search snapshots.
                for (id, items) in result where self.project(id) != nil {
                    self.history[id] = items
                    if searching.contains(id), self.searchQuery[id] != nil {
                        self.searchHistory[id] = items
                        self.searchPrompts(id)
                    }
                }
                self.historyRefreshing = false
                if self.historyRefreshPending {
                    self.historyRefreshPending = false
                    self.refreshHistory()
                }
            }
        }
    }

    /// Claude and Codex sessions of a project, newest first.
    static func history(projectPath: String, limit: Int = 40) -> [SessionSummary]? {
        guard let codex = CodexThreads.history(projectPath: projectPath, limit: limit) else { return nil }
        let all = Transcript.history(projectPath: projectPath, limit: limit)
            + codex
        return Array(all.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// History sessions that aren't currently open in a tab.
    func closedHistory(for project: Project) -> [SessionSummary] {
        let open = Set(tabs.map(\.sessionID))
        return (searchHistory[project.id] ?? history[project.id] ?? []).filter { !open.contains($0.id) }
    }

    // MARK: - Search

    func openSearch(_ project: Project) {
        updateProject(project.id) { $0.expanded = true }
        if searchQuery[project.id] == nil { searchQuery[project.id] = "" }
        let id = project.id, path = project.path
        infoQueue.async { [weak self] in
            guard let all = Self.history(projectPath: path, limit: .max) else { return }
            DispatchQueue.main.async {
                guard let self, self.searchQuery[id] != nil else { return }
                self.searchHistory[id] = all
                self.searchPrompts(id)
            }
        }
    }

    func closeSearch(_ project: Project) {
        searchQuery.removeValue(forKey: project.id)
        searchHistory.removeValue(forKey: project.id)
        promptSearchWork.removeValue(forKey: project.id)?.cancel()
        promptMatches.removeValue(forKey: project.id)
    }

    func setSearchQuery(_ query: String, for project: Project) {
        searchQuery[project.id] = query
        searchPrompts(project.id, after: 0.15)
    }

    /// The typed prompt `sessionID` matched the project's current query with, if any.
    func promptMatch(_ project: Project, sessionID: String) -> PromptSnippet? {
        guard let matches = promptMatches[project.id], matches.query == searchQuery[project.id]?.nonEmpty else { return nil }
        return matches.sessions[sessionID]
    }

    /// Searches the typed prompts of the project's sessions (open and past) for its
    /// query, off the main thread. Results for an outdated query are dropped.
    private func searchPrompts(_ id: UUID, after delay: TimeInterval = 0) {
        promptSearchWork.removeValue(forKey: id)?.cancel()
        guard let query = searchQuery[id]?.nonEmpty else {
            promptMatches.removeValue(forKey: id)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.promptSearchWork.removeValue(forKey: id)
            var claude = Set<String>(), codex = Set<String>()
            let open = self.tabs.filter { $0.projectID == id }.map { (kind: $0.kind, id: $0.sessionID) }
            let past = (self.searchHistory[id] ?? self.history[id] ?? []).map { (kind: $0.kind, id: $0.id) }
            for session in open + past where !session.id.isEmpty {
                if session.kind == .claude { claude.insert(session.id) } else { codex.insert(session.id) }
            }
            self.searchQueue.async {
                let sessions = Transcript.promptMatches(query, sessionIDs: claude)
                    .merging(CodexThreads.promptMatches(query, threadIDs: codex)) { first, _ in first }
                DispatchQueue.main.async {
                    guard self.searchQuery[id]?.nonEmpty == query else { return }
                    self.promptMatches[id] = PromptMatches(query: query, sessions: sessions)
                }
            }
        }
        promptSearchWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Attention

    func updateDockBadge() {
        let n = tabs.filter(\.attention).count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    func notify(_ tab: TabSession, body: String) {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = tab.title
        if let p = project(tab.projectID) { content.subtitle = p.name }
        content.body = body
        content.userInfo = ["tab": tab.id.uuidString]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("Vhostty: notification failed: %@", error.localizedDescription) }
        }
    }

    var workingAgentCount: Int {
        tabs.filter { $0.status == .working && ($0.surface.map { !$0.processExited } ?? false) }.count
    }
}

/// Prompt search results of one query: matching session ids and their snippets.
struct PromptMatches {
    let query: String
    let sessions: [String: PromptSnippet]
}
