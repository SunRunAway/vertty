import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            Workspace(layout: store) {
                LocalSidebar(store: store)
            } strip: {
                LocalTitleStrip(store: store)
            } detail: {
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
}

/// The title strip of this Mac's window: what's selected, and the bottom
/// shell's button.
private struct LocalTitleStrip: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TitleStrip(layout: store, background: store.terminalBackground) {
            if store.showingSchedules {
                Text("Scheduled Tasks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let tab = store.selectedTab {
                TitleStripLabel(card: tab, project: store.project(tab.projectID))
            }
        } trailing: {
            if store.showingSchedules {
                IconButton(systemName: "plus", help: "New Scheduled Task…") { store.newScheduledTask() }
                    .disabled(store.projects.isEmpty)
            } else if let tab = store.selectedTab {
                ShellToggleButton(store: store, tab: tab)
            }
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
