import GhosttyTerminal
import SwiftUI
import UIKit
import VhosttyRemote

/// The terminal of an open card. The session runs on the computer at one
/// grid size at a time: the iPhone's while it was the last to enter, resize
/// or type, else the computer's. The terminal view is laid out at that grid
/// and scaled down when it doesn't fit the screen.
final class TerminalViewController: UIViewController, TerminalSurfaceGridResizeDelegate {
    /// Ghostty's window padding, in points (see the controller's config).
    static let padding: CGFloat = 4

    let cardID: String
    private let session: RemoteSession
    private let terminal = UITerminalView(frame: .zero)
    private let container = LayoutView()
    private let controller = TerminalController { config in
        config.withWindowPaddingX(Int(TerminalViewController.padding))
        config.withWindowPaddingY(Int(TerminalViewController.padding))
        config.withCustom("window-padding-balance", "false")
    }
    private lazy var mirror = InMemoryTerminalSession(
        write: { [weak self] data in
            DispatchQueue.main.async { self?.session.client.input(data) }
        },
        resize: { [weak self] viewport in
            DispatchQueue.main.async { self?.terminalResized(viewport) }
        })

    /// The grid the terminal has now, as its IO thread reported it.
    private var reported: InMemoryTerminalViewport?
    /// The cell size in pixels.
    private var cell: (width: CGFloat, height: CGFloat)?
    /// The session's grid on the computer, from the last snapshot.
    private var sessionGrid: Remote.TerminalSize?
    /// A snapshot waiting for the terminal to take its size, with the
    /// output that came after it.
    private var awaiting: Remote.TerminalSize?
    private var queued: [Data] = []
    private var awaitingTimeout: DispatchWorkItem?
    private var opened = false
    /// The size last sent as the viewport.
    private var sentSize: Remote.TerminalSize?

    init(cardID: String, session: RemoteSession) {
        self.cardID = cardID
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        container.clipsToBounds = true
        container.onLayout = { [weak self] in self?.containerResized() }
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(mirror))
        terminal.controller = controller
        terminal.delegate = self
        terminal.inputAccessoryItems = [.esc, .tab, .shiftTab, .ctrlC, .divider, .arrowLeft, .arrowDown, .arrowUp, .arrowRight]
        terminal.onWillInput = { [weak self] in
            guard let self, let own = self.ownSize else { return }
            self.sentSize = own
            self.session.client.alignForInput(own)
        }
        container.addSubview(terminal)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.terminal = self
        terminal.acquireProgrammaticFocus()
        openIfReady()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.terminal === self { session.terminal = nil }
    }

    // MARK: - Size

    /// The grid that fits the screen, once the cell size is known.
    var ownSize: Remote.TerminalSize? {
        guard let cell else { return nil }
        let scale = traitCollection.displayScale
        let cols = Int((container.bounds.width * scale - paddingPixels * 2) / cell.width)
        let rows = Int((container.bounds.height * scale - paddingPixels * 2) / cell.height)
        guard cols > 0, rows > 0 else { return nil }
        return Remote.TerminalSize(columns: cols, rows: rows)
    }

    /// Ghostty's padding in pixels: points at 96 dpi off the Mac.
    private var paddingPixels: CGFloat {
        (Self.padding * traitCollection.displayScale * 96 / 72).rounded(.down)
    }

    /// Sends the screen's size as the viewport (it changed, or the app came
    /// back to the foreground).
    func reportViewport() {
        guard opened, let own = ownSize else { return }
        sentSize = own
        session.client.viewportChanged(own)
    }

    private func containerResized() {
        layoutTerminal()
        guard opened, let own = ownSize, own != sentSize else { return }
        reportViewport()
    }

    private func openIfReady() {
        guard !opened, session.terminal === self, let own = ownSize else { return }
        opened = true
        sentSize = own
        session.client.openTerminal(cardID: cardID, size: own)
    }

    /// Lays the terminal out at the session's grid, scaled down to fit.
    private func layoutTerminal() {
        let bounds = container.bounds
        terminal.transform = .identity
        guard let grid = sessionGrid, grid != ownSize, let cell else {
            terminal.frame = bounds
            return
        }
        let scale = traitCollection.displayScale
        // Half a cell spare, so rounding never costs a column or row.
        let width = ((CGFloat(grid.columns) + 0.5) * cell.width + paddingPixels * 2) / scale
        let height = ((CGFloat(grid.rows) + 0.5) * cell.height + paddingPixels * 2) / scale
        let fit = min(1, bounds.width / width, bounds.height / height)
        terminal.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        terminal.transform = CGAffineTransform(scaleX: fit, y: fit)
        terminal.center = CGPoint(x: width * fit / 2, y: height * fit / 2)
    }

    /// The view's metrics changed (UI side): the cell size.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard size.cellWidthPixels > 0, size.cellHeightPixels > 0 else { return }
        let first = cell == nil
        cell = (CGFloat(size.cellWidthPixels), CGFloat(size.cellHeightPixels))
        if first {
            layoutTerminal()
            openIfReady()
        }
    }

    private func terminalResized(_ viewport: InMemoryTerminalViewport) {
        reported = viewport
        guard let a = awaiting, a.columns == Int(viewport.columns), a.rows == Int(viewport.rows) else { return }
        // Ghostty reports the size just before its IO thread resizes the
        // terminal; output fed before then would land at the old size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
    }

    // MARK: - Stream

    func showSnapshot(columns: Int, rows: Int, data: Data) {
        let grid = Remote.TerminalSize(columns: columns, rows: rows)
        sessionGrid = grid
        awaiting = grid
        queued = [data]
        layoutTerminal()
        if let r = reported, Int(r.columns) == columns, Int(r.rows) == rows {
            flush()
            return
        }
        awaitingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        awaitingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func showOutput(_ data: Data) {
        if awaiting != nil {
            queued.append(data)
        } else {
            mirror.receive(data)
        }
    }

    private func flush() {
        guard awaiting != nil else { return }
        awaitingTimeout?.cancel()
        awaiting = nil
        let data = queued
        queued = []
        for d in data { mirror.receive(d) }
    }

    // MARK: - Debug

    var debugSummary: String {
        let r = reported.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let g = sessionGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let o = ownSize.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let px = reported.map { "\($0.widthPixels)x\($0.heightPixels)" } ?? "-"
        let c = cell.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return "terminal reported=\(r) session=\(g) own=\(o) scale=\(String(format: "%.2f", terminal.transform.a)) px=\(px) cell=\(c) box=\(container.bounds.size) display=\(traitCollection.displayScale)"
    }

    var visibleText: String { mirror.readViewportText() ?? "" }

    func debugType(_ text: String) {
        for ch in text {
            if let press = TerminalKeyPress(typing: ch) {
                terminal.sendKey(press)
            } else {
                terminal.insertText(String(ch))
            }
        }
    }

    func debugInsert(_ text: String) { terminal.insertText(text) }
    func debugKey(_ key: TerminalKey, modifiers: TerminalInputModifiers = []) { terminal.sendKey(key, modifiers: modifiers) }
}

/// Tells its owner when it's laid out.
private final class LayoutView: UIView {
    var onLayout: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onLayout?()
    }
}

/// The terminal screen of a card, for SwiftUI.
struct TerminalScreen: UIViewControllerRepresentable {
    let cardID: String
    let session: RemoteSession

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(cardID: cardID, session: session)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}
}
