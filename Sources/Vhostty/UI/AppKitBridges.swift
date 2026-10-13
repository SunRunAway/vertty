import AppKit
import SwiftUI

/// Hosts the selected session: Claude's terminal on top and, when open, the
/// session's shell panel below a draggable divider. Surfaces are owned by their
/// sessions and simply swapped in and out of this view.
final class TerminalContainerView: NSView {
    private(set) weak var current: TerminalSurfaceView?
    private(set) weak var currentShell: TerminalSurfaceView?
    private weak var tab: TabSession?

    /// Fraction of the height given to the shell panel.
    var shellFraction: CGFloat = 0.35 {
        didSet { needsLayout = true }
    }
    var onShellFractionChanged: ((CGFloat) -> Void)?

    private let divider = PaneDivider()

    override init(frame: NSRect) {
        super.init(frame: frame)
        divider.onDrag = { [weak self] y in self?.dragDivider(to: y) }
        divider.onDragEnd = { [weak self] in
            guard let self else { return }
            self.onShellFractionChanged?(self.shellFraction)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Shows a session (or nothing). Focus goes to the pane the session last used.
    func show(_ tab: TabSession?) {
        self.tab = tab
        let top = tab?.surface
        let bottom = tab?.shellVisible == true ? tab?.shellSurface : nil

        if current !== top {
            if let old = current { detach(old) }
            current = top
            if let top { attach(top) }
        }
        if currentShell !== bottom {
            if let old = currentShell { detach(old) }
            currentShell = bottom
            if let bottom { attach(bottom) }
        }

        // Remember whichever pane actually receives focus (click or programmatic).
        current?.onFocus = { [weak self] in self?.paneGotFocus(shell: false) }
        currentShell?.onFocus = { [weak self] in self?.paneGotFocus(shell: true) }

        if bottom != nil {
            if divider.superview == nil { addSubview(divider) }
        } else {
            divider.removeFromSuperview()
        }
        layoutPanes()
        focusCurrent()
    }

    private func attach(_ surface: TerminalSurfaceView) {
        surface.autoresizingMask = []
        addSubview(surface, positioned: .below, relativeTo: nil)
        surface.setVisible(true)
    }

    private func detach(_ surface: TerminalSurfaceView) {
        surface.setVisible(false)
        surface.removeFromSuperview()
    }

    func focusCurrent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let wantShell = self.tab?.shellFocused == true && self.currentShell != nil
            guard let target = wantShell ? self.currentShell : self.current else { return }
            if window.firstResponder !== target { window.makeFirstResponder(target) }
        }
    }

    /// Moves keyboard focus between Claude (top) and the shell (bottom).
    func focusPane(shell: Bool) {
        tab?.shellFocused = shell && currentShell != nil
        focusCurrent()
    }

    private func paneGotFocus(shell: Bool) {
        guard currentShell != nil else { return }
        tab?.shellFocused = shell
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    private static let dividerHeight: CGFloat = 5

    private func layoutPanes() {
        let b = bounds
        guard let top = current else {
            currentShell?.frame = b
            return
        }
        guard let bottom = currentShell else {
            top.frame = b
            return
        }
        let dh = Self.dividerHeight
        let shellH = (b.height * shellFraction).rounded()
        let topH = max(0, b.height - shellH - dh)
        top.frame = NSRect(x: 0, y: 0, width: b.width, height: topH)
        divider.frame = NSRect(x: 0, y: topH, width: b.width, height: dh)
        bottom.frame = NSRect(x: 0, y: topH + dh, width: b.width, height: b.height - topH - dh)
    }

    private func dragDivider(to y: CGFloat) {
        let local = convert(NSPoint(x: 0, y: y), from: nil).y
        guard bounds.height > 0 else { return }
        let fraction = (bounds.height - local) / bounds.height
        shellFraction = min(max(fraction, 0.12), 0.85)
        layoutPanes()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusCurrent()
    }
}

/// The draggable bar between Claude and the shell panel.
private final class PaneDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var store: AppStore

    func makeNSView(context: Context) -> TerminalContainerView {
        let view = TerminalContainerView()
        view.shellFraction = store.shellFraction
        view.onShellFractionChanged = { [weak store] f in
            store?.shellFraction = f
            store?.scheduleSave()
        }
        store.terminalContainer = view
        view.show(store.showingSchedules ? nil : store.selectedTab)
        return view
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {
        let tab = store.showingSchedules ? nil : store.selectedTab
        let wantShell = tab?.shellVisible == true ? tab?.shellSurface : nil
        if view.current !== tab?.surface || view.currentShell !== wantShell {
            view.show(tab)
        }
    }
}

/// Empty bar space that drags the window (and zooms on double-click).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Pointing-hand / resize cursors for SwiftUI elements.
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
