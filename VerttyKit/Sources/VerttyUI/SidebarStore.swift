import Foundation

/// A session card's data, as the sidebar shows it. Local sessions and a
/// remote computer's cards both provide it.
public protocol SessionCardModel: ObservableObject, Identifiable where ID == UUID {
    var projectID: UUID { get }
    var kind: AgentKind { get }
    var sessionID: String { get }
    var title: String { get }
    var branch: String? { get }
    var worktree: String? { get }
    var prNumber: Int? { get }
    var prURL: String? { get }
    var prState: String? { get }
    var status: SessionStatus { get }
    /// Finished in the background and not looked at yet (the blue dot).
    var attention: Bool { get }
}

/// What the sidebar offers besides browsing, starting, resuming and closing
/// sessions. A remote computer offers none of these (see
/// docs/spec/remote-client-product.md).
public struct SidebarFeatures: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Add, rename, move and remove projects.
    public static let manageProjects = SidebarFeatures(rawValue: 1 << 0)
    /// Drag projects and cards to reorder them.
    public static let reorder = SidebarFeatures(rawValue: 1 << 1)
    /// Scheduled tasks.
    public static let schedules = SidebarFeatures(rawValue: 1 << 2)
    /// Pick a project's default session kind.
    public static let defaultKindSetting = SidebarFeatures(rawValue: 1 << 3)
    /// Show directories in Finder and copy their paths (they're on this Mac).
    public static let localFiles = SidebarFeatures(rawValue: 1 << 4)
    /// Close every other session.
    public static let closeOthers = SidebarFeatures(rawValue: 1 << 5)

    public static let local: SidebarFeatures = [.manageProjects, .reorder, .schedules, .defaultKindSetting, .localFiles, .closeOthers]
}

/// Everything the sidebar shows and does: this Mac's sessions (AppStore) or
/// another computer's (RemoteStore).
public protocol SidebarStore: ObservableObject {
    associatedtype Card: SessionCardModel

    var features: SidebarFeatures { get }
    /// False until the projects are known (a remote computer's arrive later).
    var projectsLoaded: Bool { get }
    var projects: [Project] { get }
    var selectedCardID: UUID? { get }

    func cards(of project: Project) -> [Card]
    func toggleExpanded(_ project: Project)
    func defaultKind(_ project: Project) -> AgentKind
    func kindsDefaultFirst(_ project: Project) -> [AgentKind]

    func select(_ card: Card)
    func newSession(in project: Project, kind: AgentKind?)
    func resumeSession(_ summary: SessionSummary, in project: Project)
    /// Closes a card, asking first when its program still runs.
    func requestClose(_ card: Card)

    /// Past sessions not open in a card (all of them while searching).
    func closedHistory(for project: Project) -> [SessionSummary]
    func historyVisibleCount(for project: Project) -> Int
    func showMoreHistory(_ project: Project)

    /// The project's search text; nil while it isn't searching.
    func query(for project: Project) -> String?
    func openSearch(_ project: Project)
    func closeSearch(_ project: Project)
    func setSearchQuery(_ query: String, for project: Project)
    /// The typed prompt `sessionID` matched the project's query with, if any.
    func promptMatch(_ project: Project, sessionID: String) -> PromptSnippet?

    // Only with the matching feature.
    func scheduleName(for card: Card) -> String?
    func addProject()
    func renameProject(_ project: Project)
    func changeProjectDirectory(_ project: Project)
    func removeProject(_ project: Project)
    func setDefaultKind(_ kind: AgentKind, for project: Project)
    func newScheduledTask(in project: Project)
    func moveProject(_ id: UUID, before target: UUID)
    func moveCard(_ id: UUID, before target: UUID)
    func closeOthers(_ keep: Card)
    func directory(of card: Card) -> String?
}

public extension SidebarStore {
    var projectsLoaded: Bool { true }
    func scheduleName(for card: Card) -> String? { nil }
    func addProject() {}
    func renameProject(_ project: Project) {}
    func changeProjectDirectory(_ project: Project) {}
    func removeProject(_ project: Project) {}
    func setDefaultKind(_ kind: AgentKind, for project: Project) {}
    func newScheduledTask(in project: Project) {}
    func moveProject(_ id: UUID, before target: UUID) {}
    func moveCard(_ id: UUID, before target: UUID) {}
    func closeOthers(_ keep: Card) {}
    func directory(of card: Card) -> String? { nil }
}

public extension SidebarStore {
    /// Whether a session passes the project's search (always, when not searching).
    func isShown(_ project: Project, title: String, sessionID: String) -> Bool {
        PromptSnippet.matches(query(for: project) ?? "", title: title, sessionID: sessionID)
            || promptMatch(project, sessionID: sessionID) != nil
    }

    /// The project's past sessions the sidebar lists: those passing the search.
    func shownHistory(of project: Project) -> [SessionSummary] {
        closedHistory(for: project).filter { isShown(project, title: $0.title, sessionID: $0.id) }
    }
}
