import GameController
import GhosttyTerminal
import SwiftUI
import UIKit
import VhosttyRemote
import VhosttyUI

/// The iOS terminal of a card (RemoteStore does the rest, as on the Mac):
/// libghostty-spm's terminal view, fed by the connection. The session runs
/// on the computer at one grid size at a time; libghostty-spm can't set a
/// grid, so the view is laid out at the session's grid and scaled down when
/// it doesn't fit.
final class TerminalViewController: UIViewController, TerminalSurfaceGridResizeDelegate, RemoteTerminalDisplay {
    /// Ghostty's window padding, in points (see the controller's config).
    static let padding: CGFloat = 4
    /// The one on screen, for the debug driver.
    private(set) static weak var current: TerminalViewController?

    let cardID: UUID
    private let store: RemoteStore
    private let terminal = UITerminalView(frame: .zero)
    private let container = LayoutView()
    /// Ghostty's own colors, as on the computer (no libghostty-spm theme).
    private static let controller = TerminalController(theme: TerminalTheme()) { config in
        config.withWindowPaddingX(Int(TerminalViewController.padding))
        config.withWindowPaddingY(Int(TerminalViewController.padding))
        config.withCustom("window-padding-balance", "false")
    }
    static var background: Color {
        let c = controller.backgroundColor
        return Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }
    private lazy var mirror = InMemoryTerminalSession(
        write: { [weak self] data in
            DispatchQueue.main.async { self?.store.input(data) }
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

    init(cardID: UUID, store: RemoteStore) {
        self.cardID = cardID
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
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
        terminal.controller = Self.controller
        terminal.delegate = self
        terminal.inputAccessoryItems = [.esc, .tab, .shiftTab, .ctrlC, .divider, .arrowLeft, .arrowDown, .arrowUp, .arrowRight]
        terminal.inputAccessoryShowsDismissKey = true
        terminal.onWillInput = { [weak self] in self?.store.willInput() }
        container.addSubview(terminal)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.current = self
        // With a hardware keyboard nothing covers the screen, so the terminal
        // always takes the typing.
        if GCKeyboard.coalesced != nil || store.opensWithKeyboard(cardID) {
            terminal.acquireProgrammaticFocus()
        }
        attachIfReady()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        store.detach(self)
    }

    private func attachIfReady() {
        guard view.window != nil, ownSize != nil else { return }
        store.attach(self)
    }

    // MARK: - RemoteTerminalDisplay

    /// The grid that fits the screen, once the cell size is known.
    var ownSize: Remote.TerminalSize? {
        guard let cell else { return nil }
        let scale = traitCollection.displayScale
        let cols = Int((container.bounds.width * scale - paddingPixels * 2) / cell.width)
        let rows = Int((container.bounds.height * scale - paddingPixels * 2) / cell.height)
        guard cols > 0, rows > 0 else { return nil }
        return Remote.TerminalSize(columns: cols, rows: rows)
    }

    func showGrid(_ size: Remote.TerminalSize) {
        sessionGrid = size
        layoutTerminal()
    }

    func feed(_ data: Data) { mirror.receive(data) }

    // MARK: - Size

    /// Ghostty's padding in pixels: points at 96 dpi off the Mac.
    private var paddingPixels: CGFloat {
        (Self.padding * traitCollection.displayScale * 96 / 72).rounded(.down)
    }

    private func containerResized() {
        layoutTerminal()
        store.viewportChanged()
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
            attachIfReady()
        }
    }

    private func terminalResized(_ viewport: InMemoryTerminalViewport) {
        reported = viewport
        // libghostty-spm reports the size just before its IO thread resizes
        // the terminal; output fed before then would land at the old size.
        let size = Remote.TerminalSize(columns: Int(viewport.columns), rows: Int(viewport.rows))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.reported.map({ Int($0.columns) == size.columns && Int($0.rows) == size.rows }) == true else { return }
            self.store.terminalGridApplied(size)
        }
    }

    // MARK: - Debug

    var debugSummary: String {
        let r = reported.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let g = sessionGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let o = ownSize.map { "\($0.columns)x\($0.rows)" } ?? "-"
        return "terminal reported=\(r) session=\(g) own=\(o) scale=\(String(format: "%.2f", terminal.transform.a)) keyboard=\(terminal.isFirstResponder)"
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
    /// What a tap on the terminal does to the keyboard.
    func debugFocus() { terminal.acquireProgrammaticFocus() }
    /// What the bar's hide-keyboard key does.
    func debugHideKeyboard() { terminal.resignFirstResponder() }
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

/// The terminal of a card, for SwiftUI.
struct TerminalScreen: UIViewControllerRepresentable {
    let cardID: UUID
    let store: RemoteStore

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(cardID: cardID, store: store)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}
}
