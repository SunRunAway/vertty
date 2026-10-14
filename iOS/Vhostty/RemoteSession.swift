import Combine
import Foundation
import UIKit
import UserNotifications
import VhosttyRemote

/// The connection to one computer and what the app shows of it: its
/// projects, cards and history, and the terminal of the card that's open.
final class RemoteSession: ObservableObject, RemoteTerminalSink {
    let client: RemoteClient

    /// The card whose terminal screen is shown.
    @Published var path: [String] = [] {
        // Leaving the terminal gives the session back the computer's size.
        didSet { if path.isEmpty { client.leaveTerminal() } }
    }
    /// How many closed sessions each project shows (more per "Show More").
    @Published var historyShown: [String: Int] = [:]
    /// Older history fetched with ListHistory, per project.
    @Published var fetchedHistory: [String: Remote.ProjectHistory] = [:]
    /// The last request that failed, for an alert.
    @Published var failure: String?

    /// The terminal on screen, while a card is open.
    weak var terminal: TerminalViewController?
    private var forwarding: AnyCancellable?
    private var askedForNotifications = false

    init(url: URL) {
        client = RemoteClient(url: url, platform: .iphone, deviceName: UIDevice.current.name)
        client.terminalSink = self
        client.onNotification = { [weak self] n in self?.notify(n) }
        // Republish the client's changes so views of the session update.
        forwarding = client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var state: Remote.State { client.state }
    var openCardID: String? { path.last }

    // MARK: - Terminal

    func remoteSnapshot(cardID: String, columns: Int, rows: Int, data: Data) {
        guard cardID == terminal?.cardID else { return }
        terminal?.showSnapshot(columns: columns, rows: rows, data: data)
    }

    func remoteOutput(cardID: String, data: Data) {
        guard cardID == terminal?.cardID else { return }
        terminal?.showOutput(data)
    }

    func remoteTerminalClosed(cardID: String) {
        if path.last == cardID { path.removeLast() }
    }

    /// The app came back to the foreground: the open terminal takes the
    /// iPhone's size again.
    func cameToForeground() {
        client.reconnectsAutomatically = true
        terminal?.reportViewport()
    }

    func wentToBackground() {
        client.reconnectsAutomatically = false
    }

    // MARK: - Sessions

    func project(_ id: String) -> Remote.Project? { state.projects.first { $0.id == id } }
    func card(_ id: String?) -> Remote.Card? { state.cards.first { $0.id == id } }
    func cards(of project: Remote.Project) -> [Remote.Card] { state.cards.filter { $0.projectID == project.id } }

    /// Closed sessions of a project: what State carries, or more if fetched.
    func history(of project: Remote.Project) -> (sessions: [Remote.HistoryEntry], more: Bool) {
        let open = Set(state.cards.map(\.sessionID))
        let base = state.history.first { $0.projectID == project.id }
        let fetched = fetchedHistory[project.id]
        let source = (fetched?.sessions.count ?? 0) > (base?.sessions.count ?? 0) ? fetched : base
        let sessions = (source?.sessions ?? []).filter { !open.contains($0.sessionID) }
        return (sessions, source?.moreAvailable ?? false)
    }

    func historyLimit(_ project: Remote.Project) -> Int { historyShown[project.id] ?? 5 }

    func showMoreHistory(_ project: Remote.Project) {
        let limit = historyLimit(project) + 10
        historyShown[project.id] = limit
        let h = history(of: project)
        guard h.sessions.count < limit, h.more else { return }
        Task { @MainActor in
            if let more = try? await client.listHistory(projectID: project.id, limit: limit + 10) {
                fetchedHistory[project.id] = more
            }
        }
    }

    func kindsDefaultFirst(_ project: Remote.Project) -> [Remote.AgentKind] {
        let first: Remote.AgentKind = project.defaultKind == .codex ? .codex : .claude
        return [first, first == .claude ? .codex : .claude]
    }

    func open(_ cardID: String) {
        if path.last != cardID { path = [cardID] }
    }

    func newSession(in project: Remote.Project, kind: Remote.AgentKind?) {
        let operation = UUID().uuidString
        Task { @MainActor in
            do {
                let cardID = try await retrying { try await self.client.newSession(projectID: project.id, kind: kind, operationID: operation) }
                self.openWhenKnown(cardID)
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    func resume(_ entry: Remote.HistoryEntry, in project: Remote.Project) {
        Task { @MainActor in
            do {
                let cardID = try await retrying { try await self.client.resumeSession(projectID: project.id, entry: entry) }
                self.openWhenKnown(cardID)
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    /// Whether closing `card` has to be confirmed first (as on the computer).
    func needsConfirmation(_ card: Remote.Card) -> Bool {
        card.running && state.confirmClose
    }

    func close(_ card: Remote.Card, confirmed: Bool) {
        Task { @MainActor in
            do {
                try await client.closeSession(cardID: card.id, confirmed: confirmed)
                if path.last == card.id { path.removeLast() }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

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

    /// Opens a card once the State listing it has arrived.
    private func openWhenKnown(_ cardID: String, attempts: Int = 20) {
        if card(cardID) != nil {
            open(cardID)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openWhenKnown(cardID, attempts: attempts - 1) }
        }
    }

    // MARK: - Notifications

    /// Asks once, when first connected, so notifications can be shown.
    func askForNotifications() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ n: Remote.Notification) {
        // Not while you're looking at that card.
        if n.cardID == openCardID && UIApplication.shared.applicationState == .active { return }
        let content = UNMutableNotificationContent()
        let card = card(n.cardID)
        content.title = card?.title ?? n.title
        content.subtitle = [client.serverName, card.flatMap { project($0.projectID)?.name } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = n.body.isEmpty ? n.title : n.body
        content.userInfo = ["card": n.cardID]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
