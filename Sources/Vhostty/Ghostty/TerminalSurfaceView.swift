import AppKit
import Carbon
import GhosttyC
import VhosttyRemote

/// An NSView hosting one libghostty terminal surface.
///
/// Keyboard, IME and mouse handling is adapted from Ghostty's macOS app
/// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, MIT licensed).
final class TerminalSurfaceView: NSView, NSTextInputClient {
    struct Options {
        var workingDirectory: String?
        var command: String?
        var environment: [String: String] = [:]
        var initialInput: String?
    }

    private(set) var surface: ghostty_surface_t?

    /// Called on the main thread whenever title / pwd / link hover change.
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    var terminalTitle: String = "" {
        didSet { if terminalTitle != oldValue { onTitleChange?(terminalTitle) } }
    }
    var pwd: String? {
        didSet { if let pwd, pwd != oldValue { onPwdChange?(pwd) } }
    }
    var hoverURL: String?
    var progress: Int?
    var cellSize: NSSize = .zero

    private(set) var focused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var contentSize: NSSize = .zero
    private var currentCursor: NSCursor = .iBeam
    private var observers: [NSObjectProtocol] = []
    private var screenContentsCache: (text: String, at: Date)?
    /// The size this view was given in the window, to tell resizes apart
    /// from being put in (see sizeDidChange).
    private var hostedSize: NSSize?
    private var tapBox: TapBox?

    init(options: Options) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        createSurface(options)
        updateTrackingAreas()
        registerForDraggedTypes([.string, .fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surface {
            if tapBox != nil { ghostty_surface_set_tap(surface, nil, nil, 0) }
            ghostty_surface_free(surface)
        }
    }

    private func createSurface(_ options: Options) {
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Keep every C string alive for the duration of ghostty_surface_new.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        func dup(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s else { return nil }
            let p = strdup(s)!
            cStrings.append(p)
            return UnsafePointer(p)
        }
        defer { cStrings.forEach { free($0) } }

        cfg.working_directory = dup(options.workingDirectory)
        cfg.command = dup(options.command)
        cfg.initial_input = dup(options.initialInput)

        var envVars = options.environment.map { ghostty_env_var_s(key: dup($0.key), value: dup($0.value)) }
        surface = envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        if surface == nil { NSLog("Vhostty: ghostty_surface_new failed") }
    }

    /// Asks libghostty to close the surface; it calls back through close_surface_cb.
    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    @discardableResult
    func perform(action: String) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// Types text into the terminal as if pasted (local input: at the local size).
    func sendText(_ text: String) {
        guard let surface else { return }
        useLocalGrid()
        let len = text.utf8CString.count
        guard len > 1 else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(len - 1)) }
    }

    /// The text currently visible in the viewport.
    func visibleText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Synthesizes a key press (debug driver only).
    func debugPress(keyCode: UInt16, chars: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let ev = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown { keyDown(with: ev) } else { keyUp(with: ev) }
        }
    }

    // MARK: - Remote clients

    /// The grid a remote client gave the session; nil while it has this
    /// view's own size. Only the terminal's columns and rows change, never
    /// the view: a smaller grid leaves blank space, a bigger one is cut off.
    private(set) var remoteGrid: (columns: Int, rows: Int)?

    /// The session's current columns and rows.
    var gridSize: (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    func useRemoteGrid(columns: Int, rows: Int) {
        guard let surface, columns > 0, rows > 0 else { return }
        if let g = remoteGrid, g.columns == columns, g.rows == rows { return }
        remoteGrid = (columns, rows)
        ghostty_surface_set_grid_override(surface, UInt16(min(columns, 1000)), UInt16(min(rows, 1000)))
    }

    /// Back to the size that fits this view.
    func useLocalGrid() {
        guard let surface, remoteGrid != nil else { return }
        remoteGrid = nil
        ghostty_surface_set_grid_override(surface, 0, 0)
    }

    enum TapEvent {
        /// Rebuilds the terminal at this size (after a reset).
        case snapshot(columns: Int, rows: Int, data: Data)
        case output(Data)
    }

    private final class TapBox {
        let handler: (TapEvent) -> Void
        init(_ handler: @escaping (TapEvent) -> Void) { self.handler = handler }
    }

    /// Mirrors the terminal: a snapshot now and after every size change, and
    /// everything the program writes in between. `handler` runs on the
    /// terminal's IO thread, in order, and must only hand the data on.
    func startTap(_ handler: @escaping (TapEvent) -> Void) {
        guard let surface else { return }
        let box = TapBox(handler)
        ghostty_surface_set_tap(surface, { userdata, kind, cols, rows, ptr, len in
            guard let userdata, let ptr else { return }
            let box = Unmanaged<TapBox>.fromOpaque(userdata).takeUnretainedValue()
            let data = Data(bytes: ptr, count: len)
            box.handler(kind == 1 ? .snapshot(columns: Int(cols), rows: Int(rows), data: data) : .output(data))
        }, Unmanaged.passUnretained(box).toOpaque(), Remote.snapshotHistoryRows)
        // Replaced after the new tap is in, so the old box outlives its last call.
        tapBox = box
    }

    func stopTap() {
        guard let surface, tapBox != nil else { return }
        ghostty_surface_set_tap(surface, nil, nil, 0)
        tapBox = nil
    }

    /// Writes bytes to the program as they are (a remote client's input).
    func writePTY(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_surface_write_pty(surface, base, UInt(buf.count))
        }
    }

    // MARK: - Focus & geometry

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focusDidChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusDidChange(false) }
        return ok
    }

    private func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
        if focused { onFocus?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostedSize = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.updateDisplayID()
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, let surface = self.surface, self.focused else { return }
            ghostty_surface_set_focus(surface, false)
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, let surface = self.surface, self.focused else { return }
            ghostty_surface_set_focus(surface, true)
        })
        updateDisplayID()
        viewDidChangeBackingProperties()
    }

    private func updateDisplayID() {
        guard let surface, let screen = window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
        ghostty_surface_set_display_id(surface, id)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: NSSize) {
        contentSize = size
        // The display area changed size (window resized, panel toggled): the
        // session takes the local size again. Being put in the window isn't
        // a change.
        if window != nil {
            if let hosted = hostedSize, hosted != size { useLocalGrid() }
            hostedSize = size
        }
        guard let surface, size.width > 0, size.height > 0 else { return }
        let scaled = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        sizeDidChange(contentSize == .zero ? frame.size : contentSize)
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: cursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            cursor = .resizeUpDown
        default: return
        }
        DispatchQueue.main.async {
            self.currentCursor = cursor
            self.window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, Self.mouseButton(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, Self.mouseButton(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Clear Screen"), action: #selector(clearScreen(_:)), keyEquivalent: "")
        return menu
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        // Scroll mods: bit 0 = precision, bits 1..3 = momentum phase.
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        // Typing (not ⌘ shortcuts, except paste) goes in at the local size.
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !mods.contains(.command) || (mods == [.command] && event.charactersIgnoringModifiers == "v") {
            useLocalGrid()
        }

        // Translate mods (e.g. for macos-option-as-alt).
        let translatedGhostty = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }

        // Reuse the original event when possible; required for some IMEs (e.g. Korean).
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore: String? = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // If the keyboard layout changed, an input method consumed this event.
        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action, event: event, translationEvent: translationEvent,
                text: Self.ghosttyCharacters(translationEvent),
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Vhostty's own shortcuts go to the menu even when Ghostty binds the same
        // key (Ghostty's default cmd+j is scroll_to_selection).
        if Self.isAppShortcut(event) { return false }

        // Ghostty keybindings (copy/paste, new tab, goto tab, font size, ...) win.
        var keyEv = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            keyEv.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEv, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        keyDown(with: finalEvent)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEv = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        keyEv.composing = composing
        // Control characters are encoded by Ghostty itself.
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                keyEv.text = ptr
                return ghostty_surface_key(surface, keyEv)
            }
        }
        return ghostty_surface_key(surface, keyEv)
    }

    // MARK: - Edit actions

    @objc func copy(_ sender: Any?) { perform(action: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) {
        useLocalGrid()
        perform(action: "paste_from_clipboard")
    }
    @objc override func selectAll(_ sender: Any?) { perform(action: "select_all") }
    @objc func clearScreen(_ sender: Any?) { perform(action: "clear_screen") }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let str = sender.draggingPasteboard.opinionatedString() else { return false }
        sendText(str)
        return true
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    // Empty ranges are (0, 0) rather than NSNotFound, as in Ghostty: some input
    // methods (e.g. Doubao voice input) never commit their text otherwise.
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0
        var width: Double = cellSize.width, height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        sendText(chars)
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch command-modified keys that went through performKeyEquivalent.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)): perform(action: "scroll_to_top")
        case #selector(moveToEndOfDocument(_:)): perform(action: "scroll_to_bottom")
        default: break
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ghostty_surface_preedit(surface, $0, UInt(len - 1)) }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Services

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        let types: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
        guard returnType.map(types.contains) ?? true, sendType.map(types.contains) ?? true else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        if sendType != nil, surface == nil || !ghostty_surface_has_selection(surface) {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        return self
    }

    @objc func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let surface else { return false }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    @objc func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.opinionatedString() else { return false }
        sendText(str)
        return true
    }

    // MARK: - Accessibility
    //
    // Exposed as an editable text area, as Ghostty does. Voice input apps look for
    // a focused text element before committing their text.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityHelp() -> String? { "Terminal content area" }
    override func accessibilityValue() -> Any? { screenContents }
    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }

    override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }

    override func accessibilityNumberOfCharacters() -> Int { screenContents.count }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: screenContents.count)
    }

    override func accessibilityLine(for index: Int) -> Int {
        String(screenContents.prefix(index)).components(separatedBy: .newlines).count - 1
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let content = screenContents
        guard let r = Range(range, in: content) else { return nil }
        return String(content[r])
    }

    /// The whole screen's text, cached for half a second since assistive
    /// tools query it many times in a row.
    private var screenContents: String {
        if let cache = screenContentsCache, Date().timeIntervalSince(cache.at) < 0.5 { return cache.text }
        var result = ""
        if let surface {
            var text = ghostty_text_s()
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: false)
            if ghostty_surface_read_text(surface, sel, &text) {
                result = String(cString: text.text)
                ghostty_surface_free_text(surface, &text)
            }
        }
        screenContentsCache = (result, Date())
        return result
    }

    // MARK: - Helpers

    /// Shortcuts reserved for Vhostty's menu: ⌘J and ⌃` (toggle the shell panel).
    static func isAppShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 0x26: return mods == [.command]   // J
        case 0x32: return mods == [.control]   // `
        default: return false
        }
    }

    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func keyEvent(
        _ event: NSEvent,
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = mods(event.modifierFlags)
        // Control and command never contribute to text translation.
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// Text for a key event, excluding control characters and function-key PUA codepoints.
    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    static func mouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
