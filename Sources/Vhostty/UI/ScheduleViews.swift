import SwiftUI

/// What the editor sheet edits: a new task or a saved one.
struct ScheduleEditorRequest: Identifiable {
    let id = UUID()
    var task: ScheduleTask
    var isNew: Bool
}

/// The scheduled-task page, shown in the terminal's place.
struct ScheduleManagerView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore

    var body: some View {
        Group {
            if let id = store.scheduleDetailID, let task = schedules.task(id) {
                ScheduleDetailView(store: store, schedules: schedules, task: task)
            } else {
                ScheduleListView(store: store, schedules: schedules)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(store.terminalBackground)
    }
}

private enum ListView: String, CaseIterable, Identifiable {
    case tasks, deleted
    var id: String { rawValue }
}

private struct ScheduleListView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    @State private var view = ListView.tasks
    @State private var projectFilter: UUID?

    private var shown: [ScheduleTask] {
        let all = view == .tasks ? schedules.activeTasks : schedules.deletedTasks
        return all.filter { projectFilter == nil || $0.projectID == projectFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Scheduled Tasks").font(.system(size: 20, weight: .semibold))
                Spacer()
                Picker("", selection: $projectFilter) {
                    Text("All Projects").tag(UUID?.none)
                    ForEach(store.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Button { store.newScheduledTask(in: projectFilter.flatMap(store.project)) } label: {
                    Label("New Task", systemImage: "plus")
                }
                .disabled(store.projects.isEmpty)
            }
            Picker("", selection: $view) {
                Text("Tasks").tag(ListView.tasks)
                Text("Deleted").tag(ListView.deleted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if shown.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        ForEach(shown) { task in
                            ScheduleRow(store: store, schedules: schedules, task: task)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Task").frame(maxWidth: .infinity, alignment: .leading)
            Text("Schedule").frame(width: 170, alignment: .leading)
            Text("Next Run").frame(width: 150, alignment: .leading)
            Text("Status").frame(width: 110, alignment: .leading)
            Color.clear.frame(width: 28)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock").font(.system(size: 34)).foregroundStyle(.tertiary)
            if view == .tasks {
                Text("No scheduled tasks yet").foregroundStyle(.secondary)
                Button("New Task") { store.newScheduledTask(in: projectFilter.flatMap(store.project)) }
                    .disabled(store.projects.isEmpty)
            } else {
                Text("No deleted tasks").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct ScheduleRow: View {
    let store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    AgentIcon(kind: task.kind, size: 9.5).opacity(0.7)
                    Text("\(store.project(task.projectID)?.name ?? String(localized: "Removed project")) · \(task.kind.name)")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(task.enabled || task.isDeleted ? task.timing.summary : String(localized: "Paused"))
                .foregroundStyle(task.enabled ? .primary : .secondary)
                .frame(width: 170, alignment: .leading)
            Text(ScheduleText.nextRun(task))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            RunStateLabel(run: schedules.shownRun(of: task.id))
                .frame(width: 110, alignment: .leading)
            if task.isDeleted {
                Color.clear.frame(width: 28)
            } else {
                Menu {
                    ScheduleActions(store: store, schedules: schedules, task: task)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.scheduleDetailID = task.id }
        .opacity(task.enabled || task.isDeleted ? 1 : 0.7)
    }
}

/// Run Now / Edit / Pause or Resume / Delete, for menus.
private struct ScheduleActions: View {
    let store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask

    var body: some View {
        Button("Run Now") { store.runScheduleNow(task.id) }
            .disabled(schedules.openRun(of: task.id) != nil || store.project(task.projectID) == nil)
        Button("Edit…") { store.editScheduledTask(task) }
        if task.enabled {
            Button("Pause") { schedules.setEnabled(task.id, false) }
        } else {
            Button("Resume") { schedules.setEnabled(task.id, true) }
                .disabled(store.project(task.projectID) == nil || !task.timing.canResume)
        }
        Divider()
        Button("Delete…") { store.confirmDeleteScheduledTask(task) }
    }
}

struct RunStateLabel: View {
    let run: ScheduleRun?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ScheduleText.state(run))
        }
        .foregroundStyle(run == nil ? .tertiary : .secondary)
    }

    private var color: Color {
        switch run?.state {
        case .running?: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .failed?: return Color(red: 0.95, green: 0.42, blue: 0.42)
        case .replied?: return Color.white.opacity(0.55)
        case .skipped?, nil: return Color.white.opacity(0.22)
        }
    }
}

enum ScheduleText {
    static func state(_ run: ScheduleRun?) -> String {
        guard let run else { return String(localized: "Not run yet") }
        switch run.state {
        case .running: return String(localized: "Running")
        case .replied: return String(localized: "Done")
        case .failed: return String(localized: "Error")
        case .skipped: return String(localized: "Skipped")
        }
    }

    static func phase(_ run: ScheduleRun) -> String? {
        switch run.phase {
        case .starting?: return String(localized: "Starting")
        case .executing?: return String(localized: "Working")
        case .needsInput?: return String(localized: "Waiting for you")
        case nil: return nil
        }
    }

    static func trigger(_ trigger: RunTrigger) -> String {
        switch trigger {
        case .scheduled: return String(localized: "Scheduled")
        case .catchUp: return String(localized: "Caught up")
        case .manual: return String(localized: "Run by hand")
        }
    }

    static func nextRun(_ task: ScheduleTask) -> String {
        if task.isDeleted { return "—" }
        if !task.enabled { return String(localized: "Paused") }
        guard let next = task.nextPlan else { return String(localized: "No more plans") }
        return ScheduleFormat.dateTime(next)
    }
}

extension ScheduleTiming {
    /// A once task whose time has passed can't be resumed as it is.
    var canResume: Bool { repeatKind != .once || (onceDate ?? .distantPast) > Date() }
}

// MARK: - Detail

private struct ScheduleDetailView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask
    @State private var visibleRuns = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { store.scheduleDetailID = nil } label: {
                    Label("All Tasks", systemImage: "chevron.left").font(.system(size: 12.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(task.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    if task.isDeleted {
                        Text("Deleted").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else if !task.enabled {
                        Text("Paused").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !task.isDeleted { actions }
                }

                config
                runsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Run Now") { store.runScheduleNow(task.id) }
                .disabled(schedules.openRun(of: task.id) != nil || store.project(task.projectID) == nil)
            Button("Edit…") { store.editScheduledTask(task) }
            if task.enabled {
                Button("Pause") { schedules.setEnabled(task.id, false) }
            } else {
                Button("Resume") { schedules.setEnabled(task.id, true) }
                    .disabled(store.project(task.projectID) == nil || !task.timing.canResume)
            }
            Menu {
                Button("Delete…") { store.confirmDeleteScheduledTask(task) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var config: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
            row("Project", store.project(task.projectID).map { "\($0.name)  \($0.path.abbreviatingHome)" }
                ?? String(localized: "Removed project"))
            row("Agent", task.kind.name)
            row("Schedule", task.timing.summary)
            row("Next Run", ScheduleText.nextRun(task))
            GridRow {
                Text("Session").foregroundStyle(.secondary)
                if let id = task.sessionID, !id.isEmpty {
                    Button(String(localized: "Open Session")) {
                        store.openScheduleSession(kind: task.kind, sessionID: id, projectID: task.projectID, title: task.name)
                    }
                    .buttonStyle(.link)
                } else {
                    Text("Created by the first run").foregroundStyle(.secondary)
                }
            }
            GridRow(alignment: .top) {
                Text("Prompt").foregroundStyle(.secondary)
                Text(task.prompt)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
            }
        }
        .font(.system(size: 12.5))
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var runsSection: some View {
        let runs = schedules.runs(of: task.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Runs").font(.system(size: 14, weight: .semibold))
            if runs.isEmpty {
                Text("Not run yet").font(.system(size: 12.5)).foregroundStyle(.tertiary)
            }
            ForEach(runs.prefix(visibleRuns)) { run in
                RunRow(store: store, schedules: schedules, task: task, run: run)
                Divider().opacity(0.4)
            }
            if runs.count > visibleRuns {
                Button("Show Earlier Runs") { visibleRuns += 20 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12.5))
            }
        }
    }
}

private struct RunRow: View {
    let store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask
    let run: ScheduleRun
    @State private var hover = false

    private var canOpen: Bool { !(run.sessionID ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(ScheduleFormat.dateTime(run.startedAt)).frame(width: 150, alignment: .leading)
                Text(ScheduleText.trigger(run.trigger)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    RunStateLabel(run: run)
                    if let phase = ScheduleText.phase(run) {
                        Text(phase).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if canOpen {
                    Button("Open Session") { open() }
                }
            }
            .font(.system(size: 12.5))
            details
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover && canOpen ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if canOpen { open() } }
    }

    @ViewBuilder
    private var details: some View {
        let lines = detailLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .textSelection(.enabled)
        }
    }

    private var detailLines: [String] {
        var lines: [String] = []
        if let planned = run.plannedAt {
            lines.append(String(localized: "Planned for \(ScheduleFormat.dateTime(planned))"))
        }
        if let ended = run.endedAt, run.state != .skipped {
            lines.append(String(localized: "Ended \(ScheduleFormat.dateTime(ended))"))
        }
        if let reason = run.reason { lines.append(reason) }
        return lines
    }

    private func open() {
        guard let id = run.sessionID else { return }
        store.openScheduleSession(kind: run.kind, sessionID: id, projectID: task.projectID, title: task.name)
    }
}

// MARK: - Editor

struct ScheduleEditorView: View {
    @ObservedObject var store: AppStore
    let request: ScheduleEditorRequest
    @State private var task: ScheduleTask
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, request: ScheduleEditorRequest) {
        self.store = store
        self.request = request
        _task = State(initialValue: request.task)
    }

    private var bound: Bool { !request.isNew && store.schedules.sessionFixed(task) }

    private var problems: [String] {
        var p: [String] = []
        if task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append(String(localized: "Enter a name.")) }
        if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append(String(localized: "Enter a prompt.")) }
        if store.project(task.projectID) == nil { p.append(String(localized: "Choose a project.")) }
        if task.timing.repeatKind == .weekly && task.timing.weekdays.isEmpty { p.append(String(localized: "Choose at least one day.")) }
        if task.timing.repeatKind == .once && !task.timing.canResume { p.append(String(localized: "Choose a time in the future.")) }
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew ? "New Scheduled Task" : "Edit Scheduled Task")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("", text: $task.name, prompt: Text("Weekly dependency check"))
                }
                GridRow {
                    Text("Project")
                    HStack {
                        Picker("", selection: $task.projectID) {
                            ForEach(store.projects) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(bound)
                        // Another project: its own default agent.
                        .onChange(of: task.projectID) { _, id in
                            if !bound, let p = store.project(id) { task.kind = store.defaultKind(p) }
                        }
                        Picker("", selection: $task.kind) {
                            ForEach(AgentKind.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(bound)
                    }
                }
                if bound {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text("Project and agent are fixed once the task has its session.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                GridRow(alignment: .top) {
                    Text("Prompt")
                    TextEditor(text: $task.prompt)
                        .font(.system(size: 12.5))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                }
                GridRow {
                    Text("Repeat")
                    Picker("", selection: $task.timing.repeatKind) {
                        Text("Once").tag(ScheduleRepeat.once)
                        Text("Daily").tag(ScheduleRepeat.daily)
                        Text("Weekdays").tag(ScheduleRepeat.weekdays)
                        Text("Weekly").tag(ScheduleRepeat.weekly)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if task.timing.repeatKind == .weekly {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        WeekdayPicker(weekdays: $task.timing.weekdays)
                    }
                }
                GridRow {
                    Text("Time")
                    HStack(spacing: 10) {
                        if task.timing.repeatKind == .once {
                            DatePicker("", selection: onceDay, displayedComponents: .date).labelsHidden().fixedSize()
                        }
                        DatePicker("", selection: timeOfDay, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(planSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))

            Divider()
            HStack {
                if let text = notice ?? problems.first {
                    Text(text).font(.system(size: 11.5)).foregroundStyle(notice != nil ? .orange : .secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Create and Enable" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var planSummary: String {
        let next = task.timing.next(after: Date()).map { ScheduleFormat.dateTime($0) }
        return String(localized: "\(task.timing.summary) · Next: \(next ?? "—")")
    }

    /// The time of day, as a date in the task's zone (the picker shows that zone).
    private var timeOfDay: Binding<Date> {
        Binding(get: {
            let cal = task.timing.calendar
            return cal.date(bySettingHour: task.timing.hour, minute: task.timing.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = task.timing.calendar.dateComponents([.hour, .minute], from: date)
            task.timing.hour = c.hour ?? 9
            task.timing.minute = c.minute ?? 0
        })
    }

    private var onceDay: Binding<Date> {
        Binding(get: {
            let t = task.timing
            let cal = t.calendar
            if let y = t.year, let m = t.month, let d = t.day,
               let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) { return date }
            return Date()
        }, set: { date in
            let c = task.timing.calendar.dateComponents([.year, .month, .day], from: date)
            task.timing.year = c.year
            task.timing.month = c.month
            task.timing.day = c.day
        })
    }

    private func save() {
        guard problems.isEmpty else { return }
        var t = task
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.prompt = t.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.timing.repeatKind != .once {
            t.timing.year = nil
            t.timing.month = nil
            t.timing.day = nil
        }
        if request.isNew {
            store.schedules.create(t)
            store.showSchedules(detail: t.id)
        } else if let problem = store.schedules.applyEdit(t) {
            notice = problem
            return
        }
        dismiss()
    }
}

private struct WeekdayPicker: View {
    @Binding var weekdays: [Int]

    var body: some View {
        let names = ScheduleFormat.weekdayNames
        HStack(spacing: 4) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    if on { weekdays.removeAll { $0 == day } } else { weekdays.append(day) }
                } label: {
                    Text(names[day - 1])
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .frame(minWidth: 34, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Store actions

extension AppStore {
    func newScheduledTask(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        var timing = ScheduleTiming()
        let cal = timing.calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: tomorrow)
        timing.year = c.year
        timing.month = c.month
        timing.day = c.day
        timing.weekdays = [c.weekday ?? 7]
        let task = ScheduleTask(name: "", projectID: project.id, kind: defaultKind(project), prompt: "", timing: timing)
        scheduleEditor = ScheduleEditorRequest(task: task, isNew: true)
    }

    /// The same form, filled in by an agent through the schedule skill.
    func newScheduledTask(filledIn task: ScheduleTask) {
        var t = task
        if t.timing.year == nil {
            let c = t.timing.calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
            t.timing.year = c.year
            t.timing.month = c.month
            t.timing.day = c.day
        }
        scheduleEditor = ScheduleEditorRequest(task: t, isNew: true)
    }

    func editScheduledTask(_ task: ScheduleTask) {
        var t = task
        if t.timing.repeatKind != .once, t.timing.year == nil {
            let c = t.timing.calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
            t.timing.year = c.year
            t.timing.month = c.month
            t.timing.day = c.day
        }
        scheduleEditor = ScheduleEditorRequest(task: t, isNew: false)
    }

    /// An agent's delete, asked on the window as a sheet: a modal alert would
    /// hold up the main thread (and the hook socket) for as long as the user is
    /// away. It asks what the Delete menu item asks.
    func askDeleteScheduledTask(_ task: ScheduleTask) {
        guard let window = (NSApp.delegate as? AppDelegate)?.window else { return }
        scheduleAsking = true
        deleteAlert(task).beginSheetModal(for: window) { [self] answer in
            scheduleAsking = false
            guard answer == .alertFirstButtonReturn else { return }
            schedules.delete(task.id)
        }
    }

    private func deleteAlert(_ task: ScheduleTask) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(task.name)”?")
        alert.informativeText = String(localized: "It stops being scheduled and moves to Deleted, where its runs stay visible. Its session and any current run are left alone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    func confirmDeleteScheduledTask(_ task: ScheduleTask) {
        guard deleteAlert(task).runModal() == .alertFirstButtonReturn else { return }
        schedules.delete(task.id)
    }
}
