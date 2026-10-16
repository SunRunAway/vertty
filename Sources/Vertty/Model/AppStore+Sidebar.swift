import Foundation

extension TabSession: SessionCardModel {}

/// This Mac's sessions in the shared sidebar.
extension AppStore: SidebarStore {
    var features: SidebarFeatures { .local }
    var selectedCardID: UUID? { selectedTabID }

    func cards(of project: Project) -> [TabSession] { tabs(of: project) }
    func newSession(in project: Project, kind: AgentKind?) { newSession(in: Optional(project), kind: kind) }
    func query(for project: Project) -> String? { searchQuery[project.id] }

    func scheduleName(for card: TabSession) -> String? {
        (schedules.task(forSession: card.sessionID) ?? card.scheduleTaskID.flatMap(schedules.task))?.name
    }
    func addProject() { addProjectViaPanel() }
    func newScheduledTask(in project: Project) { newScheduledTask(in: Optional(project)) }
    func moveCard(_ id: UUID, before target: UUID) { moveTab(id, before: target) }
    func closeOthers(_ keep: TabSession) { closeOtherTabs(keep) }
    func directory(of card: TabSession) -> String? { card.cwd }
}

extension AppStore: SidebarLayoutModel {
    func sidebarResized() { scheduleSave() }
}
