import AppKit
import Combine
import SwiftUI
import UserNotifications
import VhosttyRemote

/// The desktop remote client: a window showing another computer's
/// Vhostty (its projects, cards and history) and the terminal of the card
/// you open. Its sessions run on that computer.
final class RemoteWindowController: NSObject, NSWindowDelegate {
    private(set) static var all: [RemoteWindowController] = []
    static let lastURLKey = "RemoteLastURL"

    let model: RemoteModel
    let window: NSWindow

    /// Asks for the address, then opens a window connected to it.
    static func connectViaPrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect to Remote Computer")
        alert.informativeText = String(localized: "The address shown in Remote Connection Info on the other computer. The connection's security is up to you (for example a VPN).")
        let field = NSTextField(string: UserDefaults.standard.string(forKey: lastURLKey) ?? "")
        field.placeholderString = "ws://192.168.1.5:58563"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = remoteURL(from: field.stringValue) else {
            let bad = NSAlert()
            bad.messageText = String(localized: "That isn't an address Vhostty can connect to.")
            bad.informativeText = String(localized: "Enter a host and port, such as 192.168.1.5:58563 or ws://mac.local:58563.")
            bad.runModal()
            return
        }
        UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: lastURLKey)
        open(url)
    }

    static func open(_ url: URL) {
        let controller = RemoteWindowController(url: url)
        all.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        controller.model.client.connect()
    }

    /// The remote window whose terminal this is, if any.
    static func owner(of surface: TerminalSurfaceView?) -> RemoteWindowController? {
        guard let surface else { return nil }
        return all.first { $0.model.terminalIfCreated === surface }
    }

    /// The remote window in front, if the key window is one.
    static var key: RemoteWindowController? {
        all.first { $0.window.isKeyWindow }
    }

    static func withID(_ id: String) -> RemoteWindowController? {
        all.first { $0.model.id == id }
    }

    private init(url: URL) {
        model = RemoteModel(url: url)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Remote")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(AppStore.shared.terminalBackground)
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: RemoteRootView(model: model))
        window.center()
        window.setFrameAutosaveName("VhosttyRemoteWindow")
        model.window = window
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.focusTerminal()
    }
}

/// One remote window's state: the connection, what's expanded and open,
/// and the terminal showing the open card.
final class RemoteModel: ObservableObject, RemoteTerminalSink {
    let id = UUID().uuidString
    let client: RemoteClient
    weak var window: NSWindow?

    /// The card whose terminal is shown.
    @Published private(set) var openCardID: String?
    @Published var collapsed: Set<String> = []
    /// How many closed sessions each project shows (5 more per "Show More").
    @Published var historyShown: [String: Int] = [:]
    /// Older history fetched with ListHistory, per project.
    @Published var fetchedHistory: [String: Remote.ProjectHistory] = [:]

    private var forwarding: AnyCancellable?
    private(set) var terminalIfCreated: TerminalSurfaceView?
    /// The grid the terminal has now, as it last reported.
    private var terminalGrid: (columns: Int, rows: Int)?
    /// A snapshot waiting for the terminal to take its size, with the
    /// output that came after it.
    private var awaiting: (columns: Int, rows: Int)?
    private var queued: [Data] = []
    private var awaitingTimeout: DispatchWorkItem?

    init(url: URL) {
        client = RemoteClient(url: url, platform: .mac, deviceName: Host.current().localizedName ?? "Mac")
        client.terminalSink = self
        client.onNotification = { [weak self] n in self?.notify(n) }
        // Republish the client's changes so views of the model update.
        forwarding = client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var state: Remote.State { client.state }

    func close() {
        client.disconnect()
        terminalIfCreated = nil
    }

    // MARK: - Terminal

    var terminal: TerminalSurfaceView {
        if let t = terminalIfCreated { return t }
        let hooks = TerminalSurfaceView.RemoteHooks(
            write: { [weak self] data in
                DispatchQueue.main.async { self?.client.input(data) }
            },
            resized: { [weak self] columns, rows in
                DispatchQueue.main.async { self?.terminalResized(columns, rows) }
            },
            willInput: { [weak self] in
                guard let self else { return }
                self.client.alignForInput(self.ownSize)
            },
            displayResized: { [weak self] in
                guard let self, self.openCardID != nil else { return }
                self.client.viewportChanged(self.ownSize)
            })
        let t = TerminalSurfaceView(options: .init(remote: hooks))
        terminalIfCreated = t
        return t
    }

    /// What the terminal's display area holds.
    private var ownSize: Remote.TerminalSize {
        let g = terminal.naturalGrid
        return Remote.TerminalSize(columns: g.columns, rows: g.rows)
    }

    func open(_ card: Remote.Card) {
        guard openCardID != card.id else {
            focusTerminal()
            return
        }
        openCardID = card.id
        awaiting = nil
        queued = []
        // Let the terminal take its place in the window first, so its size is known.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openCardID == card.id else { return }
            self.client.openTerminal(cardID: card.id, size: self.ownSize)
            self.focusTerminal()
        }
    }

    func focusTerminal() {
        guard openCardID != nil, let t = terminalIfCreated, let window else { return }
        DispatchQueue.main.async { if window.firstResponder !== t { window.makeFirstResponder(t) } }
    }

    func remoteSnapshot(cardID: String, columns: Int, rows: Int, data: Data) {
        guard cardID == openCardID else { return }
        // The terminal shows the session at its size: take it, then replay.
        awaiting = (columns, rows)
        queued = [data]
        terminal.useRemoteGrid(columns: columns, rows: rows)
        if let g = terminalGrid, g == (columns, rows) {
            flush()
        } else {
            awaitingTimeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            awaitingTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func remoteOutput(cardID: String, data: Data) {
        guard cardID == openCardID else { return }
        if awaiting != nil {
            queued.append(data)
        } else {
            terminal.feed(data)
        }
    }

    func remoteTerminalClosed(cardID: String) {
        guard cardID == openCardID else { return }
        openCardID = nil
        awaiting = nil
        queued = []
    }

    private func terminalResized(_ columns: Int, _ rows: Int) {
        terminalGrid = (columns, rows)
        if let a = awaiting, a == (columns, rows) { flush() }
    }

    private func flush() {
        guard awaiting != nil else { return }
        awaitingTimeout?.cancel()
        awaiting = nil
        let data = queued
        queued = []
        for d in data { terminal.feed(d) }
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

    /// The project new sessions go to from the menu: the open card's, else the first.
    var currentProject: Remote.Project? {
        card(openCardID).flatMap { project($0.projectID) } ?? state.projects.first
    }

    func kindsDefaultFirst(_ project: Remote.Project) -> [Remote.AgentKind] {
        let first: Remote.AgentKind = project.defaultKind == .codex ? .codex : .claude
        return [first, first == .claude ? .codex : .claude]
    }

    func newSession(in project: Remote.Project, kind: Remote.AgentKind?) {
        let operation = UUID().uuidString
        Task { @MainActor in
            do {
                let cardID = try await retrying { try await self.client.newSession(projectID: project.id, kind: kind, operationID: operation) }
                self.openWhenKnown(cardID)
            } catch {
                self.show(error)
            }
        }
    }

    func resume(_ entry: Remote.HistoryEntry, in project: Remote.Project) {
        Task { @MainActor in
            do {
                let cardID = try await retrying { try await self.client.resumeSession(projectID: project.id, entry: entry) }
                self.openWhenKnown(cardID)
            } catch {
                self.show(error)
            }
        }
    }

    /// Closes a card on the computer, asking first when its program still
    /// runs (as the computer's own window does).
    func close(_ card: Remote.Card) {
        var confirmed = false
        if card.running && state.confirmClose {
            let alert = NSAlert()
            alert.messageText = String(localized: "Close “\(card.title)”?")
            let name = card.kind == .codex ? "Codex" : "Claude"
            alert.informativeText = String(localized: "\(name) is still running on the remote computer. Closing will end it. The history is kept and can be resumed later.")
            alert.addButton(withTitle: String(localized: "Close"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            confirmed = true
        }
        Task { @MainActor in
            do {
                try await client.closeSession(cardID: card.id, confirmed: confirmed)
                if openCardID == card.id { remoteTerminalClosed(cardID: card.id) }
            } catch {
                show(error)
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
        if let card = card(cardID) {
            open(card)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openWhenKnown(cardID, attempts: attempts - 1) }
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't do that on the remote computer")
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func selectCard(at index: Int) {
        let ordered = state.cards
        guard ordered.indices.contains(index) else { return }
        open(ordered[index])
    }

    func gotoCard(_ target: GhosttyGotoTab) {
        let ordered = state.cards
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == openCardID } ?? 0
        switch target {
        case .previous: selectCard(at: (current - 1 + ordered.count) % ordered.count)
        case .next: selectCard(at: (current + 1) % ordered.count)
        case .last: selectCard(at: ordered.count - 1)
        case .index(let i): selectCard(at: min(max(i - 1, 0), ordered.count - 1))
        }
    }

    // MARK: - Notifications

    private func notify(_ n: Remote.Notification) {
        // Not while you're looking at that card.
        if n.cardID == openCardID && NSApp.isActive && window?.isKeyWindow == true { return }
        let content = UNMutableNotificationContent()
        let card = card(n.cardID)
        content.title = card?.title ?? n.title
        content.subtitle = [client.serverName, card.flatMap { project($0.projectID)?.name }]
            .compactMap { $0?.nonEmpty }.joined(separator: " · ")
        content.body = n.body.isEmpty ? n.title : n.body
        content.userInfo = ["remoteWindow": id, "remoteCard": n.cardID]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Views

struct RemoteRootView: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        HStack(spacing: 0) {
            RemoteSidebar(model: model)
                .frame(width: 300)
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            VStack(spacing: 0) {
                RemoteTitleStrip(model: model)
                ZStack {
                    AppStore.shared.terminalBackground
                    if model.openCardID != nil {
                        RemoteTerminalHost(model: model)
                    } else {
                        Text(model.state.cards.isEmpty ? "Start a session from the sidebar." : "Choose a session in the sidebar.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    if model.client.status != .connected {
                        RemoteStatusOverlay(model: model)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

private struct RemoteTerminalHost: NSViewRepresentable {
    let model: RemoteModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let t = model.terminal
        t.autoresizingMask = [.width, .height]
        t.frame = container.bounds
        container.addSubview(t)
        t.setVisible(true)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Shown over the terminal while not connected.
private struct RemoteStatusOverlay: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.client.status {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .reconnecting:
                ProgressView().controlSize(.small)
                Text("Connection lost. Reconnecting…")
            case .replaced:
                Image(systemName: "iphone.and.arrow.forward").font(.system(size: 28))
                Text("Connected on another device")
                Button("Connect Here") { model.client.connect() }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Try Again") { model.client.connect() }
            case .closed:
                Text("Disconnected")
                Button("Connect") { model.client.connect() }
            case .connected:
                EmptyView()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
    }
}

private struct RemoteTitleStrip: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        ZStack {
            WindowDragArea()
            if let card = model.card(model.openCardID) {
                HStack(spacing: 6) {
                    if let p = model.project(card.projectID) {
                        Text(p.name).foregroundStyle(.tertiary)
                        Text("/").foregroundStyle(.quaternary)
                    }
                    Text(card.title).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
            }
        }
        .frame(height: TitleStrip.height)
        .background(AppStore.shared.terminalBackground)
    }
}

private struct RemoteSidebar: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // traffic lights
                .background(WindowDragArea())
            RemoteBadge(model: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            Text("Projects")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.state.projects, id: \.id) { project in
                        RemoteProjectSection(model: model, project: project)
                    }
                    if model.client.hasState && model.state.projects.isEmpty {
                        Text("No projects on that computer yet. Add them there.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color(red: 0.118, green: 0.118, blue: 0.125))
    }
}

/// Which computer this window controls, so it isn't mistaken for this one.
private struct RemoteBadge: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.95))
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.95))
                Text(model.client.serverName.isEmpty ? model.client.url.host ?? "" : model.client.serverName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(model.client.status == .connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .help(model.client.status == .connected ? String(localized: "Connected") : String(localized: "Not connected"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.35, green: 0.78, blue: 0.95).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(red: 0.35, green: 0.78, blue: 0.95).opacity(0.30), lineWidth: 1))
        .help(model.client.url.absoluteString)
    }
}

private struct RemoteProjectSection: View {
    @ObservedObject var model: RemoteModel
    let project: Remote.Project
    @State private var hover = false

    private var expanded: Bool { !model.collapsed.contains(project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "folder" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UUID(uuidString: project.id).map(ProjectPalette.color(for:)) ?? .secondary)
                    .frame(width: 18)
                Text(project.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hover {
                    IconMenu(systemName: "square.and.pencil") {
                        ForEach(model.kindsDefaultFirst(project), id: \.self) { kind in
                            Button(kind == .codex ? "New Codex Session" : "New Claude Session") {
                                model.newSession(in: project, kind: kind)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture {
                if expanded { model.collapsed.insert(project.id) } else { model.collapsed.remove(project.id) }
            }
            .help(project.path)

            if expanded {
                let cards = model.cards(of: project)
                let history = model.history(of: project)
                let limit = model.historyLimit(project)
                ForEach(cards, id: \.id) { card in
                    RemoteCardView(model: model, card: card)
                }
                .padding(.leading, 6)
                if !history.sessions.isEmpty {
                    if !cards.isEmpty {
                        Text("Past Sessions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                            .padding(.top, 4)
                    }
                    ForEach(history.sessions.prefix(limit), id: \.sessionID) { entry in
                        RemoteHistoryRow(model: model, project: project, entry: entry)
                    }
                    if history.sessions.count > limit || history.more {
                        Button { model.showMoreHistory(project) } label: {
                            Text("Show More")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 16)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if cards.isEmpty {
                    Button { model.newSession(in: project, kind: nil) } label: {
                        Label("New Session", systemImage: "plus")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, expanded ? 10 : 0)
    }
}

extension Remote.AgentKind {
    var local: AgentKind { self == .codex ? .codex : .claude }
}

extension Remote.SessionStatus {
    var local: SessionStatus {
        switch self {
        case .dormant: return .dormant
        case .working: return .working
        case .idle: return .idle
        case .needsInput: return .needsInput
        case .exited: return .exited
        default: return .starting
        }
    }
}

private struct RemoteCardView: View {
    @ObservedObject var model: RemoteModel
    let card: Remote.Card
    @State private var hover = false

    private var selected: Bool { model.openCardID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusIndicator(status: card.status.local, attention: false, kind: card.kind.local)
                AgentIcon(kind: card.kind.local, size: 11)
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Button { model.close(card) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
                .help("Close")
            }
            .frame(height: 18)
            infoLine("arrow.triangle.branch", card.branch.nonEmpty, placeholder: String(localized: "No branch info"))
            infoLine("square.stack.3d.up", card.worktree.nonEmpty,
                     placeholder: card.branch.isEmpty ? "—" : String(localized: "Main worktree"))
            infoLine("arrow.triangle.pull", card.prNumber > 0 ? "#\(card.prNumber)" : nil, placeholder: String(localized: "No PR"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color.white.opacity(0.11) : Color.white.opacity(hover ? 0.06 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.white.opacity(selected ? 0.16 : 0.05), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hover = $0 }
        .onTapGesture { model.open(card) }
        .help(card.title)
    }

    private func infoLine(_ icon: String, _ text: String?, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(text == nil ? Color.secondary.opacity(0.5) : .secondary)
                .frame(width: 13)
            Text(text ?? placeholder)
                .font(.system(size: 11.5, design: text == nil ? .default : .monospaced))
                .foregroundStyle(text == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 15)
    }
}

private struct RemoteHistoryRow: View {
    @ObservedObject var model: RemoteModel
    let project: Remote.Project
    let entry: Remote.HistoryEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(kind: entry.kind.local, size: 11)
                .opacity(0.7)
                .frame(width: 14)
            Text(entry.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(RelativeTime.short(Date(timeIntervalSince1970: Double(entry.modifiedMs) / 1000)))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 27)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.resume(entry, in: project) }
        .help("Resume \(entry.kind.local.name) session: \(entry.title)")
    }
}
