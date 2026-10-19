import AppKit
import SwiftUI
import VerttyRemote
import VerttyTailnet

/// The desktop remote client: a window showing another computer's Vertty
/// in the shared sidebar (VerttyUI.RemoteWorkspace), with the selected
/// card's terminal. Its sessions run on that computer.
final class RemoteWindowController: NSObject, NSWindowDelegate {
    private(set) static var all: [RemoteWindowController] = []
    static let lastURLKey = "RemoteLastURL"
    private let usesTailnet: Bool

    let store: RemoteStore
    let terminal: MacRemoteTerminal
    let window: NSWindow

    /// Opens a window connected to `endpoint`.
    static func open(_ endpoint: RemoteEndpoint) {
        show(RemoteWindowController(endpoint: endpoint, tailnet: false))
    }

    /// Opens a window connected to a computer on the tailnet, keeping the
    /// Tailscale device running while it's open.
    static func open(_ computer: Tailnet.Device) {
        show(RemoteWindowController(endpoint: .tailnet(computer), tailnet: true))
    }

    private static func show(_ controller: RemoteWindowController) {
        all.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        controller.store.client.connect()
        controller.store.askForNotifications()
    }

    /// The remote window whose terminal this is, if any.
    static func owner(of surface: TerminalSurfaceView?) -> RemoteWindowController? {
        guard let surface else { return nil }
        return all.first { $0.terminal.view === surface }
    }

    /// The remote window in front, if the key window is one.
    static var key: RemoteWindowController? {
        all.first { $0.window.isKeyWindow }
    }

    static func withStore(_ id: String) -> RemoteWindowController? {
        all.first { $0.store.id == id }
    }

    private init(endpoint: RemoteEndpoint, tailnet: Bool) {
        usesTailnet = tailnet
        if tailnet { Tailnet.shared.use() }
        store = RemoteStore(endpoint: endpoint, platform: .mac, deviceName: Host.current().localizedName ?? "Mac")
        store.terminalBackground = AppStore.shared.terminalBackground
        terminal = MacRemoteTerminal(store: store)
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
        let terminal = terminal
        window.contentView = NSHostingView(rootView: RemoteWorkspace(store: store) { _ in
            RemoteTerminalHost(terminal: terminal)
        })
        window.center()
        window.setFrameAutosaveName("VerttyRemoteWindow")
        store.isViewing = { [weak self] id in
            guard let self else { return false }
            return self.store.selectedCardID == id && NSApp.isActive && self.window.isKeyWindow
        }
    }

    func windowWillClose(_ notification: Notification) {
        store.close()
        if usesTailnet { Tailnet.shared.endUse() }
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        terminal.focus()
        store.markSelectedRead()
    }
}

/// Where the Mac picks the computer to connect to: VerttyUI's
/// RemoteConnectView (Tailscale, or an address) in a window of its own.
final class RemoteConnectWindowController: NSObject, NSWindowDelegate {
    private static var shown: RemoteConnectWindowController?
    private let window: NSWindow

    static func show() {
        if let shown { return shown.window.makeKeyAndOrderFront(nil) }
        let controller = RemoteConnectWindowController()
        shown = controller
        controller.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Connect to Remote Computer")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 380, height: 360)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ConnectRoot { [weak self] pick in
            switch pick {
            case .address(let url): RemoteWindowController.open(.url(url))
            case .computer(let computer): RemoteWindowController.open(computer)
            }
            self?.window.close()
        })
        window.center()
        // The list of computers needs the Tailscale device; start it if the
        // user signed in here (signing in starts it otherwise).
        if Tailnet.shared.signedInHere { Tailnet.shared.activateClient() }
    }

    func windowWillClose(_ notification: Notification) {
        Tailnet.shared.deactivateClient()
        Self.shown = nil
    }

    enum Pick {
        case address(URL)
        case computer(Tailnet.Device)
    }

    private struct ConnectRoot: View {
        @AppStorage(RemoteWindowController.lastURLKey) private var address = ""
        let picked: (Pick) -> Void

        var body: some View {
            RemoteConnectView(address: $address,
                              connectAddress: { picked(.address($0)) },
                              connectComputer: { picked(.computer($0)) })
        }
    }
}

/// The remote window's terminal: Vertty's own terminal view, fed by the
/// connection instead of a pty (see TerminalSurfaceView.RemoteHooks).
final class MacRemoteTerminal: RemoteTerminalDisplay {
    private(set) var view: TerminalSurfaceView!
    private(set) weak var store: RemoteStore?

    init(store: RemoteStore) {
        self.store = store
        let hooks = TerminalSurfaceView.RemoteHooks(
            write: { [weak store] data in
                DispatchQueue.main.async { store?.input(data) }
            },
            resized: { [weak store] columns, rows in
                DispatchQueue.main.async { store?.terminalGridApplied(Remote.TerminalSize(columns: columns, rows: rows)) }
            },
            willInput: { [weak store] in store?.willInput() },
            displayResized: { [weak store] in store?.viewportChanged() })
        view = TerminalSurfaceView(options: .init(remote: hooks))
    }

    var ownSize: Remote.TerminalSize? {
        guard view.window != nil else { return nil }
        let g = view.naturalGrid
        return Remote.TerminalSize(columns: g.columns, rows: g.rows)
    }

    func showGrid(_ size: Remote.TerminalSize) {
        view.useRemoteGrid(columns: Int(size.columns), rows: Int(size.rows))
    }

    func feed(_ data: Data) { view.feed(data) }

    func focus() {
        guard let window = view.window else { return }
        DispatchQueue.main.async { if window.firstResponder !== self.view { window.makeFirstResponder(self.view) } }
    }
}

private struct RemoteTerminalHost: NSViewRepresentable {
    let terminal: MacRemoteTerminal

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let t = terminal.view!
        t.autoresizingMask = [.width, .height]
        t.frame = container.bounds
        container.addSubview(t)
        t.setVisible(true)
        // Once it's in the window, its size is known: open the card there.
        DispatchQueue.main.async { [terminal] in
            guard let store = terminal.store else { return }
            store.attach(terminal)
            terminal.focus()
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}

extension RemoteStore {
    /// ⇧⌘[ / ⇧⌘] and friends, as for local sessions.
    func gotoCard(_ target: GhosttyGotoTab) {
        let ordered = projects.flatMap { cards(of: $0) }
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedCardID } ?? 0
        switch target {
        case .previous: selectCard(at: (current - 1 + ordered.count) % ordered.count)
        case .next: selectCard(at: (current + 1) % ordered.count)
        case .last: selectCard(at: ordered.count - 1)
        case .index(let i): selectCard(at: min(max(i - 1, 0), ordered.count - 1))
        }
    }
}
