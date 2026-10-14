import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                SidebarView(store: store)
                    .frame(width: store.sidebarWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            }
            VStack(spacing: 0) {
                TitleStrip(store: store)
                ZStack {
                    store.terminalBackground
                    TerminalHost(store: store)
                    if store.tabs.isEmpty {
                        EmptyStateView(store: store)
                    }
                    if store.showingSchedules {
                        ScheduleManagerView(store: store, schedules: store.schedules)
                    }
                }
            }
            if store.schedulePanel != nil {
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
                SchedulePanelView(store: store, schedules: store.schedules)
                    .id(store.schedulePanel?.id)
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? store.sidebarWidth
                        dragStartWidth = start
                        store.sidebarWidth = min(max(start + value.translation.width, 230), 520)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        store.scheduleSave()
                    })
    }
}

/// Slim draggable strip above the terminal showing what's selected.
struct TitleStrip: View {
    @ObservedObject var store: AppStore

    static let height: CGFloat = 34

    var body: some View {
        ZStack {
            WindowDragArea()
            if store.showingSchedules {
                Text("Scheduled Tasks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                HStack {
                    Spacer()
                    IconButton(systemName: "plus", help: "New Scheduled Task…") { store.newScheduledTask() }
                        .disabled(store.projects.isEmpty)
                }
                .padding(.trailing, 10)
            } else if let tab = store.selectedTab {
                TitleStripLabel(tab: tab, project: store.project(tab.projectID))
                    .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Spacer()
                    ShellToggleButton(store: store, tab: tab)
                }
                .padding(.trailing, 10)
            }
        }
        .padding(.leading, store.sidebarVisible ? 0 : 112)
        .overlay(alignment: .leading) {
            if !store.sidebarVisible {
                SidebarToggleButton(store: store)
                    .padding(.leading, 80)
            }
        }
        .frame(height: Self.height)
        .background(store.terminalBackground)
    }
}

private struct TitleStripLabel: View {
    @ObservedObject var tab: TabSession
    let project: Project?

    var body: some View {
        HStack(spacing: 6) {
            if let project {
                Text(project.name).foregroundStyle(.tertiary)
                Text("/").foregroundStyle(.quaternary)
            }
            Text(tab.title).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
    }
}

struct SidebarToggleButton: View {
    @ObservedObject var store: AppStore

    var body: some View {
        IconButton(systemName: "sidebar.left",
                   help: store.sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)") {
            store.toggleSidebar()
        }
    }
}

/// Shows/hides the selected session's bottom shell panel (same as ⌘J).
private struct ShellToggleButton: View {
    let store: AppStore
    @ObservedObject var tab: TabSession

    var body: some View {
        IconButton(systemName: tab.shellVisible ? "terminal.fill" : "terminal",
                   help: tab.shellVisible ? "Hide Terminal (⌘J)" : "Show Terminal (⌘J)",
                   active: tab.shellVisible) {
            store.toggleShell()
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if let project = store.currentProject {
            watermark(project)
        } else {
            onboarding
        }
    }

    /// Projects already sit in the sidebar, so don't list them again here:
    /// just a faint mark and the keys that start something.
    private func watermark(_ project: Project) -> some View {
        VStack(spacing: 28) {
            Text("👻")
                .font(.system(size: 72))
                .grayscale(1)
                .opacity(0.18)
            VStack(alignment: .leading, spacing: 8) {
                shortcut("⌘T", "New session in \(project.name)")
                shortcut("⇧⌘O", "Add Project")
                shortcut("⌃⌘S", "Show/hide sidebar")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private var onboarding: some View {
        VStack(spacing: 18) {
            Text("👻")
                .font(.system(size: 54))
            Text("Vhostty")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Add a project directory, then start a session in it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button { store.addProjectViaPanel() } label: {
                Label("Add Project…", systemImage: "folder.badge.plus").frame(minWidth: 180)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 4) {
                shortcut("⌘T", "New session in the current project")
                shortcut("⌘1…9", "Switch sessions")
                shortcut("⌘W", "Close session")
                shortcut("⌃⌘S", "Show/hide sidebar")
            }
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.top, 12)
        }
        .padding(40)
    }

    private func shortcut(_ key: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 56, alignment: .trailing)
            Text(text)
        }
    }
}
