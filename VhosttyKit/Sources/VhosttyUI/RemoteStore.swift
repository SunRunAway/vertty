import Combine
import Foundation
import SwiftUI
import UserNotifications
import VhosttyRemote

/// A card on the computer, as RemoteStore keeps it for the sidebar.
public final class RemoteCard: SessionCardModel {
    public let id: UUID
    public let projectID: UUID
    @Published public private(set) var kind: AgentKind = .claude
    @Published public private(set) var sessionID = ""
    @Published public private(set) var title = ""
    @Published public private(set) var branch: String?
    @Published public private(set) var worktree: String?
    @Published public private(set) var prNumber: Int?
    @Published public private(set) var prURL: String?
    @Published public private(set) var prState: String?
    @Published public private(set) var status: SessionStatus = .starting
    @Published public private(set) var attention = false
    /// Its terminal runs a program (closing ends it).
    public private(set) var running = false

    init?(_ c: Remote.Card) {
        guard let id = UUID(uuidString: c.id), let projectID = UUID(uuidString: c.projectID) else { return nil }
        self.id = id
        self.projectID = projectID
        update(c)
    }

    func update(_ c: Remote.Card) {
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<RemoteCard, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        set(\.kind, AgentKind(c.kind))
        set(\.sessionID, c.sessionID)
        set(\.title, c.title)
        set(\.branch, c.branch.nonEmpty)
        set(\.worktree, c.worktree.nonEmpty)
        set(\.prNumber, c.prNumber > 0 ? Int(c.prNumber) : nil)
        set(\.prURL, c.prURL.nonEmpty)
        set(\.prState, c.prState.nonEmpty)
        set(\.status, SessionStatus(c.status))
        set(\.attention, c.attention)
        running = c.running
    }
}

/// The terminal a RemoteStore shows the selected card in: Vhostty's own
/// terminal view on the Mac, libghostty-spm's on iOS.
public protocol RemoteTerminalDisplay: AnyObject {
    /// The grid that fits the display area, once known.
    var ownSize: Remote.TerminalSize? { get }
    /// Lay the terminal out at the session's grid; call
    /// RemoteStore.terminalGridApplied once the terminal has it.
    func showGrid(_ size: Remote.TerminalSize)
    /// The program's output.
    func feed(_ data: Data)
}

/// Another computer's sessions, in the shared sidebar: its projects, cards
/// and history from the connection's State, the session requests, and the
/// terminal of the selected card. Main thread only.
public final class RemoteStore: ObservableObject, SidebarStore, SidebarLayoutModel, RemoteTerminalSink {
    public let id = UUID().uuidString
    public let client: RemoteClient

    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var allCards: [RemoteCard] = []
    /// The card whose terminal is shown. Cleared, the terminal is left.
    @Published public var selectedCardID: UUID? {
        didSet { if selectedCardID != oldValue { selectionChanged() } }
    }
    /// A card whose closing waits for the user's confirmation.
    @Published public var confirmingClose: RemoteCard?
    /// The last request that failed, for an alert.
    @Published public var failure: String?
    @Published public var sidebarVisible = true
    #if os(iOS)
    @Published public var sidebarWidth: CGFloat = 340
    #else
    @Published public var sidebarWidth: CGFloat = 300
    #endif
    /// The terminal's background (the Mac's Ghostty theme there).
    public var terminalBackground = Color(red: 0.16, green: 0.17, blue: 0.20)
    /// Whether the user is looking at this card right now (no notification
    /// then). Set by the app.
    public var isViewing: (UUID) -> Bool = { _ in false }

    private var collapsed: Set<UUID> = []
    private var historyShown: [UUID: Int] = [:]
    private var fetchedHistory: [UUID: Remote.ProjectHistory] = [:]
    private var searchQueries: [UUID: String] = [:]
    private var searchResults: [UUID: Remote.SearchResult] = [:]
    private var searchWork: [UUID: DispatchWorkItem] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    // The terminal of the selected card.
    private weak var display: RemoteTerminalDisplay?
    /// The grid the terminal has now, as it last reported.
    private var appliedGrid: Remote.TerminalSize?
    /// A snapshot waiting for the terminal to take its size, with the
    /// output that came after it.
    private var awaiting: Remote.TerminalSize?
    private var queued: [Data] = []
    private var awaitingTimeout: DispatchWorkItem?
    /// The size last sent for the open terminal.
    private var sentSize: Remote.TerminalSize?

    public init(url: URL, platform: Remote.ClientPlatform, deviceName: String) {
        client = RemoteClient(url: url, platform: platform, deviceName: deviceName)
        client.terminalSink = self
        client.onNotification = { [weak self] n in self?.notify(n) }
        // Republish the client's changes, and rebuild from each State.
        client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        client.$state.sink { [weak self] state in self?.apply(state) }.store(in: &subscriptions)
    }

    public var state: Remote.State { client.state }
    public var serverName: String { client.serverName.isEmpty ? client.url.host ?? "" : client.serverName }

    private func apply(_ state: Remote.State) {
        projects = state.projects.compactMap { p in
            guard let id = UUID(uuidString: p.id) else { return nil }
            return Project(id: id, name: p.name, path: p.path, expanded: !collapsed.contains(id), defaultKind: AgentKind(p.defaultKind))
        }
        var existing = Dictionary(uniqueKeysWithValues: allCards.map { ($0.id, $0) })
        allCards = state.cards.compactMap { c in
            if let id = UUID(uuidString: c.id), let card = existing.removeValue(forKey: id) {
                card.update(c)
                return card
            }
            return RemoteCard(c)
        }
        if let selected = selectedCardID, !allCards.contains(where: { $0.id == selected }), client.hasState {
            selectedCardID = nil
        }
    }

    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    public func card(_ id: UUID?) -> RemoteCard? { allCards.first { $0.id == id } }
    public var selectedCard: RemoteCard? { card(selectedCardID) }

    /// Where new sessions go from the keyboard: the selected card's project, else the first.
    public var currentProject: Project? {
        selectedCard.flatMap { project($0.projectID) } ?? projects.first
    }

    /// Selects the card at `index` in sidebar order (⌘1…9).
    public func selectCard(at index: Int) {
        let ordered = projects.flatMap { cards(of: $0) }
        guard ordered.indices.contains(index) else { return }
        selectedCardID = ordered[index].id
    }

    /// Disconnects for good (the window closed, or the user changes address).
    public func close() {
        selectedCardID = nil
        client.disconnect()
    }

    // MARK: - SidebarStore

    public var features: SidebarFeatures { [] }
    public var projectsLoaded: Bool { client.hasState }

    public func cards(of project: Project) -> [RemoteCard] { allCards.filter { $0.projectID == project.id } }

    public func toggleExpanded(_ project: Project) {
        historyShown.removeValue(forKey: project.id)
        if collapsed.remove(project.id) == nil { collapsed.insert(project.id) }
        apply(state)
    }

    public func defaultKind(_ project: Project) -> AgentKind { project.defaultKind ?? .claude }

    public func kindsDefaultFirst(_ project: Project) -> [AgentKind] {
        let first = defaultKind(project)
        return [first, first == .claude ? .codex : .claude]
    }

    public func select(_ card: RemoteCard) {
        selectedCardID = card.id
    }

    public func newSession(in project: Project, kind: AgentKind?) {
        let operation = UUID().uuidString
        Task { @MainActor in
            do {
                let cardID = try await retrying {
                    try await self.client.newSession(projectID: project.id.uuidString, kind: kind.map(Remote.AgentKind.init), operationID: operation)
                }
                self.selectWhenKnown(cardID)
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    public func resumeSession(_ summary: SessionSummary, in project: Project) {
        var entry = Remote.HistoryEntry()
        entry.sessionID = summary.id
        entry.kind = Remote.AgentKind(summary.kind)
        entry.title = summary.title
        Task { @MainActor in
            do {
                let cardID = try await retrying { try await self.client.resumeSession(projectID: project.id.uuidString, entry: entry) }
                self.selectWhenKnown(cardID)
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    public func requestClose(_ card: RemoteCard) {
        if card.running && state.confirmClose {
            confirmingClose = card
        } else {
            close(card, confirmed: false)
        }
    }

    /// Closes a card on the computer (after confirming, when that was needed).
    public func close(_ card: RemoteCard, confirmed: Bool) {
        Task { @MainActor in
            do {
                try await client.closeSession(cardID: card.id.uuidString, confirmed: confirmed)
                if selectedCardID == card.id { selectedCardID = nil }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: History and search

    /// Closed sessions of a project: the search's while searching, else what
    /// State carries, or more if fetched.
    public func closedHistory(for project: Project) -> [SessionSummary] {
        let open = Set(allCards.map(\.sessionID))
        if searchQueries[project.id] != nil {
            return (searchResults[project.id]?.sessions ?? []).filter { !open.contains($0.sessionID) }.map(SessionSummary.init)
        }
        return history(of: project).sessions.filter { !open.contains($0.sessionID) }.map(SessionSummary.init)
    }

    private func history(of project: Project) -> Remote.ProjectHistory {
        let base = state.history.first { $0.projectID == project.id.uuidString }
        let fetched = fetchedHistory[project.id]
        return ((fetched?.sessions.count ?? 0) > (base?.sessions.count ?? 0) ? fetched : base) ?? Remote.ProjectHistory()
    }

    public func historyVisibleCount(for project: Project) -> Int { historyShown[project.id] ?? 5 }

    public func showMoreHistory(_ project: Project) {
        let limit = historyVisibleCount(for: project) + 10
        historyShown[project.id] = limit
        objectWillChange.send()
        // One more than shown, so the sidebar knows whether more remain.
        let h = history(of: project)
        guard h.moreAvailable, closedHistory(for: project).count <= limit else { return }
        Task { @MainActor in
            if let more = try? await client.listHistory(projectID: project.id.uuidString, limit: limit + 1) {
                fetchedHistory[project.id] = more
                objectWillChange.send()
            }
        }
    }

    public func query(for project: Project) -> String? { searchQueries[project.id] }

    public func openSearch(_ project: Project) {
        collapsed.remove(project.id)
        if searchQueries[project.id] == nil { searchQueries[project.id] = "" }
        apply(state)
        search(project.id, after: 0)
    }

    public func closeSearch(_ project: Project) {
        searchQueries.removeValue(forKey: project.id)
        searchResults.removeValue(forKey: project.id)
        searchWork.removeValue(forKey: project.id)?.cancel()
        objectWillChange.send()
    }

    public func setSearchQuery(_ query: String, for project: Project) {
        searchQueries[project.id] = query
        objectWillChange.send()
        search(project.id, after: 0.15)
    }

    public func promptMatch(_ project: Project, sessionID: String) -> PromptSnippet? {
        guard let result = searchResults[project.id], !result.query.isEmpty,
              result.query == searchQueries[project.id] else { return nil }
        return result.prompts.first { $0.sessionID == sessionID }
            .map { PromptSnippet(before: $0.before, match: $0.match, after: $0.after) }
    }

    /// Asks the computer for the project's sessions and the prompts matching
    /// its query; replies for an outdated query are dropped.
    private func search(_ id: UUID, after delay: TimeInterval) {
        searchWork.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let query = self.searchQueries[id] else { return }
            Task { @MainActor in
                guard let result = try? await self.client.searchHistory(projectID: id.uuidString, query: query),
                      self.searchQueries[id] == result.query else { return }
                self.searchResults[id] = result
                self.objectWillChange.send()
            }
        }
        searchWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - SidebarLayoutModel

    public func toggleSidebar() { sidebarVisible.toggle() }
    public func sidebarResized() {}

    // MARK: - Requests

    /// A request again after a dropped connection (the server makes the
    /// retry safe: same operation id, existing card).
    private func retrying<T>(_ request: @escaping () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch let error as RemoteError where error == .disconnected {
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if client.status == .connected { return try await request() }
                if client.status != .reconnecting { break }
            }
            throw error
        }
    }

    /// Selects a card once the State listing it has arrived.
    private func selectWhenKnown(_ cardID: String, attempts: Int = 20) {
        if let id = UUID(uuidString: cardID), card(id) != nil {
            selectedCardID = id
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.selectWhenKnown(cardID, attempts: attempts - 1) }
        }
    }

    // MARK: - Terminal

    /// The terminal view is on screen (or got a new size): opens the
    /// selected card in it.
    public func attach(_ display: RemoteTerminalDisplay) {
        let changed = self.display !== display
        self.display = display
        openSelected(again: changed)
    }

    public func detach(_ display: RemoteTerminalDisplay) {
        if self.display === display { self.display = nil }
    }

    private func selectionChanged() {
        resetStream()
        if selectedCardID == nil {
            client.leaveTerminal()
        } else {
            openSelected()
        }
    }

    /// Opens the selected card's terminal; `again` asks for a new snapshot
    /// even if it's open (a new terminal view shows it).
    private func openSelected(again: Bool = false) {
        guard let id = selectedCardID, let own = display?.ownSize else { return }
        guard again || client.openCardID != id.uuidString else { return }
        resetStream()
        sentSize = own
        client.openTerminal(cardID: id.uuidString, size: own)
    }

    private func resetStream() {
        awaiting = nil
        queued = []
        awaitingTimeout?.cancel()
    }

    /// The display area changed size, or the app came back to the
    /// foreground: the session takes this end's size.
    public func viewportChanged(force: Bool = false) {
        guard client.openCardID != nil, let own = display?.ownSize, force || own != sentSize else { return }
        sentSize = own
        client.viewportChanged(own)
    }

    /// The user is about to type or paste: the session takes this end's size first.
    public func willInput() {
        guard let own = display?.ownSize else { return }
        sentSize = own
        client.alignForInput(own)
    }

    /// Bytes the terminal wrote (keys, paste, mouse).
    public func input(_ data: Data) {
        client.input(data)
    }

    /// The terminal has this grid now.
    public func terminalGridApplied(_ size: Remote.TerminalSize) {
        appliedGrid = size
        if let a = awaiting, a == size { flush() }
    }

    public func remoteSnapshot(cardID: String, columns: Int, rows: Int, data: Data) {
        guard cardID == selectedCardID?.uuidString, let display else { return }
        // The terminal shows the session at its size: take it, then replay.
        let grid = Remote.TerminalSize(columns: columns, rows: rows)
        awaiting = grid
        queued = [data]
        display.showGrid(grid)
        if appliedGrid == grid {
            flush()
        } else {
            awaitingTimeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            awaitingTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    public func remoteOutput(cardID: String, data: Data) {
        guard cardID == selectedCardID?.uuidString else { return }
        if awaiting != nil {
            queued.append(data)
        } else {
            display?.feed(data)
        }
    }

    public func remoteTerminalClosed(cardID: String) {
        guard cardID == selectedCardID?.uuidString else { return }
        selectedCardID = nil
    }

    private func flush() {
        guard awaiting != nil else { return }
        awaitingTimeout?.cancel()
        awaiting = nil
        let data = queued
        queued = []
        for d in data { display?.feed(d) }
    }

    // MARK: - Notifications

    private var askedForNotifications = false

    /// Asks once, when first connected, so notifications can be shown.
    public func askForNotifications() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ n: Remote.Notification) {
        guard let id = UUID(uuidString: n.cardID), !isViewing(id) else { return }
        let content = UNMutableNotificationContent()
        let card = card(id)
        content.title = card?.title ?? n.title
        content.subtitle = [serverName, card.flatMap { project($0.projectID)?.name } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = n.body.isEmpty ? n.title : n.body
        content.userInfo = ["remoteStore": self.id, "remoteCard": n.cardID]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension AgentKind {
    init(_ kind: Remote.AgentKind) { self = kind == .codex ? .codex : .claude }
}

extension Remote.AgentKind {
    init(_ kind: AgentKind) { self = kind == .codex ? .codex : .claude }
}

extension SessionStatus {
    init(_ status: Remote.SessionStatus) {
        switch status {
        case .dormant: self = .dormant
        case .working: self = .working
        case .idle: self = .idle
        case .needsInput: self = .needsInput
        case .exited: self = .exited
        default: self = .starting
        }
    }
}

extension SessionSummary {
    init(_ e: Remote.HistoryEntry) {
        self.init(id: e.sessionID, title: e.title, modified: Date(timeIntervalSince1970: Double(e.modifiedMs) / 1000),
                  kind: AgentKind(e.kind))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
