import Foundation

/// Shorter names for the generated protocol messages (vhostty_remote.proto).
public enum Remote {
    public typealias ClientMessage = Vhostty_Remote_ClientMessage
    public typealias ServerMessage = Vhostty_Remote_ServerMessage
    public typealias Hello = Vhostty_Remote_Hello
    public typealias Welcome = Vhostty_Remote_Welcome
    public typealias Error = Vhostty_Remote_Error
    public typealias ErrorCode = Vhostty_Remote_ErrorCode
    public typealias Reply = Vhostty_Remote_Reply
    public typealias State = Vhostty_Remote_State
    public typealias Project = Vhostty_Remote_Project
    public typealias Card = Vhostty_Remote_Card
    public typealias ProjectHistory = Vhostty_Remote_ProjectHistory
    public typealias HistoryEntry = Vhostty_Remote_HistoryEntry
    public typealias AgentKind = Vhostty_Remote_AgentKind
    public typealias SessionStatus = Vhostty_Remote_SessionStatus
    public typealias ClientPlatform = Vhostty_Remote_ClientPlatform
    public typealias TerminalSize = Vhostty_Remote_TerminalSize
    public typealias Notification = Vhostty_Remote_Notification
    public typealias NewSession = Vhostty_Remote_NewSession
    public typealias ResumeSession = Vhostty_Remote_ResumeSession
    public typealias CloseSession = Vhostty_Remote_CloseSession
    public typealias ListHistory = Vhostty_Remote_ListHistory
    public typealias SearchHistory = Vhostty_Remote_SearchHistory
    public typealias SearchResult = Vhostty_Remote_SearchResult
    public typealias PromptMatch = Vhostty_Remote_PromptMatch

    /// The port a server listens on unless VHOSTTY_REMOTE_PORT says otherwise.
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
        case .incompatibleVersion: return String(localized: "This computer runs a Vhostty version that can't be used remotely from here. Update both to the same version.", bundle: .vhosttyRemoteResources)
        case .notFound: return String(localized: "It no longer exists on the computer.", bundle: .vhosttyRemoteResources)
        case .resumeFailed: return String(localized: "The session can't be resumed. Its history may have been removed.", bundle: .vhosttyRemoteResources)
        case .replaced: return String(localized: "Connected on another device.", bundle: .vhosttyRemoteResources)
        case .unspecified where self == .disconnected: return String(localized: "The connection was lost.", bundle: .vhosttyRemoteResources)
        default: return message.isEmpty ? String(localized: "Something went wrong.", bundle: .vhosttyRemoteResources) : message
        }
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
