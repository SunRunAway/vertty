import AppKit
import SwiftUI

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
    /// Whether Claude has ended its turn with a background shell command still running.
    var backgroundShell = false
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
                  shellOpen: shellVisible, shellCwd: shellCwd, scheduleTaskID: scheduleTaskID,
                  unread: attention ? true : nil)
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
        // Unread survives a restart; a question it was waiting on doesn't (the
        // process ended), so it comes back as unread, not as needing input.
        attention = r.unread ?? false
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
    /// The unread marker (TabSession.attention).
    var unread: Bool?
}

struct PersistedState: Codable {
    var projects: [Project] = []
    var tabs: [TabRecord] = []
    var selectedTabID: UUID?
    var lastProjectID: UUID?
    var detectedKind: AgentKind?
    var newProjectKind: AgentKind?
    var sidebarWidth: Double?
    var sidebarVisible: Bool?
    var shellFraction: Double?
}
