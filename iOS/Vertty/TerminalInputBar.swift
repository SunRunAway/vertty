import GhosttyTerminal
import UIKit
import UniformTypeIdentifiers

/// The bar under the terminal. It shows the keys a phone keyboard lacks and,
/// at the right end, the key that brings the keyboard up and puts it away;
/// while the keyboard is up and something is typed, the text field the
/// typing goes into and a send key take the other keys' place. The keyboard always belongs
/// to that field (`composer`), even while the keys show, so switching
/// between the two never moves the focus or breaks an IME composition.
final class TerminalInputBar: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The height the bar takes from the terminal. A field taller than one
    /// line grows up over the terminal instead, so typing never resizes the
    /// session.
    static let height: CGFloat = 56
    private static let rowHeight: CGFloat = 44
    private static let inset: CGFloat = 8
    private static let keySpacing: CGFloat = 4
    private static let maxKeyWidth: CGFloat = 56
    private static let maxLines: CGFloat = 5

    enum Mode { case keys, field }

    private struct Key {
        let label: String
        let image: String?
        let accessibility: String
        let press: TerminalKeyPress
    }

    private static let keys: [Key] = [
        Key(label: "Esc", image: nil, accessibility: NSLocalizedString("Escape", comment: "Key"), press: TerminalKeyPress(.escape)),
        Key(label: "Tab", image: "arrow.right.to.line", accessibility: NSLocalizedString("Tab", comment: "Key"), press: TerminalKeyPress(.tab)),
        Key(label: "⇧Tab", image: nil, accessibility: NSLocalizedString("Shift-Tab", comment: "Key"), press: TerminalKeyPress(.tab, modifiers: .shift)),
        Key(label: "^C", image: nil, accessibility: NSLocalizedString("Control-C", comment: "Key"), press: TerminalKeyPress(.c, modifiers: .ctrl)),
        Key(label: "↓", image: "arrowtriangle.down.fill", accessibility: NSLocalizedString("Down Arrow", comment: "Key"), press: TerminalKeyPress(.arrowDown)),
        Key(label: "↑", image: "arrowtriangle.up.fill", accessibility: NSLocalizedString("Up Arrow", comment: "Key"), press: TerminalKeyPress(.arrowUp)),
    ]

    let composer = ComposerTextView()
    private weak var terminal: UITerminalView?
    private let keysCapsule = TerminalInputBar.makeCapsule()
    private let fieldCapsule = TerminalInputBar.makeCapsule()
    private let sendButton = UIButton(type: .system)
    /// Brings the keyboard up and puts it away, always at the right end:
    /// the last of the keys, and beside the field while it shows.
    private let keysToggle = UIButton(type: .system)
    /// The system's paste key: one the app draws itself would have iOS ask
    /// for permission on every paste.
    private lazy var pasteKey: UIPasteControl = {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.systemGray5.withAlphaComponent(0.92)
        config.baseForegroundColor = .label
        let key = UIPasteControl(configuration: config)
        key.target = pasteTarget
        return key
    }()
    private lazy var pasteTarget = PasteTarget { [weak self] providers in self?.paste(providers) }
    private let fieldToggleCapsule = TerminalInputBar.makeCapsule()
    private let fieldToggle = UIButton(type: .system)
    private var composerHeight: NSLayoutConstraint!
    private let diagnosticID = UUID().uuidString
    private var diagnosticTimer: Timer?
    private var diagnosticState: Data?
    private var diagnosticTime: TimeInterval = 0

    private(set) var mode = Mode.keys

    /// Whether the software keyboard is up, and putting it away: the owner
    /// knows whether the terminal took it instead (a hardware keyboard).
    var keyboardIsUp: () -> Bool = { false }
    var hideKeyboard: () -> Void = {}

    init(terminal: UITerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setUpKeys()
        setUpField()
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        // A swipe down on the bar puts the keyboard away.
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipe.delegate = self
        addGestureRecognizer(swipe)
        update()
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification,
                     UIApplication.didReceiveMemoryWarningNotification, UIApplication.userDidTakeScreenshotNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIPasteboard.changedNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(diagnosticNotification(_:)), name: name, object: nil)
        }
        diagnosePaste("created", force: true)
    }

    deinit {
        diagnosticTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        PasteDiagnostics.record("destroyed", state: ["bar": diagnosticID])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        if window != nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else { return }
                self?.diagnosePaste("sample")
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            diagnosticTimer = timer
        }
        diagnosePaste("window", force: true)
    }

    @objc private func diagnosticNotification(_ notification: Notification) {
        let event = notification.name.rawValue
        diagnosePaste(event, force: true, flush: true)
        // UIKit's system subviews can settle after the notification itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.window != nil, UIApplication.shared.applicationState == .active else { return }
            self.diagnosePaste(event + ".settled", force: true)
        }
    }

    private func diagnosePaste(_ event: String, force: Bool = false, flush: Bool = false) {
        var ancestors: [[String: Any]] = []
        var ancestor = pasteKey.superview
        var visible = pasteKey.convert(pasteKey.bounds, to: window)
        var hidden = pasteKey.isHidden
        var alpha = pasteKey.alpha
        while let view = ancestor {
            ancestors.append(PasteDiagnostics.view(view))
            hidden = hidden || view.isHidden
            alpha *= view.alpha
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        if let window { visible = visible.intersection(window.bounds) }
        let state: [String: Any] = [
            "bar": diagnosticID, "mode": mode == .keys ? "keys" : "field",
            "appState": UIApplication.shared.applicationState.rawValue,
            "sceneState": window?.windowScene?.activationState.rawValue ?? -1,
            "keyboardUp": keyboardIsUp(), "composerFocused": composer.isFirstResponder,
            "composerHasText": composer.hasText, "enabled": pasteKey.isEnabled,
            "targetMatches": pasteKey.target === pasteTarget,
            "acceptedTypes": pasteTarget.pasteConfiguration?.acceptableTypeIdentifiers ?? [],
            "effectiveHidden": hidden, "effectiveAlpha": alpha,
            "clippedRect": NSCoder.string(for: visible),
            "control": PasteDiagnostics.view(pasteKey, depth: 4), "ancestors": ancestors,
        ]
        let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        let now = ProcessInfo.processInfo.systemUptime
        guard force || data != diagnosticState || now - diagnosticTime >= 60 else { return }
        diagnosticState = data
        diagnosticTime = now
        PasteDiagnostics.record(event, state: state, flush: flush)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private static func makeCapsule() -> UIVisualEffectView {
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            effect = glass
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let capsule = UIVisualEffectView(effect: effect)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.clipsToBounds = true
        capsule.layer.cornerRadius = rowHeight / 2
        capsule.layer.cornerCurve = .continuous
        return capsule
    }

    private func setUpKeys() {
        styleKey(keysToggle)
        keysToggle.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: Self.keys.map(makeKey) + [pasteKey, keysToggle])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.keySpacing
        addSubview(keysCapsule)
        keysCapsule.contentView.addSubview(row)
        let pad = (Self.rowHeight - 36) / 2
        // The keys share the row; past their widest the row stops growing
        // and stays centered (an iPad).
        let count = CGFloat(row.arrangedSubviews.count)
        let widest = count * Self.maxKeyWidth + (count - 1) * Self.keySpacing + pad * 2
        let fill = keysCapsule.widthAnchor.constraint(equalTo: widthAnchor, constant: -Self.inset * 2)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            keysCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            keysCapsule.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Self.inset * 2),
            keysCapsule.widthAnchor.constraint(lessThanOrEqualToConstant: widest),
            fill,
            keysCapsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.height - Self.rowHeight) / 2),
            keysCapsule.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            row.leadingAnchor.constraint(equalTo: keysCapsule.contentView.leadingAnchor, constant: pad),
            row.trailingAnchor.constraint(equalTo: keysCapsule.contentView.trailingAnchor, constant: -pad),
            row.topAnchor.constraint(equalTo: keysCapsule.contentView.topAnchor, constant: pad),
            row.bottomAnchor.constraint(equalTo: keysCapsule.contentView.bottomAnchor, constant: -pad),
        ])
    }

    private func styleKey(_ button: UIButton) {
        button.tintColor = .label
        button.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.92)
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
    }

    private func makeKey(_ key: Key) -> UIButton {
        let button = UIButton(type: .system)
        styleKey(button)
        button.accessibilityLabel = key.accessibility
        if let image = key.image {
            button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        } else {
            button.setTitle(key.label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.6
        }
        button.addAction(UIAction { [weak self] _ in self?.press(key.press) }, for: .touchUpInside)
        return button
    }

    private func setUpField() {
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        composer.backgroundColor = .clear
        composer.font = .systemFont(ofSize: 17)
        composer.textColor = .label
        composer.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 0)
        composer.isScrollEnabled = false
        // What's typed here is for a terminal program: nothing changes it.
        composer.autocorrectionType = .no
        composer.autocapitalizationType = .none
        composer.spellCheckingType = .no
        composer.smartQuotesType = .no
        composer.smartDashesType = .no
        composer.smartInsertDeleteType = .no
        composer.inlinePredictionType = .no
        composer.terminal = terminal

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        send.contentInsets = .zero
        sendButton.configuration = send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityLabel = NSLocalizedString("Send", comment: "Sends the typed text to the terminal")
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)

        fieldToggle.translatesAutoresizingMaskIntoConstraints = false
        fieldToggle.tintColor = .label
        fieldToggle.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .touchUpInside)

        addSubview(fieldCapsule)
        addSubview(fieldToggleCapsule)
        fieldCapsule.contentView.addSubview(composer)
        fieldCapsule.contentView.addSubview(sendButton)
        fieldToggleCapsule.contentView.addSubview(fieldToggle)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            fieldCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            fieldCapsule.trailingAnchor.constraint(equalTo: fieldToggleCapsule.leadingAnchor, constant: -6),
            fieldCapsule.bottomAnchor.constraint(equalTo: keysCapsule.bottomAnchor),
            fieldToggleCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            fieldToggleCapsule.bottomAnchor.constraint(equalTo: keysCapsule.bottomAnchor),
            fieldToggleCapsule.widthAnchor.constraint(equalToConstant: Self.rowHeight),
            fieldToggleCapsule.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            fieldToggle.leadingAnchor.constraint(equalTo: fieldToggleCapsule.contentView.leadingAnchor),
            fieldToggle.trailingAnchor.constraint(equalTo: fieldToggleCapsule.contentView.trailingAnchor),
            fieldToggle.topAnchor.constraint(equalTo: fieldToggleCapsule.contentView.topAnchor),
            fieldToggle.bottomAnchor.constraint(equalTo: fieldToggleCapsule.contentView.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: fieldCapsule.contentView.leadingAnchor, constant: 8),
            composer.topAnchor.constraint(equalTo: fieldCapsule.contentView.topAnchor),
            composer.bottomAnchor.constraint(equalTo: fieldCapsule.contentView.bottomAnchor),
            composerHeight,
            sendButton.leadingAnchor.constraint(equalTo: composer.trailingAnchor, constant: 4),
            sendButton.trailingAnchor.constraint(equalTo: fieldCapsule.contentView.trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: fieldCapsule.contentView.bottomAnchor, constant: -6),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitComposer()
        diagnosePaste("layout")
    }

    /// The field grows with its lines, up to `maxLines`, then scrolls.
    private func fitComposer() {
        guard composer.bounds.width > 0, let font = composer.font else { return }
        let inset = composer.textContainerInset.top + composer.textContainerInset.bottom
        let most = (font.lineHeight * Self.maxLines).rounded(.up) + inset
        let natural = composer.sizeThatFits(CGSize(width: composer.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(max(natural, Self.rowHeight), most)
        let scrolls = natural > most
        if composer.isScrollEnabled != scrolls { composer.isScrollEnabled = scrolls }
        if composerHeight.constant != height { composerHeight.constant = height }
    }

    /// The field reaches above the bar when it has grown; touches there are
    /// still the bar's.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (mode == .field && fieldCapsule.frame.contains(point))
    }

    /// Where the bar's visible part starts, in `view`'s coordinates.
    func visibleTop(in view: UIView) -> CGFloat {
        let capsule = mode == .field ? fieldCapsule : keysCapsule
        return capsule.convert(capsule.bounds, to: view).minY
    }

    // MARK: - State

    /// The field while the keyboard is up and something is typed (an IME
    /// composition counts), the keys otherwise.
    private func update() {
        let mode: Mode = composer.isFirstResponder && composer.hasText ? .field : .keys
        if mode != self.mode {
            self.mode = mode
            setNeedsLayout()
        }
        keysCapsule.isHidden = mode == .field
        // Transparent rather than hidden: the field has to stay able to
        // take the keyboard.
        fieldCapsule.alpha = mode == .field ? 1 : 0
        fieldToggleCapsule.alpha = fieldCapsule.alpha
        let up = keyboardIsUp()
        let icon = UIImage(systemName: up ? "keyboard.chevron.compact.down" : "keyboard",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        let label = up ? NSLocalizedString("Hide Keyboard", comment: "Key") : NSLocalizedString("Show Keyboard", comment: "Key")
        for toggle in [keysToggle, fieldToggle] {
            toggle.setImage(icon, for: .normal)
            toggle.accessibilityLabel = label
        }
        fitComposer()
        diagnosePaste("update")
    }

    func focus() { composer.becomeFirstResponder() }

    /// Text goes into the field, which then shows with the keyboard up, to
    /// be edited before it's sent. A picture or file goes to the terminal,
    /// which pastes it as its path.
    private func paste(_ providers: [NSItemProvider]) {
        diagnosePaste("pasteCallback", force: true)
        guard let text = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            terminal?.paste(nil)
            return
        }
        _ = text.loadObject(ofClass: NSString.self) { [weak self] object, error in
            PasteDiagnostics.record("pasteTextLoaded", state: ["success": object is String,
                "errorDomain": (error as NSError?)?.domain ?? "", "errorCode": (error as NSError?)?.code ?? 0])
            guard let string = object as? String else { return }
            DispatchQueue.main.async {
                self?.focus()
                self?.composer.insertText(string)
            }
        }
    }

    private func toggleKeyboard() {
        if keyboardIsUp() { hideKeyboard() } else { focus() }
    }

    private func press(_ key: TerminalKeyPress) {
        terminal?.sendKey(key)
    }

    /// A key, by its label, for the debug driver.
    func debugPress(_ label: String) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["VERTTY_DEBUG"] == "1" {
                switch label {
                case "diagnostic-hide-paste": pasteKey.isHidden = true
                case "diagnostic-detach-target": pasteKey.target = nil
                case "diagnostic-restore-paste":
                    pasteKey.isHidden = false
                    pasteKey.target = pasteTarget
                default: break
                }
                if label.hasPrefix("diagnostic-") {
                    diagnosePaste(label, force: true, flush: true)
                    return
                }
            }
        #endif
        if label == "keyboard" { return toggleKeyboard() }
        if label == "paste" { return paste([NSItemProvider(object: "pasted" as NSString)]) }
        if let key = Self.keys.first(where: { $0.label.lowercased() == label.lowercased() }) { press(key.press) }
    }

    /// Sends what's typed as one paste (a program with bracketed paste
    /// takes its line breaks as text), then Enter to submit it. Enter waits
    /// a moment: Claude Code and Codex take keys that arrive right with a
    /// paste as part of it.
    func send() {
        composer.unmarkText()
        guard let text = composer.text, !text.isEmpty, let terminal else { return }
        composer.text = ""
        update()
        terminal.paste(text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak terminal] in
            terminal?.sendKey(.enter)
        }
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) { update() }
    func textViewDidBeginEditing(_ textView: UITextView) { update() }
    func textViewDidEndEditing(_ textView: UITextView) { update() }

    // MARK: - Swipe down

    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { hideKeyboard() }
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view === self else {
            return super.gestureRecognizerShouldBegin(gesture)
        }
        let velocity = pan.velocity(in: self)
        // A field with more than fits scrolls down to its top first.
        let atTop = !composer.isScrollEnabled || composer.contentOffset.y <= 0
        return keyboardIsUp() && velocity.y > abs(velocity.x) && atTop
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// What the paste key pastes into.
private final class PasteTarget: UIResponder {
    private let onPaste: ([NSItemProvider]) -> Void

    init(onPaste: @escaping ([NSItemProvider]) -> Void) {
        self.onPaste = onPaste
        super.init()
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.text.identifier, UTType.image.identifier, UTType.fileURL.identifier,
        ])
    }

    override func paste(itemProviders: [NSItemProvider]) { onPaste(itemProviders) }
}

/// The bar's text field. With nothing typed it passes what has no text to
/// edit to the terminal: Return (to answer a menu), Backspace, sliding on
/// the space bar. A picture or file it can't hold is pasted there too.
final class ComposerTextView: UITextView {
    weak var terminal: UITerminalView?
    private var slidesTerminal = false

    /// Return is a line break once something is typed.
    override func insertText(_ text: String) {
        if text == "\n", !hasText { terminal?.sendKey(.enter) } else { super.insertText(text) }
    }

    override func deleteBackward() {
        if hasText { super.deleteBackward() } else { terminal?.sendKey(.backspace) }
    }

    override func beginFloatingCursor(at point: CGPoint) {
        slidesTerminal = !hasText
        if slidesTerminal { terminal?.beginFloatingCursor(at: point) } else { super.beginFloatingCursor(at: point) }
    }

    override func updateFloatingCursor(at point: CGPoint) {
        if slidesTerminal { terminal?.updateFloatingCursor(at: point) } else { super.updateFloatingCursor(at: point) }
    }

    override func endFloatingCursor() {
        if slidesTerminal { terminal?.endFloatingCursor() } else { super.endFloatingCursor() }
        slidesTerminal = false
    }

    /// The terminal pastes a picture or file as its path, which is how
    /// Claude Code and Codex take one; the field can't hold it.
    private var pastesInTerminal: Bool {
        !UIPasteboard.general.hasStrings && UIPasteboard.general.numberOfItems > 0
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), pastesInTerminal { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if pastesInTerminal, let terminal { terminal.paste(sender) } else { super.paste(sender) }
    }
}
