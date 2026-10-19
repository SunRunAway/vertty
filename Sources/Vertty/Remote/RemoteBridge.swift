import AppKit
import VerttyRemote

/// What the remote client sees of and does to the app: State, the session
/// requests, and the terminal it has open. Main thread only.
final class RemoteBridge {
    private unowned let store: AppStore
    private unowned let server: RemoteServer
    private var connection: RemoteConnection?
    private var stateTimer: Timer?
    private var lastState: Data?
    /// NewSession operation ids already handled, oldest first.
    private var operations: [(id: String, tab: UUID)] = []
    /// The terminal the client has open.
    private var attached: Attachment?
    /// Terminal data leaves the IO thread through here, in order.
    private let sendQueue = DispatchQueue(label: "vertty.remote.send", qos: .userInitiated)

    private struct Attachment {
        let tab: TabSession
        let surface: TerminalSurfaceView
    }

    /// Closed sessions per project in State; more come with ListHistory.
    private static let stateHistoryCount = 40

    init(store: AppStore, server: RemoteServer) {
        self.store = store
        self.server = server
    }

    func clientConnected(_ connection: RemoteConnection) {
        RemoteLog.note("server: client connected")
        self.connection = connection
        lastState = nil
        sendStateIfChanged()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func clientDisconnected(_ connection: RemoteConnection) {
        guard connection === self.connection else { return }
        RemoteLog.note("server: client disconnected")
        detach()
        stateTimer?.invalidate()
        stateTimer = nil
        self.connection = nil
    }

    func notify(_ tab: TabSession, title: String, body: String) {
        connection?.send {
            $0.notification.cardID = tab.id.uuidString
            $0.notification.title = title
            $0.notification.body = body
        }
    }

    private func tick() {
        sendStateIfChanged()
        guard let a = attached else { return }
        if !store.tabs.contains(where: { $0 === a.tab }) || a.tab.surface == nil {
            // Closed here, or its terminal was released (a scheduled run).
            detach()
            connection?.send { $0.terminalClosed.cardID = a.tab.id.uuidString }
        } else if let surface = a.tab.surface, surface !== a.surface {
            // Restarted in a new terminal: follow it.
            let grid = a.surface.remoteGrid
            detach()
            attach(a.tab, surface: surface, columns: grid?.columns ?? surface.gridSize.columns,
                   rows: grid?.rows ?? surface.gridSize.rows)
        }
    }

    // MARK: - State

    private func sendStateIfChanged() {
        guard let connection else { return }
        let state = makeState()
        guard let data = try? state.serializedData(), data != lastState else { return }
        lastState = data
        connection.send { $0.state = state }
    }

    private func makeState() -> Remote.State {
        var state = Remote.State()
        state.projects = store.projects.map { p in
            var rp = Remote.Project()
            rp.id = p.id.uuidString
            rp.name = p.name
            rp.path = p.path
            rp.defaultKind = Self.kind(store.defaultKind(p))
            return rp
        }
        state.cards = store.orderedTabs.map(card)
        let open = Set(store.tabs.map(\.sessionID))
        state.history = store.projects.map { p in
            let all = (store.history[p.id] ?? []).filter { !open.contains($0.id) }
            var h = Remote.ProjectHistory()
            h.projectID = p.id.uuidString
            h.sessions = all.prefix(Self.stateHistoryCount).map(Self.entry)
            h.moreAvailable = all.count > Self.stateHistoryCount || (store.history[p.id]?.count ?? 0) >= Self.stateHistoryCount
            return h
        }
        state.confirmClose = !UserDefaults.standard.bool(forKey: AppStore.skipCloseConfirmKey)
        return state
    }

    private func card(_ tab: TabSession) -> Remote.Card {
        var c = Remote.Card()
        c.id = tab.id.uuidString
        c.projectID = tab.projectID.uuidString
        c.kind = Self.kind(tab.kind)
        c.title = tab.title
        c.branch = tab.branch ?? ""
        c.worktree = tab.worktree ?? ""
        c.prNumber = UInt32(tab.prNumber ?? 0)
        c.prState = tab.prState ?? ""
        c.status = Self.status(tab.shownStatus)
        c.running = tab.surface.map { !$0.processExited } ?? false
        c.sessionID = tab.sessionID
        c.attention = tab.attention
        c.prURL = tab.prURL ?? ""
        return c
    }

    static func kind(_ kind: AgentKind) -> Remote.AgentKind {
        kind == .claude ? .claude : .codex
    }

    static func kind(_ kind: Remote.AgentKind) -> AgentKind? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        default: return nil
        }
    }

    private static func status(_ status: SessionStatus) -> Remote.SessionStatus {
        switch status {
        case .dormant: return .dormant
        case .starting: return .starting
        case .working: return .working
        case .idle: return .idle
        case .needsInput: return .needsInput
        case .exited: return .exited
        }
    }

    private static func entry(_ s: SessionSummary) -> Remote.HistoryEntry {
        var e = Remote.HistoryEntry()
        e.sessionID = s.id
        e.kind = kind(s.kind)
        e.title = s.title
        e.modifiedMs = Int64(s.modified.timeIntervalSince1970 * 1000)
        return e
    }

    // MARK: - Messages

    func handle(_ msg: Remote.ClientMessage, from connection: RemoteConnection) {
        let id = msg.requestID
        switch msg.body {
        case .newSession(let r): newSession(r, id)
        case .resumeSession(let r): resumeSession(r, id)
        case .closeSession(let r): closeSession(r, id)
        case .listHistory(let r): listHistory(r, id)
        case .searchHistory(let r): searchHistory(r, id)
        case .openTerminal(let r):
            RemoteLog.note("server: open \(r.size.text)")
            openTerminal(r.cardID, r.size)
        case .leaveTerminal(let r):
            RemoteLog.note("server: leave")
            if attached?.tab.id.uuidString == r.cardID { detach() }
        case .viewport(let r):
            RemoteLog.note("server: viewport \(r.size.text)")
            resize(r.cardID, r.size)
        case .alignForInput(let r):
            if let a = attached, a.surface.remoteGrid.map({ $0.columns != Int(r.size.columns) || $0.rows != Int(r.size.rows) }) ?? true {
                RemoteLog.note("server: align \(r.size.text)")
            }
            resize(r.cardID, r.size)
        case .input(let r):
            guard let a = attached, a.tab.id.uuidString == r.cardID else { return }
            a.surface.writePTY(r.data)
        case .readTerminal(let r):
            guard let a = attached, a.tab.id.uuidString == r.cardID, a.tab.attention else { return }
            a.tab.attention = false
            store.updateDockBadge()
            sendStateIfChanged()
        case .hello, nil:
            break
        }
    }

    private func reply(_ id: UInt64, _ fill: (inout Remote.Reply) -> Void) {
        var reply = Remote.Reply()
        reply.requestID = id
        fill(&reply)
        connection?.send { $0.reply = reply }
    }

    private func fail(_ id: UInt64, _ code: Remote.ErrorCode, _ message: String) {
        reply(id) {
            $0.error.code = code
            $0.error.message = message
        }
    }

    private func project(_ id: String) -> Project? {
        UUID(uuidString: id).flatMap(store.project)
    }

    private func tab(_ id: String) -> TabSession? {
        UUID(uuidString: id).flatMap(store.tab(withID:))
    }

    private func newSession(_ r: Remote.NewSession, _ id: UInt64) {
        if let done = operations.first(where: { $0.id == r.operationID }), !r.operationID.isEmpty {
            // A retry of a request that already went through.
            guard store.tab(withID: done.tab) != nil else { return fail(id, .notFound, "The session was closed.") }
            return reply(id) { $0.session.cardID = done.tab.uuidString }
        }
        guard let project = project(r.projectID) else { return fail(id, .notFound, "No such project.") }
        let tab = store.newSessionInBackground(in: project, kind: Self.kind(r.kind))
        if !r.operationID.isEmpty {
            operations.append((r.operationID, tab.id))
            if operations.count > 200 { operations.removeFirst() }
        }
        sendStateIfChanged()
        reply(id) { $0.session.cardID = tab.id.uuidString }
    }

    private func resumeSession(_ r: Remote.ResumeSession, _ id: UInt64) {
        guard let project = project(r.projectID) else { return fail(id, .notFound, "No such project.") }
        if let open = store.tabs.first(where: { $0.sessionID == r.sessionID }) {
            return reply(id) { $0.session.cardID = open.id.uuidString }
        }
        let kind = Self.kind(r.kind) ?? .claude
        let summary = store.history[project.id]?.first { $0.id == r.sessionID }
        // Only resume what can be resumed: starting the agent with an
        // unknown id would quietly begin a new session instead.
        store.infoQueue.async { [weak self] in
            let exists = kind == .claude
                ? Transcript.locate(sessionID: r.sessionID, projectPath: project.path) != nil
                : CodexThreads.thread(id: r.sessionID) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard exists, !r.sessionID.isEmpty else {
                    return self.fail(id, .resumeFailed, "No such session.")
                }
                // It may have been opened meanwhile.
                if let open = self.store.tabs.first(where: { $0.sessionID == r.sessionID }) {
                    return self.reply(id) { $0.session.cardID = open.id.uuidString }
                }
                let tab = self.store.resumeInBackground(sessionID: r.sessionID, kind: kind, title: summary?.title, in: project)
                self.sendStateIfChanged()
                self.reply(id) { $0.session.cardID = tab.id.uuidString }
            }
        }
    }

    private func closeSession(_ r: Remote.CloseSession, _ id: UInt64) {
        guard let tab = tab(r.cardID) else { return reply(id) { $0.closed = .init() } }
        let running = tab.surface.map { !$0.processExited } ?? false
        if running && !r.confirmed && !UserDefaults.standard.bool(forKey: AppStore.skipCloseConfirmKey) {
            return fail(id, .confirmationRequired, "Closing ends the running session.")
        }
        if attached?.tab === tab {
            detach()
            connection?.send { $0.terminalClosed.cardID = r.cardID }
        }
        store.closeTab(tab, force: true)
        sendStateIfChanged()
        reply(id) { $0.closed = .init() }
    }

    private func listHistory(_ r: Remote.ListHistory, _ id: UInt64) {
        guard let project = project(r.projectID) else { return fail(id, .notFound, "No such project.") }
        let limit = Int(min(max(r.limit, 1), 5000))
        let open = Set(store.tabs.map(\.sessionID))
        store.infoQueue.async { [weak self] in
            let all = AppStore.history(projectPath: project.path, limit: limit + open.count + 1)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let all else { return self.fail(id, .internal, "Couldn't read the history.") }
                let closed = all.filter { !open.contains($0.id) }
                self.reply(id) {
                    $0.history.projectID = r.projectID
                    $0.history.sessions = closed.prefix(limit).map(Self.entry)
                    $0.history.moreAvailable = closed.count > limit
                }
            }
        }
    }

    /// What the computer's own search shows (see AppStore.openSearch).
    private func searchHistory(_ r: Remote.SearchHistory, _ id: UInt64) {
        guard let project = project(r.projectID) else { return fail(id, .notFound, "No such project.") }
        let openIDs = Set(store.tabs.map(\.sessionID))
        let open = store.tabs(of: project).map { (kind: $0.kind, id: $0.sessionID) }
        let query = r.query
        store.infoQueue.async { [weak self] in
            let all = AppStore.history(projectPath: project.path, limit: .max)
            var prompts: [String: PromptSnippet] = [:]
            if let all, !query.isEmpty {
                var claude = Set<String>(), codex = Set<String>()
                for session in open + all.map({ (kind: $0.kind, id: $0.id) }) where !session.id.isEmpty {
                    if session.kind == .claude { claude.insert(session.id) } else { codex.insert(session.id) }
                }
                prompts = Transcript.promptMatches(query, sessionIDs: claude)
                    .merging(CodexThreads.promptMatches(query, threadIDs: codex)) { first, _ in first }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let all else { return self.fail(id, .internal, "Couldn't read the history.") }
                self.reply(id) {
                    $0.search.query = query
                    $0.search.sessions = all.filter { !openIDs.contains($0.id) }.map(Self.entry)
                    $0.search.prompts = prompts.map { sessionID, snippet in
                        var m = Remote.PromptMatch()
                        m.sessionID = sessionID
                        m.before = snippet.before
                        m.match = snippet.match
                        m.after = snippet.after
                        return m
                    }
                }
            }
        }
    }

    // MARK: - Terminal

    private func openTerminal(_ cardID: String, _ size: Remote.TerminalSize) {
        detach()
        guard let tab = tab(cardID) else {
            connection?.send { $0.terminalClosed.cardID = cardID }
            return
        }
        store.launchInBackground(tab)
        guard let surface = tab.surface else {
            connection?.send { $0.terminalClosed.cardID = cardID }
            return
        }
        attach(tab, surface: surface, columns: Int(size.columns), rows: Int(size.rows))
    }

    private func attach(_ tab: TabSession, surface: TerminalSurfaceView, columns: Int, rows: Int) {
        attached = Attachment(tab: tab, surface: surface)
        surface.useRemoteGrid(columns: columns, rows: rows)
        let cardID = tab.id.uuidString
        let queue = sendQueue
        surface.startTap { [weak connection] event in
            queue.async {
                guard let connection else { return }
                switch event {
                case .snapshot(let columns, let rows, let data):
                    connection.send {
                        $0.snapshot.cardID = cardID
                        $0.snapshot.size = Remote.TerminalSize(columns: columns, rows: rows)
                        $0.snapshot.data = data
                    }
                case .output(let data):
                    connection.send {
                        $0.output.cardID = cardID
                        $0.output.data = data
                    }
                }
            }
        }
    }

    /// The client stopped showing the terminal: back to the local size.
    private func detach() {
        guard let a = attached else { return }
        attached = nil
        a.surface.stopTap()
        a.surface.useLocalGrid(because: "client left")
    }

    /// The latest size change wins (see TERMINAL SIZE AND INPUT).
    private func resize(_ cardID: String, _ size: Remote.TerminalSize) {
        guard let a = attached, a.tab.id.uuidString == cardID else { return }
        let (c, r) = (Int(size.columns), Int(size.rows))
        let current = a.surface.gridSize
        if a.surface.remoteGrid == nil || current.columns != c || current.rows != r {
            a.surface.useRemoteGrid(columns: c, rows: r)
        }
    }
}
