import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's projects, cards and history, for this Mac's sessions or
/// another computer's. `header` goes above the project list (the window
/// controls and scheduled tasks locally; which computer it is remotely).
public struct SidebarView<Store: SidebarStore, Header: View>: View {
    @ObservedObject var store: Store
    let header: Header
    @State private var draggingProjectID: UUID?

    public init(store: Store, @ViewBuilder header: () -> Header) {
        self.store = store
        self.header = header()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(spacing: 6) {
                Text("Projects", bundle: .module)
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.features.contains(.manageProjects) {
                    IconButton(systemName: "plus", help: Text("Add Project (⇧⌘O)", bundle: .module)) { store.addProject() }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.projects) { project in
                        ProjectSection(store: store, project: project, draggingProjectID: $draggingProjectID)
                    }
                    if store.projects.isEmpty && store.projectsLoaded {
                        if store.features.contains(.manageProjects) {
                            Button { store.addProject() } label: {
                                Label { Text("Add Your First Project…", bundle: .module) } icon: { Image(systemName: "folder.badge.plus") }
                                    .font(.ui(13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                        } else {
                            Text("No projects on that computer yet. Add them there.", bundle: .module)
                                .font(.ui(12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        // Solid, opaque background: a behind-window blur makes WindowServer
        // re-composite the blur every time the terminal draws a frame.
        .background(SidebarView<Store, Header>.background)
    }

    public static var background: Color { Color(red: 0.118, green: 0.118, blue: 0.125) }
}

private struct ProjectSection<Store: SidebarStore>: View {
    @ObservedObject var store: Store
    let project: Project
    @Binding var draggingProjectID: UUID?
    @State private var draggingID: UUID?

    /// The typed prompt a session matches the search by, when its title or id doesn't.
    private func prompt(_ title: String, _ id: String) -> PromptSnippet? {
        let query = store.query(for: project) ?? ""
        return PromptSnippet.matches(query, title: title, sessionID: id) ? nil : store.promptMatch(project, sessionID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProjectRow(store: store, project: project, draggingID: $draggingProjectID)
            if project.expanded {
                let query = store.query(for: project)
                let searching = !(query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let open = store.cards(of: project).filter { store.isShown(project, title: $0.title, sessionID: $0.sessionID) }
                let closed = store.shownHistory(of: project)
                let visibleCount = searching ? closed.count : store.historyVisibleCount(for: project)

                if query != nil {
                    SessionSearchField(store: store, project: project)
                }

                ForEach(open) { card in
                    VStack(alignment: .leading, spacing: 2) {
                        SessionCard(card: card, store: store, draggingID: $draggingID)
                        if let snippet = prompt(card.title, card.sessionID) {
                            PromptSnippetLine(snippet: snippet)
                                .padding(.leading, Touch.size(27))
                        }
                    }
                }
                .padding(.leading, 6)

                if !closed.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if !open.isEmpty {
                            Text("Past Sessions", bundle: .module)
                                .font(.ui(11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 16)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                        }
                        ForEach(closed.prefix(visibleCount)) { summary in
                            HistoryRow(store: store, project: project, summary: summary,
                                       snippet: prompt(summary.title, summary.id))
                        }
                        if closed.count > visibleCount {
                            Button {
                                store.showMoreHistory(project)
                            } label: {
                                Text("Show More", bundle: .module)
                                    .font(.ui(12.5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 16)
                                    .padding(.vertical, 5)
                                    .tapHeight()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if searching && open.isEmpty && closed.isEmpty {
                    Text("No Matching Sessions", bundle: .module)
                        .font(.ui(12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                        .padding(.vertical, 5)
                } else if query == nil && open.isEmpty && closed.isEmpty {
                    Button { store.newSession(in: project, kind: nil) } label: {
                        Label { Text("New Session", bundle: .module) } icon: { Image(systemName: "plus") }
                            .font(.ui(12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                            .padding(.vertical, 5)
                            .tapHeight()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, project.expanded ? 10 : 0)
    }
}

private struct ProjectRow<Store: SidebarStore>: View {
    @ObservedObject var store: Store
    let project: Project
    @Binding var draggingID: UUID?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.expanded ? "folder" : "folder.fill")
                .font(.ui(13))
                .foregroundStyle(project.color)
                .frame(width: Touch.size(18))
            Text(project.name)
                .font(.ui(13.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                IconMenu { projectMenu }
                IconButton(systemName: "magnifyingglass", help: Text("Search Sessions", bundle: .module)) {
                    if store.query(for: project) != nil { store.closeSearch(project) } else { store.openSearch(project) }
                }
                IconButton(systemName: "square.and.pencil", help: Text(store.defaultKind(project).newSessionTitle)) {
                    store.newSession(in: project, kind: nil)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: Touch.row(30))
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.toggleExpanded(project) }
        .reorderable(store.features.contains(.reorder), id: project.id, dragging: $draggingID) { id in
            store.moveProject(id, before: project.id)
        }
        .help(project.path.abbreviatingHome)
        .contextMenu { projectMenu }
    }

    @ViewBuilder
    private var projectMenu: some View {
        ForEach(store.kindsDefaultFirst(project)) { kind in
            Button(kind.newSessionTitle) { store.newSession(in: project, kind: kind) }
        }
        Button { store.openSearch(project) } label: { Text("Search Sessions", bundle: .module) }
        if store.features.contains(.schedules) {
            Button { store.newScheduledTask(in: project) } label: { Text("New Scheduled Task…", bundle: .module) }
        }
        if store.features.contains(.defaultKindSetting) {
            Menu {
                ForEach(AgentKind.allCases) { kind in
                    Toggle(kind.name, isOn: Binding(
                        get: { store.defaultKind(project) == kind },
                        set: { if $0 { store.setDefaultKind(kind, for: project) } }))
                }
            } label: { Text("Set Default Session", bundle: .module) }
        }
        if store.features.contains(.localFiles) {
            Divider()
            Button { Platform.reveal(project.path) } label: { Text("Show in Finder", bundle: .module) }
            Button { Platform.copy(project.path) } label: { Text("Copy Path", bundle: .module) }
        }
        if store.features.contains(.manageProjects) {
            Divider()
            Button { store.renameProject(project) } label: { Text("Rename…", bundle: .module) }
            Button { store.changeProjectDirectory(project) } label: { Text("Change Directory…", bundle: .module) }
            Divider()
            Button { store.removeProject(project) } label: { Text("Remove Project…", bundle: .module) }
        }
    }
}

/// Filters a project's sessions by title, typed prompt or session id. Esc or ✕ closes it.
private struct SessionSearchField<Store: SidebarStore>: View {
    @ObservedObject var store: Store
    let project: Project
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(11))
                .foregroundStyle(.tertiary)
            TextField(text: Binding(
                get: { store.query(for: project) ?? "" },
                set: { store.setSearchQuery($0, for: project) }
            )) { Text("Title, Prompt or Session ID", bundle: .module) }
            .textFieldStyle(.plain)
            .font(.ui(12.5))
            .focused($focused)
            #if os(macOS)
            .onExitCommand { store.closeSearch(project) }
            #endif
            Button { store.closeSearch(project) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.ui(11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Close Search", bundle: .module))
        }
        .padding(.horizontal, 8)
        .frame(height: Touch.row(26))
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
        .padding(.leading, 6)
        .onAppear { focused = true }
    }
}

private struct HistoryRow<Store: SidebarStore>: View {
    @ObservedObject var store: Store
    let project: Project
    let summary: SessionSummary
    var snippet: PromptSnippet?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AgentIcon(kind: summary.kind, size: Touch.size(11))
                    .opacity(0.7)
                    .frame(width: Touch.size(14))
                Text(summary.title)
                    .font(.ui(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RelativeTime.short(summary.modified))
                    .font(.ui(11))
                    .foregroundStyle(.tertiary)
                    .opacity(hover ? 1 : 0.8)
            }
            .frame(height: Touch.row(27))
            if let snippet {
                PromptSnippetLine(snippet: snippet)
                    .padding(.leading, Touch.size(22))
                    .padding(.bottom, 5)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.resumeSession(summary, in: project) }
        .help(Text("Resume \(summary.kind.name) session: \(summary.title)", bundle: .module))
    }
}

/// The typed prompt a session matched a search with, the match in bold.
struct PromptSnippetLine: View {
    let snippet: PromptSnippet

    var body: some View {
        var match = AttributedString(snippet.match)
        match.font = .ui(11.5, weight: .semibold)
        match.foregroundColor = .secondary
        return Text(AttributedString(snippet.before) + match + AttributedString(snippet.after))
            .font(.ui(11.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(snippet.before + snippet.match + snippet.after)
    }
}

extension View {
    /// Drag to reorder (projects, cards), where the sidebar allows it.
    @ViewBuilder
    func reorderable(_ enabled: Bool, id: UUID, dragging: Binding<UUID?>, move: @escaping (UUID) -> Void) -> some View {
        if enabled {
            self
                .onDrag {
                    dragging.wrappedValue = id
                    return NSItemProvider(object: id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(target: id, dragging: dragging, move: move))
        } else {
            self
        }
    }
}

/// Moves the dragged row live as it passes over another one.
private struct ReorderDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let move: (UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != target else { return }
        withAnimation(.easeOut(duration: 0.12)) { move(id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

extension String {
    var abbreviatingHome: String {
        #if os(macOS)
        let home = NSHomeDirectory()
        if hasPrefix(home) { return "~" + dropFirst(home.count) }
        #endif
        return self
    }
}
