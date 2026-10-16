import Foundation

/// Shorter names for the generated protocol messages (vertty_remote.proto).
public enum Remote {
    public typealias ClientMessage = Vertty_Remote_ClientMessage
    public typealias ServerMessage = Vertty_Remote_ServerMessage
    public typealias Hello = Vertty_Remote_Hello
    public typealias Welcome = Vertty_Remote_Welcome
    public typealias Error = Vertty_Remote_Error
    public typealias ErrorCode = Vertty_Remote_ErrorCode
    public typealias Reply = Vertty_Remote_Reply
    public typealias State = Vertty_Remote_State
    public typealias Project = Vertty_Remote_Project
    public typealias Card = Vertty_Remote_Card
    public typealias ProjectHistory = Vertty_Remote_ProjectHistory
    public typealias HistoryEntry = Vertty_Remote_HistoryEntry
    public typealias AgentKind = Vertty_Remote_AgentKind
    public typealias SessionStatus = Vertty_Remote_SessionStatus
    public typealias ClientPlatform = Vertty_Remote_ClientPlatform
    public typealias TerminalSize = Vertty_Remote_TerminalSize
    public typealias Notification = Vertty_Remote_Notification
    public typealias NewSession = Vertty_Remote_NewSession
    public typealias ResumeSession = Vertty_Remote_ResumeSession
    public typealias CloseSession = Vertty_Remote_CloseSession
    public typealias ListHistory = Vertty_Remote_ListHistory
    public typealias SearchHistory = Vertty_Remote_SearchHistory
    public typealias SearchResult = Vertty_Remote_SearchResult
    public typealias PromptMatch = Vertty_Remote_PromptMatch

    /// The port a server listens on unless VERTTY_REMOTE_PORT says otherwise.
    public static let defaultPort: UInt16 = 58563

    /// Most rows of scrollback a snapshot carries.
    public static let snapshotHistoryRows: UInt32 = 1000

    /// Largest frame either side accepts (a snapshot with its scrollback).
    public static let maxFrameSize = 64 << 20
}

public extension Remote.TerminalSize {
    init(columns: Int, rows: Int) {
        self.init()
        self.columns = UInt32(max(columns, 1))
        self.rows = UInt32(max(rows, 1))
    }
}

/// A failed request, or the reason a connection was refused.
public struct RemoteError: Swift.Error, LocalizedError, Equatable {
    public let code: Remote.ErrorCode
    public let message: String

    public init(code: Remote.ErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ error: Remote.Error) {
        self.init(code: error.code, message: error.message)
    }

    /// Connection dropped before the reply arrived.
    public static let disconnected = RemoteError(code: .unspecified, message: "Disconnected")

    public var errorDescription: String? {
        switch code {
        case .incompatibleVersion: return String(localized: "This computer runs a Vertty version that can't be used remotely from here. Update both to the same version.", bundle: .verttyRemoteResources)
        case .notFound: return String(localized: "It no longer exists on the computer.", bundle: .verttyRemoteResources)
        case .resumeFailed: return String(localized: "The session can't be resumed. Its history may have been removed.", bundle: .verttyRemoteResources)
        case .replaced: return String(localized: "Connected on another device.", bundle: .verttyRemoteResources)
        case .unspecified where self == .disconnected: return String(localized: "The connection was lost.", bundle: .verttyRemoteResources)
        default: return message.isEmpty ? String(localized: "Something went wrong.", bundle: .verttyRemoteResources) : message
        }
    }
}

/// Where a RemoteClient connects: an address the user typed, or a computer
/// found another way (Tailscale), whose URL is worked out for each attempt.
public struct RemoteEndpoint {
    /// The computer's name until the server tells it.
    public let name: String
    /// How it's reached, for a tooltip.
    public let detail: String
    /// What to tell the user when the computer doesn't answer.
    public let unreachable: String
    /// The WebSocket URL to connect to now; its error's description is
    /// shown to the user.
    public let resolve: @MainActor () async throws -> URL

    public init(name: String, detail: String, unreachable: String, resolve: @escaping @MainActor () async throws -> URL) {
        self.name = name
        self.detail = detail
        self.unreachable = unreachable
        self.resolve = resolve
    }

    /// An address the user typed (see remoteURL(from:)).
    public static func url(_ url: URL) -> RemoteEndpoint {
        RemoteEndpoint(name: url.host ?? "", detail: url.absoluteString,
                       unreachable: String(localized: "Can't reach the computer. Check the address and that remote connections are allowed in Vertty there.", bundle: .verttyRemoteResources)) { url }
    }
}

/// Turns what the user typed into a WebSocket URL: adds ws:// and the
/// default port when they're missing.
public func remoteURL(from input: String) -> URL? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "ws://" + text }
    guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else { return nil }
    switch parts.scheme?.lowercased() {
    case "http": parts.scheme = "ws"
    case "https": parts.scheme = "wss"
    case "ws", "wss": break
    default: return nil
    }
    if parts.port == nil { parts.port = Int(Remote.defaultPort) }
    return parts.url
}
