import AppKit
import Network
import VerttyRemote
import VerttyTailnet

/// Serves remote clients (the iPhone app, Vertty on another Mac) over one
/// WebSocket per client; see VerttyKit/Proto/vertty_remote.proto. Off unless
/// one of the ways under "Allow Remote Connections" is checked:
/// - Via Tailscale: on the embedded Tailscale device (VerttyTailnet), which
///   forwards the same user's connections to a port on 127.0.0.1;
/// - Own Network: on the port on every interface.
/// Keeps one client at a time: a new one replaces the previous connection.
final class RemoteServer: ObservableObject {
    /// Present while remote connections are allowed; holds the Mode (empty
    /// means Own Network, from before there was a choice).
    static var enabledMarker: URL { AppPaths.support.appendingPathComponent("remote-enabled") }

    enum Mode: String {
        case tailscale
        case direct
    }

    enum Status: Equatable {
        case off
        case starting(UInt16)
        case listening(UInt16)
        /// Serving on the tailnet (Tailnet.shared has the details).
        case tailnet
        /// Couldn't start; the reason is shown under the menu item.
        case failed(String)
    }

    struct ClientInfo: Equatable {
        let deviceName: String
        let platform: Remote.ClientPlatform
        let since: Date
    }

    @Published private(set) var status: Status = .off
    /// The connected client, if any.
    @Published private(set) var client: ClientInfo?

    /// The checked way, nil while remote connections are off.
    var mode: Mode? {
        guard let data = FileManager.default.contents(atPath: Self.enabledMarker.path) else { return nil }
        return Mode(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? .direct
    }

    private let store: AppStore
    private var listener: NWListener?
    /// Connections that haven't sent Hello yet.
    private var greeting: [ObjectIdentifier: RemoteConnection] = [:]
    private var current: RemoteConnection?
    /// Holding the Tailscale device (Tailnet.use()).
    private var usingTailnet = false
    /// Token of the last client accepted (see ONE CLIENT AT A TIME).
    private var currentToken: String?
    private lazy var bridge = RemoteBridge(store: store, server: self)

    init(store: AppStore) {
        self.store = store
    }

    /// The menu's choice: a way, or nil for off. Choosing Tailscale opens
    /// its sign-in page if this Mac isn't signed in.
    func setMode(_ mode: Mode?) {
        if let mode {
            FileManager.default.createFile(atPath: Self.enabledMarker.path, contents: Data(mode.rawValue.utf8))
            start()
            if mode == .tailscale, Tailnet.shared.state != .running {
                TailscaleSignIn.shared.start()
            }
        } else {
            try? FileManager.default.removeItem(at: Self.enabledMarker)
            stop()
        }
    }

    /// Starts listening if enabled (at launch, once the shell's environment
    /// with VERTTY_REMOTE_PORT is known).
    func startIfEnabled() {
        if mode != nil { start() }
    }

    private func start() {
        stop()
        guard let mode else { return }
        let port: UInt16
        if mode == .tailscale {
            // Any free port: only the Tailscale device connects to it.
            port = 0
        } else {
            switch Self.configuredPort() {
            case .success(let p): port = p
            case .failure(let reason):
                status = .failed(reason.message)
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
            status = .failed(error.localizedDescription)
            return
        }
        self.listener = listener
        status = .starting(port)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready where mode == .tailscale:
                guard let local = listener.port?.rawValue else { return }
                self.status = .tailnet
                self.usingTailnet = true
                Tailnet.shared.use()
                Tailnet.shared.serve(port: Remote.defaultPort, to: local) { [weak self] reason in
                    guard let self, self.listener === listener else { return }
                    self.status = .failed(reason)
                }
            case .ready:
                self.status = .listening(port)
            case .failed(let error):
                // No retry: the reason stays under the menu item.
                self.status = .failed(Self.describe(error))
                listener.cancel()
                self.listener = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .main)
    }

    private func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        if usingTailnet {
            usingTailnet = false
            Tailnet.shared.stopServing()
            Tailnet.shared.endUse()
        }
        for c in greeting.values { c.close() }
        greeting = [:]
        if let current {
            drop(current)
            current.close()
        }
        status = .off
    }

    private struct PortError: Error { let message: String }

    /// VERTTY_REMOTE_PORT from the login shell, else the default.
    private static func configuredPort() -> Result<UInt16, PortError> {
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

    private func accept(_ nw: NWConnection) {
        let connection = RemoteConnection(nw)
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
    var onMessage: ((Remote.ClientMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    private var pingTimer: Timer?
    private var lastPong = Date()

    init(_ nw: NWConnection) {
        self.nw = nw
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
