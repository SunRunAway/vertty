import AppKit
import Network
import VerttyRemote
import VerttyTailnet

/// Serves remote clients (the iPhone app, Vertty on another Mac) over one
/// WebSocket per client; see VerttyKit/Proto/vertty_remote.proto. Off unless
/// a way in the "Remote Connections" submenu is checked; either or both:
/// - Via Tailscale: on the embedded Tailscale device (VerttyTailnet), which
///   forwards the same user's connections to a port on 127.0.0.1;
/// - Own Network: on the port on every interface.
/// Each way has a listener of its own, so one failing leaves the other.
/// Keeps one client at a time, whichever way it came: a new one replaces
/// the previous connection.
final class RemoteServer: ObservableObject {
    /// Present while remote connections are allowed; holds the checked
    /// Modes, one per line (empty means Own Network, from before there was
    /// a choice).
    static var enabledMarker: URL { AppPaths.support.appendingPathComponent("remote-enabled") }

    enum Mode: String, CaseIterable {
        case tailscale
        case direct
    }

    /// A checked way's listener (absent while unchecked).
    enum Status: Equatable {
        case starting
        /// Own Network: the port; Via Tailscale: the local port the device
        /// forwards to (Tailnet.shared has the details).
        case listening(UInt16)
        /// Couldn't start; the reason is shown in the menu.
        case failed(String)
    }

    struct ClientInfo: Equatable {
        let deviceName: String
        let platform: Remote.ClientPlatform
        let since: Date
    }

    @Published private(set) var status: [Mode: Status] = [:]
    /// The connected client, if any.
    @Published private(set) var client: ClientInfo?

    /// The checked ways.
    var modes: Set<Mode> {
        guard let data = FileManager.default.contents(atPath: Self.enabledMarker.path) else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.isEmpty ? [.direct] : Set(lines.compactMap { Mode(rawValue: String($0)) })
    }

    private let store: AppStore
    private var listeners: [Mode: NWListener] = [:]
    /// Connections that haven't sent Hello yet.
    private var greeting: [ObjectIdentifier: RemoteConnection] = [:]
    private var current: RemoteConnection?
    /// Token of the last client accepted (see ONE CLIENT AT A TIME).
    private var currentToken: String?
    private lazy var bridge = RemoteBridge(store: store, server: self)

    init(store: AppStore) {
        self.store = store
    }

    /// A way's checkbox in the menu. Checking Tailscale opens its sign-in
    /// page if this Mac isn't signed in.
    func set(_ mode: Mode, enabled: Bool) {
        var modes = modes
        if enabled { modes.insert(mode) } else { modes.remove(mode) }
        if modes.isEmpty {
            try? FileManager.default.removeItem(at: Self.enabledMarker)
        } else {
            let text = Mode.allCases.filter(modes.contains).map(\.rawValue).joined(separator: "\n")
            FileManager.default.createFile(atPath: Self.enabledMarker.path, contents: Data(text.utf8))
        }
        if enabled {
            start(mode)
            if mode == .tailscale, Tailnet.shared.state != .running {
                TailscaleSignIn.shared.start()
            }
        } else {
            stop(mode)
        }
    }

    /// Starts the checked ways (at launch, once the shell's environment with
    /// VERTTY_REMOTE_PORT is known).
    func startIfEnabled() {
        for mode in modes { start(mode) }
    }

    private func start(_ mode: Mode) {
        stop(mode)
        let port: UInt16
        if mode == .tailscale {
            // Any free port: only the Tailscale device connects to it.
            port = 0
            // Started now, so signing in can begin before the port is ready.
            Tailnet.shared.use()
        } else {
            switch Self.configuredPort() {
            case .success(let p): port = p
            case .failure(let reason):
                status[mode] = .failed(reason.message)
                return
            }
        }

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Remote.maxFrameSize
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if mode == .tailscale {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            }
        } catch {
            status[mode] = .failed(error.localizedDescription)
            return
        }
        listeners[mode] = listener
        status[mode] = .starting
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listeners[mode] === listener else { return }
            switch state {
            case .ready:
                guard let local = listener.port?.rawValue else { return }
                self.status[mode] = .listening(local)
                guard mode == .tailscale else { return }
                Tailnet.shared.serve(port: Remote.defaultPort, to: local) { [weak self] reason in
                    guard let self, self.listeners[mode] === listener else { return }
                    self.status[mode] = .failed(reason)
                }
            case .failed(let error):
                // No retry: the reason stays in the menu.
                self.status[mode] = .failed(Self.describe(error))
                listener.cancel()
                self.listeners[mode] = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, via: mode)
        }
        listener.start(queue: .main)
    }

    /// Stops a way and ends the connections that came that way.
    private func stop(_ mode: Mode) {
        if let listener = listeners.removeValue(forKey: mode) {
            listener.stateUpdateHandler = nil
            listener.cancel()
        }
        if mode == .tailscale, status[mode] != nil {
            Tailnet.shared.stopServing()
            Tailnet.shared.endUse()
        }
        for c in greeting.values where c.via == mode { c.close() }
        if let current, current.via == mode {
            drop(current)
            current.close()
        }
        status[mode] = nil
    }

    struct PortError: Error { let message: String }

    /// VERTTY_REMOTE_PORT from the login shell, else the default.
    static func configuredPort() -> Result<UInt16, PortError> {
        guard let raw = ShellEnvironment.remotePort?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .success(Remote.defaultPort)
        }
        guard let n = Int(raw), (1...65535).contains(n) else {
            return .failure(PortError(message: String(localized: "VERTTY_REMOTE_PORT is “\(raw)”, not a port number (1–65535).")))
        }
        return .success(UInt16(n))
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return String(localized: "The port is already in use by another program.")
        }
        return error.localizedDescription
    }

    // MARK: - Connections

    private func accept(_ nw: NWConnection, via mode: Mode) {
        let connection = RemoteConnection(nw, via: mode)
        greeting[ObjectIdentifier(connection)] = connection
        connection.onMessage = { [weak self, weak connection] msg in
            guard let self, let connection else { return }
            self.received(msg, from: connection)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.greeting.removeValue(forKey: ObjectIdentifier(connection))
            if self.current === connection { self.drop(connection) }
        }
        connection.start()
    }

    private func received(_ msg: Remote.ClientMessage, from connection: RemoteConnection) {
        if case .hello(let hello) = msg.body {
            greeted(hello, connection)
            return
        }
        guard connection === current else {
            // Anything before Hello is a protocol error.
            connection.fail(.badRequest, "Expected Hello first.")
            return
        }
        bridge.handle(msg, from: connection)
    }

    private func greeted(_ hello: Remote.Hello, _ connection: RemoteConnection) {
        greeting.removeValue(forKey: ObjectIdentifier(connection))
        guard hello.protocolVersion == .current else {
            connection.fail(.incompatibleVersion, "Protocol version \(hello.protocolVersion.rawValue) is not supported.")
            return
        }
        // Reconnecting on its own, but another client connected since.
        if !hello.reconnectToken.isEmpty, let token = currentToken, token != hello.reconnectToken {
            connection.fail(.replaced, "Another device connected.")
            return
        }
        if let old = current {
            old.send { $0.replaced = .init() }
            drop(old)
            old.close()
        }
        let token = UUID().uuidString
        currentToken = token
        current = connection
        client = ClientInfo(deviceName: hello.deviceName, platform: hello.platform, since: Date())
        connection.send {
            $0.welcome.protocolVersion = .current
            $0.welcome.serverName = Host.current().localizedName ?? ""
            $0.welcome.connectionToken = token
        }
        bridge.clientConnected(connection)
    }

    /// The current client is gone (closed, replaced or the server stopped).
    private func drop(_ connection: RemoteConnection) {
        guard connection === current else { return }
        bridge.clientDisconnected(connection)
        current = nil
        client = nil
    }

    /// A session's desktop notification, for the client.
    func notify(_ tab: TabSession, title: String, body: String) {
        bridge.notify(tab, title: title, body: body)
    }
}

/// One WebSocket client connection: framing and sending.
final class RemoteConnection {
    private let nw: NWConnection
    /// The way it came.
    let via: RemoteServer.Mode
    var onMessage: ((Remote.ClientMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    private var pingTimer: Timer?
    private var lastPong = Date()

    init(_ nw: NWConnection, via: RemoteServer.Mode) {
        self.nw = nw
        self.via = via
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        nw.start(queue: .main)
        receive()
        // A client that went away without closing (an iPhone suspended in the
        // background, a dropped network) stops answering pings.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPong) > 45 {
                self.close()
                return
            }
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            meta.setPongHandler(.main) { [weak self] error in
                if error == nil { self?.lastPong = Date() }
            }
            let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
            self.nw.send(content: Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    private func receive() {
        nw.receiveMessage { [weak self] content, context, _, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.finish()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close {
                self.finish()
                return
            }
            self.lastPong = Date()
            // Pings (answered on their own) and pongs carry payloads too.
            if meta?.opcode == .binary, let content, !content.isEmpty {
                if let msg = try? Remote.ClientMessage(serializedBytes: content) {
                    self.onMessage?(msg)
                } else {
                    self.fail(.badRequest, "Couldn't decode the message.")
                    return
                }
            }
            self.receive()
        }
    }

    func send(_ fill: (inout Remote.ServerMessage) -> Void) {
        var msg = Remote.ServerMessage()
        fill(&msg)
        send(msg)
    }

    /// Thread-safe; messages go out in the order they were sent.
    func send(_ msg: Remote.ServerMessage) {
        guard let data = try? msg.serializedData() else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        nw.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.close() } }
        })
    }

    /// Sends a connection-level error, then closes.
    func fail(_ code: Remote.ErrorCode, _ message: String) {
        send {
            $0.error.code = code
            $0.error.message = message
        }
        close()
    }

    func close() {
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        nw.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { [nw] _ in
            nw.cancel()
        })
        // In case the close frame never goes out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [nw] in nw.cancel() }
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        pingTimer?.invalidate()
        pingTimer = nil
        onClose?()
    }
}
