import Foundation
import SwiftUI

public struct Project: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var path: String
    public var expanded = true
    /// What ⌘T and the new-session button start here (the global default when unset).
    public var defaultKind: AgentKind?

    public init(id: UUID = UUID(), name: String, path: String, expanded: Bool = true, defaultKind: AgentKind? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.expanded = expanded
        self.defaultKind = defaultKind
    }

    public var color: Color { ProjectPalette.color(for: id) }
}

public enum ProjectPalette {
    public static let colors: [Color] = [
        Color(red: 0.55, green: 0.48, blue: 0.98), Color(red: 0.31, green: 0.72, blue: 0.96),
        Color(red: 0.98, green: 0.62, blue: 0.29), Color(red: 0.36, green: 0.82, blue: 0.55),
        Color(red: 0.95, green: 0.42, blue: 0.56), Color(red: 0.95, green: 0.80, blue: 0.30),
        Color(red: 0.42, green: 0.85, blue: 0.82), Color(red: 0.80, green: 0.55, blue: 0.95),
    ]

    public static func color(for id: UUID) -> Color {
        // FNV-1a over the UUID bytes: stable across launches (unlike hashValue).
        var h: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return colors[Int(h % UInt64(colors.count))]
    }
}

/// Which coding agent a session runs.
public enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }
    public var name: String { self == .claude ? "Claude" : "Codex" }

    public var newSessionTitle: String {
        self == .claude ? String(localized: "New Claude Session", bundle: .vhosttyUIResources)
            : String(localized: "New Codex Session", bundle: .vhosttyUIResources)
    }
}

public enum SessionStatus: String, Codable {
    case dormant     // restored from disk, the agent not started yet
    case starting
    case working
    case idle
    case needsInput
    case exited
}

/// A past session in a project's history.
public struct SessionSummary: Identifiable, Hashable {
    public let id: String          // session id
    public let title: String
    public let modified: Date
    /// Its transcript, on the computer that has it.
    public let path: URL?
    public var kind: AgentKind = .claude

    public init(id: String, title: String, modified: Date, path: URL? = nil, kind: AgentKind = .claude) {
        self.id = id
        self.title = title
        self.modified = modified
        self.path = path
        self.kind = kind
    }
}

/// One line of a prompt around the first case-insensitive match of a search query.
public struct PromptSnippet: Hashable {
    public let before: String
    public let match: String
    public let after: String

    public init(before: String, match: String, after: String) {
        self.before = before
        self.match = match
        self.after = after
    }

    public init?(_ text: String, query: String) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let range = line.range(of: query, options: .caseInsensitive, locale: .current) else { return nil }
        // Little context before the match, so the match stays visible in the narrow sidebar.
        let start = line.index(range.lowerBound, offsetBy: -10, limitedBy: line.startIndex) ?? line.startIndex
        before = (start > line.startIndex ? "…" : "") + line[start..<range.lowerBound]
        match = String(line[range])
        after = String(line[range.upperBound...].prefix(160))
    }

    /// Matches a session by title or session id, case-insensitively.
    public static func matches(_ query: String, title: String, sessionID: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || sessionID.localizedCaseInsensitiveContains(q)
    }
}
