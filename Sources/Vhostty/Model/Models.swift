import AppKit
import SwiftUI

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var expanded = true
    /// What ⌘T and the new-session button start here (AppStore.globalDefaultKind when unset).
    var defaultKind: AgentKind?

    var color: Color { ProjectPalette.color(for: id) }
}

enum ProjectPalette {
    static let colors: [Color] = [
        Color(red: 0.55, green: 0.48, blue: 0.98), Color(red: 0.31, green: 0.72, blue: 0.96),
        Color(red: 0.98, green: 0.62, blue: 0.29), Color(red: 0.36, green: 0.82, blue: 0.55),
        Color(red: 0.95, green: 0.42, blue: 0.56), Color(red: 0.95, green: 0.80, blue: 0.30),
        Color(red: 0.42, green: 0.85, blue: 0.82), Color(red: 0.80, green: 0.55, blue: 0.95),
    ]

    static func color(for id: UUID) -> Color {
        // FNV-1a over the UUID bytes: stable across launches (unlike hashValue).
        var h: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return colors[Int(h % UInt64(colors.count))]
    }
}

/// Which coding agent a session runs.
enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }

    var newSessionTitle: LocalizedStringKey {
        self == .claude ? "New Claude Session" : "New Codex Session"
    }
}

enum SessionStatus: String, Codable {
    case dormant     // restored from disk, Claude not started yet
    case starting
    case working
    case idle
    case needsInput
    case exited
}

/// One session card = one terminal running Claude Code or Codex (+ an optional bottom shell).
final class TabSession: ObservableObject, Identifiable {
    let id: UUID
    let projectID: UUID

    @Published var kind: AgentKind
    /// Empty for a new Codex session until Codex has saved its thread (see codexThreadID).
    @Published var sessionID: String
    @Published var title: String
    @Published var branch: String?
    @Published var worktree: String?
    @Published var prNumber: Int?
    @Published var prURL: String?
    @Published var prState: String?
    @Published var status: SessionStatus
    @Published var attention = false
    /// Whether the bottom shell panel is shown for this session.
    @Published var shellVisible = false

    var cwd: String
    /// Where Claude is effectively working (hook cwd, corrected for worktrees).
    var workDir: String?
    var transcriptPath: String?
    var terminalTitle: String?
    /// Whether Claude's last terminal title carried its working spinner.
    var titleBusy = false
    var transcript: TranscriptInfo?
    var hooksActive = false
    /// The thread Codex shows in its terminal title: its id, or the first part of
    /// it. Codex only saves a thread once its first message is sent; once it's saved,
    /// its full id becomes sessionID.
    var codexThreadID: String?
    var surface: TerminalSurfaceView?
    /// The scheduled task that started this card (shown with a clock).
    @Published var scheduleTaskID: UUID?
    /// The scheduled run going on in this card's current process, if any.
    var scheduleRunID: UUID?
    /// When the card's current process was started.
    var launchedAt: Date?

    /// The bottom shell panel's terminal (created on first ⌘J).
    var shellSurface: TerminalSurfaceView?
    /// Last known working directory of the bottom shell.
    var shellCwd: String?
    /// Which pane had keyboard focus last, restored when switching back.
    var shellFocused = false

    var isLaunched: Bool { surface != nil }

    init(id: UUID = UUID(), projectID: UUID, kind: AgentKind = .claude, sessionID: String, cwd: String,
         title: String = String(localized: "New Session"), status: SessionStatus = .starting) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.status = status
    }

    var record: TabRecord {
        TabRecord(id: id, projectID: projectID, kind: kind, sessionID: sessionID, title: title, cwd: cwd,
                  branch: branch, worktree: worktree, prNumber: prNumber, prURL: prURL, prState: prState,
                  shellOpen: shellVisible, shellCwd: shellCwd, scheduleTaskID: scheduleTaskID)
    }

    convenience init(record r: TabRecord) {
        self.init(id: r.id, projectID: r.projectID, kind: r.kind ?? .claude, sessionID: r.sessionID, cwd: r.cwd, title: r.title, status: .dormant)
        branch = r.branch
        worktree = r.worktree
        prNumber = r.prNumber
        prURL = r.prURL
        prState = r.prState
        shellVisible = r.shellOpen ?? false
        shellCwd = r.shellCwd
        scheduleTaskID = r.scheduleTaskID
    }
}

struct TabRecord: Codable {
    var id: UUID
    var projectID: UUID
    var kind: AgentKind?
    var sessionID: String
    var title: String
    var cwd: String
    var branch: String?
    var worktree: String?
    var prNumber: Int?
    var prURL: String?
    var prState: String?
    var shellOpen: Bool?
    var shellCwd: String?
    var scheduleTaskID: UUID?
}

struct PersistedState: Codable {
    var projects: [Project] = []
    var tabs: [TabRecord] = []
    var selectedTabID: UUID?
    var lastProjectID: UUID?
    var detectedKind: AgentKind?
    var sidebarWidth: Double?
    var sidebarVisible: Bool?
    var shellFraction: Double?
}
