import SwiftUI

/// What the editor sheet edits: a new task or a saved one.
struct ScheduleEditorRequest: Identifiable {
    let id = UUID()
    var task: ScheduleTask
    var isNew: Bool
    /// The agent's draft this sheet reviews, if any.
    var draftID: UUID? = nil
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
    case tasks, pending, deleted
    var id: String { rawValue }
}

private struct ScheduleListView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    @State private var view: ListView
    @State private var projectFilter: UUID?

    init(store: AppStore, schedules: ScheduleStore) {
        self.store = store
        self.schedules = schedules
        _view = State(initialValue: store.scheduleShowPending ? .pending : .tasks)
    }

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
                Text("Pending (\(schedules.pendingDrafts.count))").tag(ListView.pending)
                Text("Deleted").tag(ListView.deleted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if view == .pending {
                pendingList
            } else if shown.isEmpty {
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

    @ViewBuilder
    private var pendingList: some View {
        let drafts = schedules.pendingDrafts.filter { d in
            projectFilter == nil || (d.task ?? d.base)?.projectID == projectFilter
        }
        if drafts.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("No drafts waiting").foregroundStyle(.secondary)
                Text("Drafts come from Claude or Codex when you ask them to schedule something.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(drafts) { draft in
                        DraftRow(store: store, draft: draft)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
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
        case .replied: return String(localized: "Replied")
        case .failed: return String(localized: "Error")
        case .skipped: return String(localized: "Skipped")
        }
    }

    static func phase(_ run: ScheduleRun) -> String? {
        if run.unresolved == true { return String(localized: "Result unknown") }
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

    static func draftTitle(_ d: ScheduleDraft) -> String {
        let name = (d.task ?? d.base)?.name ?? "?"
        switch d.action {
        case .create: return String(localized: "Create “\(name)”")
        case .edit: return String(localized: "Change “\(name)”")
        case .pause: return String(localized: "Pause “\(name)”")
        case .resume: return String(localized: "Resume “\(name)”")
        case .delete: return String(localized: "Delete “\(name)”")
        case .run: return String(localized: "Run “\(name)” now")
        }
    }

    static func draftSource(_ d: ScheduleDraft) -> String {
        let agent = d.sourceKind?.name ?? String(localized: "an agent")
        if let title = d.sourceTitle { return String(localized: "From \(agent) session “\(title)”") }
        return String(localized: "From \(agent)")
    }

    static func nextRun(_ task: ScheduleTask) -> String {
        if task.isDeleted { return "—" }
        if !task.enabled { return String(localized: "Paused") }
        guard let next = task.nextPlan else { return String(localized: "No more plans") }
        return ScheduleFormat.dateTime(next, zone: task.timing.zone)
    }
}

extension ScheduleTiming {
    /// A once task whose time has passed can't be resumed as it is.
    var canResume: Bool { repeatKind != .once || (onceDate ?? .distantPast) > Date() }
}

private struct DraftRow: View {
    let store: AppStore
    let draft: ScheduleDraft
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScheduleText.draftTitle(draft)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(ScheduleText.draftSource(draft)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ScheduleFormat.dateTime(draft.createdAt)).foregroundStyle(.secondary)
            Button("Review…") { store.reviewDraft(draft.id) }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.reviewDraft(draft.id) }
    }
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

                if let note = task.reviewNote, !task.isDeleted {
                    banner(note, systemImage: "exclamationmark.triangle")
                }
                if !task.isDeleted {
                    banner(String(localized: "When the task runs, it stops and resumes this session, which may interrupt what you're doing in it."),
                           systemImage: "info.circle")
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

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
    }

    private var config: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
            row("Project", store.project(task.projectID).map { "\($0.name)  \($0.path.abbreviatingHome)" }
                ?? String(localized: "Removed project"))
            row("Agent", task.kind.name)
            row("Schedule", task.timing.summaryWithZone)
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
                if run.unresolved == true {
                    Button("End This Record") { schedules.endRecord(run.id) }
                }
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
            if let count = run.skippedCount, count > 1, let from = run.skippedFrom {
                lines.append(String(localized: "\(count) missed plans: \(ScheduleFormat.dateTime(from)) – \(ScheduleFormat.dateTime(planned))"))
            } else {
                lines.append(String(localized: "Planned for \(ScheduleFormat.dateTime(planned))"))
            }
        }
        if let ended = run.endedAt, run.state != .skipped {
            lines.append(String(localized: "Ended \(ScheduleFormat.dateTime(ended))"))
        }
        if let reason = run.reason { lines.append(reason) }
        if run.resolvedByUser == true { lines.append(String(localized: "Record ended by you.")) }
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
    /// For a draft that changes a task: that task as shown when the sheet opened.
    @State private var shownTask: ScheduleTask?
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, request: ScheduleEditorRequest) {
        self.store = store
        self.request = request
        _task = State(initialValue: request.task)
        _shownTask = State(initialValue: request.isNew ? nil : store.schedules.task(request.task.id))
    }

    private var draft: ScheduleDraft? { request.draftID.flatMap(store.schedules.draft) }

    private var bound: Bool { task.isBound }

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
            Text(draft != nil ? (request.isNew ? "Review Draft: New Task" : "Review Draft: Change Task")
                 : request.isNew ? "New Scheduled Task" : "Edit Scheduled Task")
                .font(.system(size: 15, weight: .semibold))
            if let draft {
                DraftSourceLine(store: store, draft: draft)
                if draft.action == .edit, let base = draft.base, let proposed = draft.task {
                    DraftChanges(store: store, old: base, new: proposed)
                }
            }

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
                        Text(task.timing.timeZone).foregroundStyle(.secondary)
                    }
                    .environment(\.timeZone, task.timing.zone)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(planSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))

            Divider()
            Label("Needs Vhostty running. When the task runs, it may interrupt what you're doing in its session.",
                  systemImage: "info.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack {
                if let text = notice ?? problems.first {
                    Text(text).font(.system(size: 11.5)).foregroundStyle(notice != nil ? .orange : .secondary)
                }
                Spacer()
                if let draft {
                    Button("Discard") {
                        store.schedules.decide(draft.id, .rejected)
                        dismiss()
                    }
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button(request.isNew ? "Create and Enable" : draft != nil ? "Save Changes" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var planSummary: String {
        let next = task.timing.next(after: Date()).map { ScheduleFormat.dateTime($0, zone: task.timing.zone) }
        return String(localized: "\(task.timing.summaryWithZone) · Next: \(next ?? "—")")
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
        if let id = request.draftID {
            // Only what this sheet showed gets confirmed.
            guard store.schedules.draft(id)?.status == .pending else {
                notice = String(localized: "This draft is no longer waiting for confirmation.")
                return
            }
            if !request.isNew {
                guard let current = store.schedules.task(t.id), !current.isDeleted else {
                    notice = String(localized: "The task no longer exists.")
                    return
                }
                guard current == shownTask else {
                    shownTask = current
                    notice = String(localized: "The task changed while you were reviewing. Check it again, then save.")
                    return
                }
                if let problem = store.schedules.applyEdit(t) {
                    notice = problem
                    return
                }
            } else {
                store.schedules.create(t)
            }
            store.schedules.decide(id, .approved, taskID: t.id)
            store.showSchedules(detail: t.id)
        } else if request.isNew {
            store.schedules.create(t)
            store.showSchedules(detail: t.id)
        } else if let problem = store.schedules.applyEdit(t) {
            notice = problem
            return
        }
        dismiss()
    }
}

/// "From Claude session “…”", with a way back to it.
private struct DraftSourceLine: View {
    let store: AppStore
    let draft: ScheduleDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text(ScheduleText.draftSource(draft)).foregroundStyle(.secondary)
            if let id = draft.sourceTabID, let tab = store.tab(withID: id) {
                Button("Open Session") {
                    dismiss()
                    store.select(tab)
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
    }
}

/// What an edit draft changes: each field before and after.
private struct DraftChanges: View {
    let store: AppStore
    let old: ScheduleTask
    let new: ScheduleTask

    var body: some View {
        let rows = changes
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes").font(.system(size: 12, weight: .semibold))
            ForEach(rows, id: \.0) { label, before, after in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
                    Text("− " + before).foregroundStyle(.secondary).lineLimit(3)
                    Text("+ " + after).lineLimit(3)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
    }

    private var changes: [(String, String, String)] {
        var c: [(String, String, String)] = []
        if old.name != new.name { c.append((String(localized: "Name"), old.name, new.name)) }
        if old.projectID != new.projectID {
            c.append((String(localized: "Project"), store.project(old.projectID)?.name ?? "?", store.project(new.projectID)?.name ?? "?"))
        }
        if old.kind != new.kind { c.append((String(localized: "Agent"), old.kind.name, new.kind.name)) }
        if old.timing != new.timing { c.append((String(localized: "Schedule"), old.timing.summaryWithZone, new.timing.summaryWithZone)) }
        if old.prompt != new.prompt { c.append((String(localized: "Prompt"), old.prompt, new.prompt)) }
        return c
    }
}

/// Reviewing a draft that pauses, resumes, deletes or runs a task: just the
/// task and what the action does.
struct ScheduleDraftActionView: View {
    @ObservedObject var store: AppStore
    let draftID: UUID
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let draft = store.schedules.draft(draftID)
        let task = draft?.taskID.flatMap(store.schedules.task)
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Draft").font(.system(size: 15, weight: .semibold))
            if let draft {
                DraftSourceLine(store: store, draft: draft)
                Text(ScheduleText.draftTitle(draft)).font(.system(size: 14, weight: .medium))
            }
            if let task {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Project").foregroundStyle(.secondary); Text(store.project(task.projectID)?.name ?? "?") }
                    GridRow { Text("Agent").foregroundStyle(.secondary); Text(task.kind.name) }
                    GridRow { Text("Schedule").foregroundStyle(.secondary); Text(task.timing.summaryWithZone) }
                    GridRow { Text("Next Run").foregroundStyle(.secondary); Text(ScheduleText.nextRun(task)) }
                }
                .font(.system(size: 12.5))
            }
            if let draft { Text(impact(draft.action, task)).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                if let notice { Text(notice).font(.system(size: 11.5)).foregroundStyle(.orange) }
                Spacer()
                Button("Discard") {
                    store.schedules.decide(draftID, .rejected)
                    dismiss()
                }
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                if let draft {
                    Button(confirmTitle(draft.action)) { confirm(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(task == nil || draft.status != .pending)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func impact(_ action: DraftAction, _ task: ScheduleTask?) -> String {
        switch action {
        case .pause: return String(localized: "Stops its future runs. A run going on now isn't stopped.")
        case .resume:
            let next = task.flatMap { t in t.timing.next(after: Date()).map { ScheduleFormat.dateTime($0, zone: t.timing.zone) } } ?? "—"
            return String(localized: "Runs on its schedule again from now on, without catching up what was missed. Next: \(next)")
        case .delete: return String(localized: "Stops scheduling it and moves it to Deleted. Its session and runs are kept.")
        case .run: return String(localized: "Runs it once now with its current settings; its schedule stays as it is. Its session is stopped and resumed, which may interrupt you.")
        case .create, .edit: return ""
        }
    }

    private func confirmTitle(_ action: DraftAction) -> LocalizedStringKey {
        switch action {
        case .pause: return "Confirm Pause"
        case .resume: return "Confirm Resume"
        case .delete: return "Confirm Delete"
        case .run: return "Confirm Run"
        case .create, .edit: return "Confirm"
        }
    }

    private func confirm(_ draft: ScheduleDraft) {
        guard draft.status == .pending, let id = draft.taskID, let task = store.schedules.task(id), !task.isDeleted else {
            notice = String(localized: "This draft can no longer be applied.")
            return
        }
        switch draft.action {
        case .pause: store.schedules.setEnabled(id, false)
        case .resume:
            guard store.project(task.projectID) != nil, task.timing.canResume else {
                notice = String(localized: "This task can't be resumed as it is. Edit it first.")
                return
            }
            store.schedules.setEnabled(id, true)
        case .delete: store.schedules.delete(id)
        case .run:
            guard store.schedules.openRun(of: id) == nil else {
                notice = String(localized: "The task is running now.")
                return
            }
            store.runScheduleNow(id)
        case .create, .edit: return
        }
        store.schedules.decide(draft.id, .approved)
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

    /// Opens the review sheet for an agent's draft.
    func reviewDraft(_ id: UUID) {
        guard let draft = schedules.draft(id), draft.status == .pending else { return }
        switch draft.action {
        case .create, .edit:
            guard var task = draft.task else { return }
            if draft.action == .edit, let current = draft.taskID.flatMap(schedules.task) {
                // The proposal's fields over the task as it is now.
                var t = current
                t.name = task.name
                t.prompt = task.prompt
                t.timing = task.timing
                t.projectID = task.projectID
                t.kind = task.kind
                task = t
            }
            if task.timing.year == nil {
                let c = task.timing.calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
                task.timing.year = c.year
                task.timing.month = c.month
                task.timing.day = c.day
            }
            scheduleEditor = ScheduleEditorRequest(task: task, isNew: draft.action == .create, draftID: id)
        default:
            scheduleEditor = ScheduleEditorRequest(task: draft.base ?? ScheduleTask(name: "", projectID: UUID(), kind: .claude,
                                                                                    prompt: "", timing: ScheduleTiming()),
                                                   isNew: false, draftID: id)
        }
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

    func confirmDeleteScheduledTask(_ task: ScheduleTask) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(task.name)”?")
        alert.informativeText = String(localized: "It stops being scheduled and moves to Deleted, where its runs stay visible. Its session and any current run are left alone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        schedules.delete(task.id)
    }
}
