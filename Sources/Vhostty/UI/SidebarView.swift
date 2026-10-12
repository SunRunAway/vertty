import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // traffic lights
                .background(WindowDragArea())

            HStack(spacing: 6) {
                Text("Projects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(systemName: "plus", help: "Add Project (⇧⌘O)") { store.addProjectViaPanel() }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.projects) { project in
                        ProjectSection(store: store, project: project)
                    }
                    if store.projects.isEmpty {
                        Button { store.addProjectViaPanel() } label: {
                            Label("Add Your First Project…", systemImage: "folder.badge.plus")
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        // Solid, opaque background: a behind-window blur makes WindowServer
        // re-composite the blur every time the terminal draws a frame.
        .background(Color(red: 0.118, green: 0.118, blue: 0.125))
    }
}

private struct ProjectSection: View {
    @ObservedObject var store: AppStore
    let project: Project
    @State private var draggingID: UUID?

    /// The typed prompt a session matches the search by, when its title or id doesn't.
    private func prompt(_ title: String, _ id: String) -> PromptSnippet? {
        let query = store.searchQuery[project.id] ?? ""
        return AppStore.matches(query, title: title, sessionID: id) ? nil : store.promptMatch(project, sessionID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProjectRow(store: store, project: project)
            if project.expanded {
                let query = store.searchQuery[project.id]
                let searching = !(query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let open = store.tabs(of: project).filter {
                    AppStore.matches(query ?? "", title: $0.title, sessionID: $0.sessionID) || store.promptMatch(project, sessionID: $0.sessionID) != nil
                }
                let closed = store.closedHistory(for: project).filter {
                    AppStore.matches(query ?? "", title: $0.title, sessionID: $0.id) || store.promptMatch(project, sessionID: $0.id) != nil
                }
                let visibleCount = searching ? closed.count : store.historyVisibleCount(for: project)

                if query != nil {
                    SessionSearchField(store: store, project: project)
                }

                ForEach(open) { tab in
                    VStack(alignment: .leading, spacing: 2) {
                        SessionCard(tab: tab, store: store, draggingID: $draggingID)
                        if let snippet = prompt(tab.title, tab.sessionID) {
                            PromptSnippetLine(snippet: snippet)
                                .padding(.leading, 27)
                        }
                    }
                }
                .padding(.leading, 6)

                if !closed.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if !open.isEmpty {
                            Text("Past Sessions")
                                .font(.system(size: 11, weight: .medium))
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
                                Text("Show More")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 16)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if searching && open.isEmpty && closed.isEmpty {
                    Text("No Matching Sessions")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                        .padding(.vertical, 5)
                } else if query == nil && open.isEmpty && closed.isEmpty {
                    Button { store.newSession(in: project) } label: {
                        Label("New Session", systemImage: "plus")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                            .padding(.vertical, 5)
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

private struct ProjectRow: View {
    @ObservedObject var store: AppStore
    let project: Project
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.expanded ? "folder" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(project.color)
                .frame(width: 18)
            Text(project.name)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                Menu {
                    projectMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                IconButton(systemName: "magnifyingglass", help: "Search Sessions") {
                    if store.searchQuery[project.id] != nil { store.closeSearch(project) } else { store.openSearch(project) }
                }
                IconButton(systemName: "square.and.pencil", help: store.defaultKind(project).newSessionTitle) {
                    store.newSession(in: project)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.toggleExpanded(project) }
        .help(project.path.abbreviatingHome)
        .contextMenu { projectMenu }
    }

    @ViewBuilder
    private var projectMenu: some View {
        ForEach(store.kindsDefaultFirst(project)) { kind in
            Button(kind.newSessionTitle) { store.newSession(in: project, kind: kind) }
        }
        Button("Search Sessions") { store.openSearch(project) }
        Menu("Set Default Session") {
            ForEach(AgentKind.allCases) { kind in
                Toggle(kind.name, isOn: Binding(
                    get: { store.defaultKind(project) == kind },
                    set: { if $0 { store.setDefaultKind(kind, for: project) } }))
            }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename…") { store.renameProject(project) }
        Button("Change Directory…") { store.changeProjectDirectory(project) }
        Divider()
        Button("Remove Project…") { store.removeProject(project) }
    }
}

/// Filters a project's sessions by title, typed prompt or session id. Esc or ✕ closes it.
private struct SessionSearchField: View {
    @ObservedObject var store: AppStore
    let project: Project
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Title, Prompt or Session ID", text: Binding(
                get: { store.searchQuery[project.id] ?? "" },
                set: { store.setSearchQuery($0, for: project) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .onExitCommand { store.closeSearch(project) }
            Button { store.closeSearch(project) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Search")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
        .padding(.leading, 6)
        .onAppear { focused = true }
    }
}

private struct HistoryRow: View {
    @ObservedObject var store: AppStore
    let project: Project
    let summary: SessionSummary
    var snippet: PromptSnippet?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AgentIcon(kind: summary.kind, size: 11)
                    .opacity(0.7)
                    .frame(width: 14)
                Text(summary.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RelativeTime.short(summary.modified))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .opacity(hover ? 1 : 0.8)
            }
            .frame(height: 27)
            if let snippet {
                PromptSnippetLine(snippet: snippet)
                    .padding(.leading, 22)
                    .padding(.bottom, 5)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.resumeSession(summary, in: project) }
        .help("Resume \(summary.kind.name) session: \(summary.title)")
    }
}

/// The typed prompt a session matched a search with, the match in bold.
private struct PromptSnippetLine: View {
    let snippet: PromptSnippet

    var body: some View {
        var match = AttributedString(snippet.match)
        match.font = .system(size: 11.5, weight: .semibold)
        match.foregroundColor = .secondary
        return Text(AttributedString(snippet.before) + match + AttributedString(snippet.after))
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(snippet.before + snippet.match + snippet.after)
    }
}

struct IconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    /// Drawn brighter while what it toggles is on.
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

enum RelativeTime {
    static func short(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        switch s {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(s / 60))m")
        case ..<86400: return String(localized: "\(Int(s / 3600))h")
        case ..<(86400 * 30): return String(localized: "\(Int(s / 86400))d")
        default:
            let f = DateFormatter()
            f.dateFormat = "M/d"
            return f.string(from: date)
        }
    }
}
