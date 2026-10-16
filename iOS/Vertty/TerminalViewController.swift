import GameController
import GhosttyKit
import GhosttyTerminal
import SwiftUI
import UIKit
import VerttyRemote
import VerttyUI

/// The iOS terminal of a card (RemoteStore does the rest, as on the Mac):
/// the vendored libghostty-spm terminal view, fed by the connection, over
/// the input bar. The session runs on the computer at one grid size at a
/// time; the view is laid out at the session's grid and scaled down when it
/// doesn't fit.
final class TerminalViewController: UIViewController, TerminalSurfaceGridResizeDelegate, RemoteTerminalDisplay,
    UIGestureRecognizerDelegate
{
    /// Ghostty's window padding, in points (see the controller's config).
    static let padding: CGFloat = 4
    /// The one on screen, for the debug driver.
    private(set) static weak var current: TerminalViewController?

    let cardID: UUID
    private let store: RemoteStore
    private let terminal = RemoteTerminalView(frame: .zero)
    private let container = LayoutView()
    private lazy var bar = TerminalInputBar(terminal: terminal)
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
        // The bar rides on the keyboard, or sits at the bottom without it.
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(mirror))
        terminal.controller = Self.controller
        terminal.delegate = self
        // The keys are on the bar, so the keyboard carries none of its own.
        terminal.inputAccessoryItems = []
        terminal.onWillInput = { [weak self] in self?.store.willInput() }
        terminal.onTap = { [weak self] in self?.terminalTapped() ?? false }
        container.addSubview(terminal)

        bar.keyboardIsUp = { [weak self] in self?.keyboardIsUp ?? false }
        bar.hideKeyboard = { [weak self] in self?.hideKeyboard() }
        // A drag on the terminal scrolls it; carried on down onto the bar,
        // it puts the keyboard away.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        drag.delegate = self
        container.addGestureRecognizer(drag)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.current = self
        // With a hardware keyboard nothing covers the screen, so the terminal
        // always takes the typing.
        if Self.hasHardwareKeyboard {
            terminal.acquireProgrammaticFocus()
        } else if store.opensWithKeyboard(cardID) {
            bar.focus()
        }
        attachIfReady()
    }

    // MARK: - Keyboard

    /// A hardware keyboard types into the terminal directly; the software
    /// one types into the bar's field.
    private static var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    private var keyboardIsUp: Bool {
        bar.composer.isFirstResponder || (terminal.isFirstResponder && !Self.hasHardwareKeyboard)
    }

    private func hideKeyboard() {
        bar.composer.resignFirstResponder()
        if terminal.isFirstResponder, !Self.hasHardwareKeyboard { terminal.resignFirstResponder() }
    }

    /// A tap on the terminal is only its click, for the program (an option,
    /// Claude Code's "Jump to bottom"): the bar's keyboard key brings the
    /// keyboard up and puts it away. False leaves the tap to the terminal,
    /// which takes a hardware keyboard's focus.
    private func terminalTapped() -> Bool {
        !Self.hasHardwareKeyboard
    }

    @objc private func dragged(_ drag: UIPanGestureRecognizer) {
        guard drag.state == .changed, keyboardIsUp, drag.velocity(in: view).y > 0,
              drag.location(in: view).y >= bar.visibleTop(in: view) else { return }
        hideKeyboard()
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
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

    /// The terminal has this grid now (Ghostty reports it once resized, so
    /// output fed from here on lands at it).
    private func terminalResized(_ viewport: InMemoryTerminalViewport) {
        reported = viewport
        store.terminalGridApplied(Remote.TerminalSize(columns: Int(viewport.columns), rows: Int(viewport.rows)))
    }

    // MARK: - Debug

    var debugSummary: String {
        let r = reported.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let g = sessionGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
        let o = ownSize.map { "\($0.columns)x\($0.rows)" } ?? "-"
        return "terminal reported=\(r) session=\(g) own=\(o) scale=\(String(format: "%.2f", terminal.transform.a)) keyboard=\(bar.composer.isFirstResponder || terminal.isFirstResponder) bar=\(bar.mode) config=\(Self.controller.lastConfigurationIssue == nil ? "ok" : "error")\ncomposer|\(bar.composer.text ?? "")"
    }

    var visibleText: String { mirror.readViewportText() ?? "" }

    /// Typing on the software keyboard, Return included: into the bar's field.
    func debugType(_ text: String) {
        for ch in text { bar.composer.insertText(String(ch)) }
    }

    /// An IME composition in the field, not committed yet.
    func debugMark(_ text: String) {
        bar.composer.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    func debugBackspace() { bar.composer.deleteBackward() }
    func debugSend() { bar.send() }
    /// A key on the bar, by its label.
    func debugPress(_ label: String) { bar.debugPress(label) }
    /// A tap in the middle of the terminal without a hardware keyboard: only
    /// its click.
    func debugTap() {
        terminal.sendMousePos(x: terminal.bounds.midX, y: terminal.bounds.midY)
        terminal.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        terminal.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }
    /// What a swipe down onto the bar does without a hardware keyboard (the
    /// simulator has the Mac's); it also puts away the terminal's focus a
    /// hardware keyboard gave it.
    func debugHideKeyboard() {
        bar.composer.resignFirstResponder()
        terminal.resignFirstResponder()
    }
    /// Holding the space bar and sliding this many cells (negative: left).
    func debugSlide(_ cells: Int) {
        guard let cell else { return }
        let width = cell.width / traitCollection.displayScale
        bar.composer.beginFloatingCursor(at: .zero)
        bar.composer.updateFloatingCursor(at: CGPoint(x: (CGFloat(cells) + 0.5 * CGFloat(cells.signum())) * width, y: 0))
        bar.composer.endFloatingCursor()
    }
}

/// The terminal, with what a tap does to the keyboard up to its owner.
private final class RemoteTerminalView: UITerminalView {
    /// After a tap's click; false leaves the keyboard to the terminal.
    var onTap: (() -> Bool)?

    override func toggleSoftwareKeyboard() {
        if onTap?() != true { super.toggleSoftwareKeyboard() }
    }
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
