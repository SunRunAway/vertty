import SwiftUI
import VhosttyRemote

struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        if let session = app.session {
            SessionsView(app: app, session: session)
        } else {
            ConnectView(app: app)
        }
    }
}

// MARK: - Connect

struct ConnectView: View {
    @ObservedObject var app: AppModel
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://192.168.1.5:58563", text: $app.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Computer")
                } footer: {
                    Text("The address shown in Remote Connection Info in Vhostty on your computer. The connection's security is up to you (for example a VPN).")
                }
                Section {
                    Button("Connect", action: connect)
                        .disabled(app.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Vhostty")
            .alert("That isn't an address Vhostty can connect to.", isPresented: $invalid) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a host and port, such as 192.168.1.5:58563 or ws://mac.local:58563.")
            }
        }
    }

    private func connect() {
        if !app.connect() { invalid = true }
    }
}

// MARK: - Sessions

struct SessionsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: RemoteSession

    var body: some View {
        NavigationStack(path: $session.path) {
            List {
                ForEach(session.state.projects, id: \.id) { project in
                    ProjectSection(session: session, project: project)
                }
                if session.client.hasState && session.state.projects.isEmpty {
                    Text("No projects on that computer yet. Add them there.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(session.client.serverName.isEmpty ? (session.client.url.host ?? "") : session.client.serverName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Disconnect") { app.disconnect() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NewSessionMenu(session: session)
                }
            }
            .navigationDestination(for: String.self) { cardID in
                TerminalPage(session: session, cardID: cardID)
            }
            .safeAreaInset(edge: .bottom) {
                if session.client.status != .connected {
                    StatusBar(app: app, session: session)
                }
            }
        }
        .alert("Couldn't do that on the computer", isPresented: Binding(
            get: { session.failure != nil },
            set: { if !$0 { session.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.failure ?? "")
        }
    }
}

private struct NewSessionMenu: View {
    @ObservedObject var session: RemoteSession

    var body: some View {
        Menu {
            ForEach(session.state.projects, id: \.id) { project in
                Section(project.name) {
                    ForEach(session.kindsDefaultFirst(project), id: \.self) { kind in
                        Button(kind == .codex ? "New Codex Session" : "New Claude Session") {
                            session.newSession(in: project, kind: kind)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .disabled(session.client.status != .connected || session.state.projects.isEmpty)
    }
}

private struct ProjectSection: View {
    @ObservedObject var session: RemoteSession
    let project: Remote.Project

    var body: some View {
        let cards = session.cards(of: project)
        let history = session.history(of: project)
        let limit = session.historyLimit(project)
        Section {
            ForEach(cards, id: \.id) { card in
                CardRow(session: session, card: card)
            }
            if cards.isEmpty {
                Button { session.newSession(in: project, kind: nil) } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
            if !history.sessions.isEmpty {
                ForEach(history.sessions.prefix(limit), id: \.sessionID) { entry in
                    HistoryRow(entry: entry) { session.resume(entry, in: project) }
                }
                if history.sessions.count > limit || history.more {
                    Button("Show More") { session.showMoreHistory(project) }
                        .font(.subheadline)
                }
            }
        } header: {
            Text(project.name)
        }
    }
}

private struct CardRow: View {
    @ObservedObject var session: RemoteSession
    let card: Remote.Card
    @State private var confirming = false

    var body: some View {
        Button { session.open(card.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    StatusDot(status: card.status)
                    Text(card.kind == .codex ? "Codex" : "Claude")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(card.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                infoLine("arrow.triangle.branch", card.branch.isEmpty ? nil : card.branch,
                         placeholder: String(localized: "No branch info"))
                infoLine("square.stack.3d.up", card.worktree.isEmpty ? nil : card.worktree,
                         placeholder: card.branch.isEmpty ? "—" : String(localized: "Main worktree"))
                infoLine("arrow.triangle.pull", card.prNumber > 0 ? "#\(card.prNumber)" : nil,
                         placeholder: String(localized: "No PR"))
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Close", role: .destructive) {
                if session.needsConfirmation(card) {
                    confirming = true
                } else {
                    session.close(card, confirmed: false)
                }
            }
        }
        .confirmationDialog("Close “\(card.title)”?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Close", role: .destructive) { session.close(card, confirmed: true) }
        } message: {
            Text("\(card.kind == .codex ? "Codex" : "Claude") is still running on the computer. Closing will end it. The history is kept and can be resumed later.")
        }
    }

    private func infoLine(_ icon: String, _ text: String?, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .frame(width: 14)
            Text(text ?? placeholder)
                .font(text == nil ? .caption : .caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(text == nil ? .tertiary : .secondary)
    }
}

private struct StatusDot: View {
    let status: Remote.SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .working: return .blue
        case .needsInput: return .orange
        case .idle: return .green
        default: return .gray
        }
    }
}

private struct HistoryRow: View {
    let entry: Remote.HistoryEntry
    let resume: () -> Void

    var body: some View {
        Button(action: resume) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Date(timeIntervalSince1970: Double(entry.modifiedMs) / 1000), style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Resume \(entry.kind == .codex ? "Codex" : "Claude") session: \(entry.title)"))
    }
}

/// The connection's state while it isn't connected.
private struct StatusBar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: RemoteSession

    var body: some View {
        VStack(spacing: 10) {
            switch session.client.status {
            case .connecting:
                ProgressView("Connecting…")
            case .reconnecting:
                ProgressView("Connection lost. Reconnecting…")
            case .replaced:
                Text("Connected on another device")
                Button("Connect Here") { session.client.connect() }
                    .buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message).multilineTextAlignment(.center)
                HStack {
                    Button("Change Address") { app.disconnect() }
                    Button("Try Again") { session.client.connect() }
                        .buttonStyle(.borderedProminent)
                }
            case .closed:
                Text("Disconnected")
                Button("Connect") { session.client.connect() }
                    .buttonStyle(.borderedProminent)
            case .connected:
                EmptyView()
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
    }
}

// MARK: - Terminal

private struct TerminalPage: View {
    @ObservedObject var session: RemoteSession
    let cardID: String

    var body: some View {
        // A terminal of its own per card: SwiftUI would otherwise reuse the
        // one on screen when the path switches cards.
        TerminalScreen(cardID: cardID, session: session)
            .id(cardID)
            .ignoresSafeArea(.keyboard)
            .navigationTitle(session.card(cardID)?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .overlay(alignment: .top) {
                if session.client.status != .connected {
                    Text(statusText)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
    }

    private var statusText: String {
        switch session.client.status {
        case .replaced: return String(localized: "Connected on another device")
        case .failed(let message): return message
        case .closed: return String(localized: "Disconnected")
        default: return String(localized: "Connection lost. Reconnecting…")
        }
    }
}
