import SwiftUI

/// This Mac's sidebar: the shared one (VhosttyUI.SidebarView) under the
/// window controls and the scheduled tasks.
struct LocalSidebar: View {
    @ObservedObject var store: AppStore

    var body: some View {
        SidebarView(store: store) {
            SidebarTopBar(layout: store)

            ScheduleEntry(store: store, schedules: store.schedules)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
    }
}

/// Opens the scheduled-task page (above the projects).
private struct ScheduleEntry: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12.5))
                .frame(width: 18)
            Text("Scheduled Tasks")
                .font(.system(size: 13.5, weight: .medium))
            Spacer(minLength: 4)
            let running = schedules.runs.filter { $0.state == .running }.count
            if running > 0 {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
                    .help(String(localized: "\(running) scheduled runs going"))
            }
        }
        .foregroundStyle(store.showingSchedules ? .primary : .secondary)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(store.showingSchedules ? 0.11 : hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.showSchedules() }
    }
}
