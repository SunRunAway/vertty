import AppKit
import GhosttyC

/// Things the runtime needs from the rest of the app. All calls happen on the main thread.
protocol GhosttyRuntimeDelegate: AnyObject {
    func ghosttyNewTab(from surface: TerminalSurfaceView?)
    func ghosttyCloseTab(_ surface: TerminalSurfaceView)
    func ghosttyGotoTab(_ target: GhosttyGotoTab)
    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e)
    func ghosttySurfaceRequestedClose(_ surface: TerminalSurfaceView, processAlive: Bool)
    func ghosttyDesktopNotification(_ surface: TerminalSurfaceView?, title: String, body: String)
    func ghosttyBell(_ surface: TerminalSurfaceView)
}

enum GhosttyGotoTab {
    case previous, next, last, index(Int)
}

/// Owns the single libghostty app instance and routes its C callbacks.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    weak var delegate: GhosttyRuntimeDelegate?

    private var tickScheduled = false
    private let tickLock = NSLock()

    private init() {}

    /// Initializes libghostty. Must be called once, before any surface is created.
    func start() -> Bool {
        // Point libghostty at our bundled resources (terminfo, shell integration, themes),
        // overriding anything inherited from a parent Ghostty process.
        if let res = Bundle.main.resourcePath {
            setenv("GHOSTTY_RESOURCES_DIR", res + "/ghostty", 1)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("Vhostty: ghostty_init failed")
            return false
        }

        guard let cfg = Self.loadConfig() else { return false }
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state in GhosttyRuntime.readClipboard(userdata, location: loc, state: state) },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, string: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in GhosttyRuntime.closeSurface(userdata, processAlive: processAlive) }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("Vhostty: ghostty_app_new failed")
            return false
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
        return true
    }

    /// Vhostty defaults first, then the user's regular Ghostty config on top.
    private static func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if let defaults = Bundle.main.path(forResource: "ghostty-defaults", ofType: "conf") {
            ghostty_config_load_file(cfg, defaults)
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message { NSLog("Vhostty: ghostty config: %@", String(cString: msg)) }
        }
        return cfg
    }

    /// The terminal background color from the Ghostty config.
    var backgroundColor: NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    func reloadConfig() {
        guard let app, let cfg = Self.loadConfig() else { return }
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    func tick() {
        tickLock.lock()
        tickScheduled = false
        tickLock.unlock()
        if let app { ghostty_app_tick(app) }
    }

    // MARK: - C callbacks

    private static func runtime(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime {
        Unmanaged<GhosttyRuntime>.fromOpaque(userdata!).takeUnretainedValue()
    }

    /// Surface callbacks receive the surface's userdata, which is the TerminalSurfaceView.
    private static func surfaceView(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(of surface: ghostty_surface_t?) -> TerminalSurfaceView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let rt = runtime(userdata)
        rt.tickLock.lock()
        let already = rt.tickScheduled
        rt.tickScheduled = true
        rt.tickLock.unlock()
        if !already {
            DispatchQueue.main.async { rt.tick() }
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let view = surfaceView(userdata) else { return }
        DispatchQueue.main.async {
            shared.delegate?.ghosttySurfaceRequestedClose(view, processAlive: processAlive)
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = surfaceView(userdata), let surface = view.surface else { return false }
        guard let pb = NSPasteboard.ghostty(location), let str = pb.opinionatedString() else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = surfaceView(userdata), let string else { return }
        let value = String(cString: string)
        DispatchQueue.main.async {
            guard let surface = view.surface else { return }
            let alert = NSAlert()
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                alert.messageText = String(localized: "Allow a terminal program to read the clipboard?")
                alert.informativeText = String(localized: "A program in the terminal is asking to read your clipboard contents.")
            default:
                alert.messageText = String(localized: "Paste potentially unsafe content?")
                alert.informativeText = String(value.prefix(600))
            }
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let ok = alert.runModal() == .alertFirstButtonReturn
            let result = ok ? value : ""
            result.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, ok) }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let pb = NSPasteboard.ghostty(location), let content, len > 0 else { return }
        var items: [(NSPasteboard.PasteboardType, String)] = []
        for i in 0..<len {
            let c = content[i]
            guard let mime = c.mime, let data = c.data else { continue }
            let mimeStr = String(cString: mime)
            let type: NSPasteboard.PasteboardType = mimeStr == "text/plain" ? .string
                : mimeStr == "text/html" ? .html : NSPasteboard.PasteboardType(mimeStr)
            items.append((type, String(cString: data)))
        }
        guard !items.isEmpty else { return }

        let write = {
            pb.declareTypes(items.map(\.0), owner: nil)
            for (type, value) in items { pb.setString(value, forType: type) }
        }
        if !confirm {
            write()
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "Allow a terminal program to write to the clipboard?")
            alert.informativeText = String((items.first { $0.0 == .string }?.1 ?? "").prefix(600))
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { write() }
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalSurfaceView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? surfaceView(of: target.target.surface) : nil
        let delegate = shared.delegate

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)

        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            delegate?.ghosttyNewTab(from: view)

        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let view else { return false }
            delegate?.ghosttyCloseTab(view)

        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            switch raw {
            case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: delegate?.ghosttyGotoTab(.previous)
            case GHOSTTY_GOTO_TAB_NEXT.rawValue: delegate?.ghosttyGotoTab(.next)
            case GHOSTTY_GOTO_TAB_LAST.rawValue: delegate?.ghosttyGotoTab(.last)
            default: delegate?.ghosttyGotoTab(.index(Int(raw)))
            }

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let direction = action.action.goto_split
            DispatchQueue.main.async { delegate?.ghosttyGotoSplit(direction) }

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let ptr = action.action.set_title.title else { return false }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.terminalTitle = title }

        case GHOSTTY_ACTION_PWD:
            guard let view, let ptr = action.action.pwd.pwd else { return false }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { view.pwd = pwd }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view else { return false }
            view.setCursorShape(action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view else { return false }
            let link = action.action.mouse_over_link
            let url: String? = link.len > 0 && link.url != nil
                ? String(decoding: UnsafeRawBufferPointer(start: link.url, count: link.len), as: UTF8.self) : nil
            DispatchQueue.main.async { view.hoverURL = url }

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let str = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), as: UTF8.self)
            let url: URL? = str.hasPrefix("/") ? URL(fileURLWithPath: str) : URL(string: str)
            if let url {
                DispatchQueue.main.async {
                    if ScheduleTask.id(from: url) != nil {
                        (NSApp.delegate as? AppDelegate)?.openScheduleURL(url)
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let size = action.action.cell_size
            let scale = view.window?.backingScaleFactor ?? 2
            view.cellSize = NSSize(width: Double(size.width) / scale, height: Double(size.height) / scale)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { delegate?.ghosttyDesktopNotification(view, title: title, body: body) }

        case GHOSTTY_ACTION_RING_BELL:
            guard let view else { return false }
            DispatchQueue.main.async { delegate?.ghosttyBell(view) }

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            (view?.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async { shared.reloadConfig() }

        case GHOSTTY_ACTION_OPEN_CONFIG:
            let path = ghostty_config_open_path()
            defer { ghostty_string_free(path) }
            if let ptr = path.ptr {
                let str = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(path.len)), as: UTF8.self)
                NSWorkspace.shared.open(URL(fileURLWithPath: str))
            }

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view else { return false }
            let report = action.action.progress_report
            DispatchQueue.main.async {
                view.progress = report.state == GHOSTTY_PROGRESS_STATE_REMOVE ? nil : Int(report.progress)
            }

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
                NSLog("Vhostty: renderer unhealthy")
            }

        default:
            return false
        }
        return true
    }
}

extension NSPasteboard {
    static let ghosttySelection = NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))

    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return ghosttySelection
        default: return nil
        }
    }

    /// File URLs become shell-escaped paths; otherwise plain string contents.
    func opinionatedString() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { $0.isFileURL ? ShellQuote.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        return string(forType: .string)
    }
}

enum ShellQuote {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Backslash-escapes characters that are special to the shell (for pasting paths).
    static func escape(_ str: String) -> String {
        var result = ""
        for ch in str {
            if escapeCharacters.contains(ch) { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    /// Single-quotes a string for use in a shell command line.
    static func quote(_ str: String) -> String {
        if !str.isEmpty, str.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }) {
            return str
        }
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
