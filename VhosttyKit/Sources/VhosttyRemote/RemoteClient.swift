import Foundation
import SwiftProtobuf

/// Receives the stream of the terminal a client opened, on the main thread.
public protocol RemoteTerminalSink: AnyObject {
    /// Reset the terminal to `columns` x `rows`, then replay `data`.
    func remoteSnapshot(cardID: String, columns: Int, rows: Int, data: Data)
    /// More of what the program wrote.
    func remoteOutput(cardID: String, data: Data)
    func remoteTerminalClosed(cardID: String)
}

/// One connection to a Vhostty server (see vhostty_remote.proto): the latest
/// State, requests, and the terminal the user is looking at. Reconnects on
/// its own after a dropped connection, unless another device took over.
/// Use it on the main thread only; the async requests run there too.
public final class RemoteClient: ObservableObject {
    public enum Status: Equatable {
        /// Connecting because the user asked to.
        case connecting
        case connected
        /// The connection dropped; trying again on its own.
        case reconnecting
        /// Another device connected to the computer. Stays this way until
        /// the user connects again.
        case replaced
        /// Couldn't connect, or the server refused (message for the user).
        case failed(String)
        /// Closed by the user.
        case closed
    }

    @Published public private(set) var status: Status = .closed
    /// The latest State; empty until the first one arrives.
    @Published public private(set) var state = Remote.State()
    @Published public private(set) var hasState = false
    @Published public private(set) var serverName = ""

    public let url: URL
    public weak var terminalSink: RemoteTerminalSink?
    public var onNotification: ((Remote.Notification) -> Void)?

    /// Off while the iPhone app is in the background: a dropped connection
    /// waits for resumeIfDropped().
    public var reconnectsAutomatically = true {
        didSet { if reconnectsAutomatically { resumeIfDropped() } else { cancelRetry() } }
    }

    private let platform: Remote.ClientPlatform
    private let deviceName: String
    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    /// Bumped per connection attempt, so callbacks of an old one are ignored.
    private var generation = 0
    private var welcomed = false
    /// From the last Welcome; sent back when reconnecting on our own.
    private var token: String?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Remote.Reply, Swift.Error>] = [:]
    /// The terminal on screen, opened again after reconnecting.
    private var openCard: (id: String, size: Remote.TerminalSize)?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var pingTimer: Timer?

    public init(url: URL, platform: Remote.ClientPlatform, deviceName: String) {
        self.url = url
        self.platform = platform
        self.deviceName = deviceName
    }

    // MARK: - Connection

    /// Connects because the user asked to: takes over from any other device.
    public func connect() {
        token = nil
        status = .connecting
        start()
    }

    /// Closes the connection for good (the user disconnected).
    public func disconnect() {
        cancelRetry()
        stop()
        status = .closed
    }

    /// Reconnects right away if the connection dropped (the iPhone app came
    /// back to the foreground). Does nothing after another device took over.
    public func resumeIfDropped() {
        guard status == .reconnecting else { return }
        cancelRetry()
        start()
    }

    private func start() {
        stop()
        generation += 1
        let gen = generation
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = Remote.maxFrameSize
        self.task = task
        task.resume()
        receive(task, gen)

        var hello = Remote.Hello()
        hello.protocolVersion = .current
        hello.platform = platform
        hello.deviceName = deviceName
        if let token { hello.reconnectToken = token }
        var msg = Remote.ClientMessage()
        msg.hello = hello
        send(msg)

        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.task?.sendPing { error in
                guard error != nil else { return }
                DispatchQueue.main.async { self.dropped(gen) }
            }
        }
    }

    private func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        welcomed = false
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: RemoteError.disconnected) }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                switch result {
                case .failure:
                    self.dropped(gen)
                case .success(let message):
                    if case .data(let data) = message, let msg = try? Remote.ServerMessage(serializedBytes: data) {
                        self.handle(msg)
                    }
                    if self.generation == gen { self.receive(task, gen) }
                }
            }
        }
    }

    /// The connection is gone without the server saying why.
    private func dropped(_ gen: Int) {
        guard gen == generation else { return }
        let wasConnecting = status == .connecting
        stop()
        if wasConnecting {
            status = .failed(String(localized: "Can't reach the computer. Check the address and that remote connections are allowed in Vhostty there.", bundle: .module))
            return
        }
        guard status == .connected || status == .reconnecting else { return }
        status = .reconnecting
        scheduleRetry()
    }

    private func scheduleRetry() {
        cancelRetry()
        guard reconnectsAutomatically else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == .reconnecting else { return }
            self.start()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 10)
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
    }

    // MARK: - Incoming

    private func handle(_ msg: Remote.ServerMessage) {
        switch msg.body {
        case .welcome(let welcome):
            welcomed = true
            token = welcome.connectionToken
            serverName = welcome.serverName
            status = .connected
            retryDelay = 1
            if let open = openCard { sendOpen(open.id, open.size) }
        case .state(let state):
            self.state = state
            hasState = true
        case .reply(let reply):
            pending.removeValue(forKey: reply.requestID)?.resume(returning: reply)
        case .snapshot(let s):
            terminalSink?.remoteSnapshot(cardID: s.cardID, columns: Int(s.size.columns), rows: Int(s.size.rows), data: s.data)
        case .output(let o):
            terminalSink?.remoteOutput(cardID: o.cardID, data: o.data)
        case .terminalClosed(let c):
            if openCard?.id == c.cardID { openCard = nil }
            terminalSink?.remoteTerminalClosed(cardID: c.cardID)
        case .notification(let n):
            onNotification?(n)
        case .replaced:
            cancelRetry()
            stop()
            status = .replaced
        case .error(let error):
            cancelRetry()
            stop()
            status = error.code == .replaced ? .replaced : .failed(RemoteError(error).localizedDescription)
        case nil:
            break
        }
    }

    // MARK: - Outgoing

    private func send(_ msg: Remote.ClientMessage) {
        guard let task, let data = try? msg.serializedData() else { return }
        let gen = generation
        task.send(.data(data)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.dropped(gen) }
        }
    }

    @MainActor
    private func request(_ fill: (inout Remote.ClientMessage) -> Void) async throws -> Remote.Reply {
        guard status == .connected, welcomed else { throw RemoteError.disconnected }
        var msg = Remote.ClientMessage()
        msg.requestID = nextRequestID
        nextRequestID += 1
        fill(&msg)
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[msg.requestID] = continuation
            send(msg)
        }
        if reply.hasError { throw RemoteError(reply.error) }
        return reply
    }

    /// Starts a session; returns its card. Retrying with the same
    /// operation id never creates a second one.
    @MainActor
    public func newSession(projectID: String, kind: Remote.AgentKind?, operationID: String) async throws -> String {
        try await request {
            $0.newSession.projectID = projectID
            if let kind { $0.newSession.kind = kind }
            $0.newSession.operationID = operationID
        }.session.cardID
    }

    /// Opens a session from the history (or finds the card it's open in).
    @MainActor
    public func resumeSession(projectID: String, entry: Remote.HistoryEntry) async throws -> String {
        try await request {
            $0.resumeSession.projectID = projectID
            $0.resumeSession.sessionID = entry.sessionID
            $0.resumeSession.kind = entry.kind
        }.session.cardID
    }

    @MainActor
    public func closeSession(cardID: String, confirmed: Bool) async throws {
        _ = try await request {
            $0.closeSession.cardID = cardID
            $0.closeSession.confirmed = confirmed
        }
    }

    @MainActor
    public func listHistory(projectID: String, limit: Int) async throws -> Remote.ProjectHistory {
        try await request {
            $0.listHistory.projectID = projectID
            $0.listHistory.limit = UInt32(limit)
        }.history
    }

    /// A project's closed sessions and the prompts matching `query` (see
    /// SearchHistory).
    @MainActor
    public func searchHistory(projectID: String, query: String) async throws -> Remote.SearchResult {
        try await request {
            $0.searchHistory.projectID = projectID
            $0.searchHistory.query = query
        }.search
    }

    // MARK: - Terminal

    /// Shows a card's terminal at `size`; the snapshot and output go to
    /// terminalSink.
    public func openTerminal(cardID: String, size: Remote.TerminalSize) {
        if let open = openCard, open.id != cardID { leaveTerminal() }
        openCard = (cardID, size)
        if status == .connected, welcomed { sendOpen(cardID, size) }
    }

    private func sendOpen(_ cardID: String, _ size: Remote.TerminalSize) {
        var msg = Remote.ClientMessage()
        msg.openTerminal.cardID = cardID
        msg.openTerminal.size = size
        send(msg)
    }

    public func leaveTerminal() {
        guard let open = openCard else { return }
        openCard = nil
        var msg = Remote.ClientMessage()
        msg.leaveTerminal.cardID = open.id
        send(msg)
    }

    /// The display area changed or the app came back to the foreground.
    public func viewportChanged(_ size: Remote.TerminalSize) {
        guard let open = openCard else { return }
        openCard = (open.id, size)
        var msg = Remote.ClientMessage()
        msg.viewport.cardID = open.id
        msg.viewport.size = size
        send(msg)
    }

    /// Call when the user types or pastes, before the terminal encodes it.
    public func alignForInput(_ size: Remote.TerminalSize) {
        guard let open = openCard else { return }
        openCard = (open.id, size)
        var msg = Remote.ClientMessage()
        msg.alignForInput.cardID = open.id
        msg.alignForInput.size = size
        send(msg)
    }

    /// Bytes the terminal wrote (keys, paste, mouse) for the open card.
    public func input(_ data: Data) {
        guard let open = openCard, !data.isEmpty else { return }
        var msg = Remote.ClientMessage()
        msg.input.cardID = open.id
        msg.input.data = data
        send(msg)
    }

    /// The card whose terminal is open.
    public var openCardID: String? { openCard?.id }
}
