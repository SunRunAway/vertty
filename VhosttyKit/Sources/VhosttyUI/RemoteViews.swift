import SwiftUI
import VhosttyRemote

/// Another computer's sessions: the shared sidebar and the selected card's
/// terminal. Side by side on the Mac and iPad; on the iPhone the sidebar is
/// a screen of its own and a card's terminal opens over it.
public struct RemoteWorkspace<Terminal: View>: View {
    @ObservedObject var store: RemoteStore
    let terminal: (UUID) -> Terminal
    let onDisconnect: (() -> Void)?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// `terminal` shows the card with that id; `onDisconnect` adds a button
    /// that ends the connection (where closing a window doesn't).
    public init(store: RemoteStore, onDisconnect: (() -> Void)? = nil, @ViewBuilder terminal: @escaping (UUID) -> Terminal) {
        self.store = store
        self.terminal = terminal
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact {
                compact
            } else {
                regular
            }
            #else
            regular
            #endif
        }
        .preferredColorScheme(.dark)
        .alert(Text("Close “\(store.confirmingClose?.title ?? "")”?", bundle: .vhosttyUIResources),
               isPresented: Binding(get: { store.confirmingClose != nil }, set: { if !$0 { store.confirmingClose = nil } }),
               presenting: store.confirmingClose) { card in
            Button(role: .destructive) { store.close(card, confirmed: true) } label: { Text("Close", bundle: .vhosttyUIResources) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .vhosttyUIResources) }
        } message: { card in
            Text("\(card.kind.name) is still running on the computer. Closing will end it. The history is kept and can be resumed later.", bundle: .vhosttyUIResources)
        }
        .alert(Text("Couldn't do that on the computer", bundle: .vhosttyUIResources),
               isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button(role: .cancel) {} label: { Text("OK", bundle: .vhosttyUIResources) }
        } message: {
            Text(store.failure ?? "")
        }
    }

    private var regular: some View {
        Workspace(layout: store) {
            SidebarView(store: store) {
                SidebarTopBar(layout: store)
                RemoteBadge(store: store, onDisconnect: onDisconnect)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
            }
        } strip: {
            TitleStrip(layout: store, background: store.terminalBackground) {
                if let card = store.selectedCard {
                    TitleStripLabel(card: card, project: store.project(card.projectID))
                }
            } trailing: {
                EmptyView()
            }
        } detail: {
            ZStack {
                store.terminalBackground.ignoresSafeArea()
                if let id = store.selectedCardID {
                    terminal(id)
                } else {
                    Text(store.allCards.isEmpty ? "Start a session from the sidebar." : "Choose a session in the sidebar.", bundle: .vhosttyUIResources)
                        .font(.ui(13))
                        .foregroundStyle(.tertiary)
                }
                if store.client.status != .connected {
                    RemoteStatusOverlay(store: store, onDisconnect: onDisconnect)
                }
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    #if os(iOS)
    private var compact: some View {
        NavigationStack(path: Binding(
            get: { store.selectedCardID.map { [$0] } ?? [] },
            set: { store.selectedCardID = $0.last }
        )) {
            SidebarView(store: store) {
                RemoteBadge(store: store, onDisconnect: onDisconnect)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                ZStack {
                    store.terminalBackground.ignoresSafeArea()
                    terminal(id)
                }
                .navigationTitle(store.card(id)?.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(store.terminalBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        .overlay {
            if store.client.status != .connected {
                RemoteStatusOverlay(store: store, onDisconnect: onDisconnect)
            }
        }
    }
    #endif
}

/// Which computer this is, so it isn't mistaken for this one.
public struct RemoteBadge: View {
    @ObservedObject var store: RemoteStore
    let onDisconnect: (() -> Void)?

    public init(store: RemoteStore, onDisconnect: (() -> Void)? = nil) {
        self.store = store
        self.onDisconnect = onDisconnect
    }

    private static let tint = Color(red: 0.35, green: 0.78, blue: 0.95)

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.ui(13))
                .foregroundStyle(Self.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote", bundle: .vhosttyUIResources)
                    .font(.ui(10.5, weight: .semibold))
                    .foregroundStyle(Self.tint)
                Text(store.serverName)
                    .font(.ui(13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(store.client.status == .connected ? Color.green : Color.orange)
                .frame(width: Touch.size(7), height: Touch.size(7))
                .help(store.client.status == .connected ? Text("Connected", bundle: .vhosttyUIResources) : Text("Not connected", bundle: .vhosttyUIResources))
            if let onDisconnect {
                IconButton(systemName: "power", help: Text("Disconnect", bundle: .vhosttyUIResources), action: onDisconnect)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Self.tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Self.tint.opacity(0.30), lineWidth: 1))
        .help(store.client.url.absoluteString)
    }
}

/// Shown over the terminal while not connected.
public struct RemoteStatusOverlay: View {
    @ObservedObject var store: RemoteStore
    let onDisconnect: (() -> Void)?

    public init(store: RemoteStore, onDisconnect: (() -> Void)? = nil) {
        self.store = store
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        VStack(spacing: 14) {
            switch store.client.status {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…", bundle: .vhosttyUIResources)
            case .reconnecting:
                ProgressView().controlSize(.small)
                Text("Connection lost. Reconnecting…", bundle: .vhosttyUIResources)
            case .replaced:
                Image(systemName: "iphone.and.arrow.forward").font(.ui(28))
                Text("Connected on another device", bundle: .vhosttyUIResources)
                Button { store.client.connect() } label: { Text("Connect Here", bundle: .vhosttyUIResources) }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.ui(28))
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    if let onDisconnect {
                        Button(action: onDisconnect) { Text("Change Address", bundle: .vhosttyUIResources) }
                    }
                    Button { store.client.connect() } label: { Text("Try Again", bundle: .vhosttyUIResources) }
                }
            case .closed:
                Text("Disconnected", bundle: .vhosttyUIResources)
                Button { store.client.connect() } label: { Text("Connect", bundle: .vhosttyUIResources) }
            case .connected:
                EmptyView()
            }
        }
        .font(.ui(13))
        .foregroundStyle(.secondary)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
        .padding(16)
    }
}
