import GhosttyTerminal
import UIKit

/// The bar under the terminal. It shows the keys a phone keyboard lacks;
/// while the keyboard is up and something is typed, it shows the text field
/// the typing goes into and a send key instead. The keyboard always belongs
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
        Key(label: "←", image: "arrowtriangle.left.fill", accessibility: NSLocalizedString("Left Arrow", comment: "Key"), press: TerminalKeyPress(.arrowLeft)),
        Key(label: "↓", image: "arrowtriangle.down.fill", accessibility: NSLocalizedString("Down Arrow", comment: "Key"), press: TerminalKeyPress(.arrowDown)),
        Key(label: "↑", image: "arrowtriangle.up.fill", accessibility: NSLocalizedString("Up Arrow", comment: "Key"), press: TerminalKeyPress(.arrowUp)),
        Key(label: "→", image: "arrowtriangle.right.fill", accessibility: NSLocalizedString("Right Arrow", comment: "Key"), press: TerminalKeyPress(.arrowRight)),
    ]

    let composer = ComposerTextView()
    private weak var terminal: UITerminalView?
    private let keysCapsule = TerminalInputBar.makeCapsule()
    private let fieldCapsule = TerminalInputBar.makeCapsule()
    private let sendButton = UIButton(type: .system)
    private var composerHeight: NSLayoutConstraint!
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
        let row = UIStackView(arrangedSubviews: Self.keys.map(makeKey))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.keySpacing
        addSubview(keysCapsule)
        keysCapsule.contentView.addSubview(row)
        let pad = (Self.rowHeight - 36) / 2
        // The keys share the row; past their widest the row stops growing
        // and stays centered (an iPad).
        let widest = CGFloat(Self.keys.count) * Self.maxKeyWidth + CGFloat(Self.keys.count - 1) * Self.keySpacing + pad * 2
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

    private func makeKey(_ key: Key) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .label
        button.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.92)
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
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

        addSubview(fieldCapsule)
        fieldCapsule.contentView.addSubview(composer)
        fieldCapsule.contentView.addSubview(sendButton)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            fieldCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            fieldCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            fieldCapsule.bottomAnchor.constraint(equalTo: keysCapsule.bottomAnchor),
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
        fitComposer()
    }

    func focus() { composer.becomeFirstResponder() }

    private func press(_ key: TerminalKeyPress) {
        terminal?.sendKey(key)
    }

    /// A key, by its label, for the debug driver.
    func debugPress(_ label: String) {
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
