import AppKit
import SwiftUI
import VhosttyRemote

/// The desktop remote client: a window showing another computer's Vhostty
/// in the shared sidebar (VhosttyUI.RemoteWorkspace), with the selected
/// card's terminal. Its sessions run on that computer.
final class RemoteWindowController: NSObject, NSWindowDelegate {
    private(set) static var all: [RemoteWindowController] = []
    static let lastURLKey = "RemoteLastURL"

    let store: RemoteStore
    let terminal: MacRemoteTerminal
    let window: NSWindow

    /// Asks for the address, then opens a window connected to it.
    static func connectViaPrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect to Remote Computer")
        alert.informativeText = String(localized: "The other computer's address, with the port shown under Allow Remote Connections in its Vhostty menu. The connection's security is up to you (for example a VPN).")
        let field = NSTextField(string: UserDefaults.standard.string(forKey: lastURLKey) ?? "")
        field.placeholderString = "192.168.1.5:58563"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = remoteURL(from: field.stringValue) else {
            let bad = NSAlert()
            bad.messageText = String(localized: "That isn't an address Vhostty can connect to.")
            bad.informativeText = String(localized: "Enter a host and port, such as 192.168.1.5:58563 or mac.local:58563.")
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

    private init(url: URL) {
        store = RemoteStore(url: url, platform: .mac, deviceName: Host.current().localizedName ?? "Mac")
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
        window.setFrameAutosaveName("VhosttyRemoteWindow")
        store.isViewing = { [weak self] id in
            guard let self else { return false }
            return self.store.selectedCardID == id && NSApp.isActive && self.window.isKeyWindow
        }
    }

    func windowWillClose(_ notification: Notification) {
        store.close()
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        terminal.focus()
    }
}

/// The remote window's terminal: Vhostty's own terminal view, fed by the
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
