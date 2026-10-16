import Foundation
import os

/// Why a shared session's size changed, and the connection around it, on
/// either end: the unified log (subsystem dev.vertty, category remote-size),
/// and `sink` (the iPhone app keeps a file).
public enum RemoteLog {
    public static var sink: ((String) -> Void)?
    private static let logger = Logger(subsystem: "dev.vertty", category: "remote-size")

    public static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        sink?(message)
    }
}

public extension Remote.TerminalSize {
    var text: String { "\(columns)x\(rows)" }
}
