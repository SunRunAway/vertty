import SwiftUI

/// What the task panel on the right shows: a saved task, or a new one being
/// filled in. The draft holds the panel's settings until they're saved.
struct SchedulePanel: Identifiable {
    let id = UUID()
    /// nil: a new task.
    var taskID: UUID?
    var draft: ScheduleTask
    var isNew: Bool { taskID == nil }
}

// MARK: - Page

/// The scheduled-task page, shown in the terminal's place: tasks grouped by
/// project. A task opens in the panel on the right.
struct ScheduleManagerView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    @State private var showDeleted = false

    var body: some View {
        let active = schedules.activeTasks
        let deleted = schedules.deletedTasks
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if active.isEmpty {
                    emptyState
                } else {
                    ForEach(groups(active), id: \.0) { projectID, tasks in
                        section(projectID, tasks)
                    }
                }
                if !deleted.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showDeleted.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showDeleted ? 90 : 0))
                                Text("Deleted (\(deleted.count))")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showDeleted { rows(deleted) }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(store.terminalBackground)
    }

    /// In sidebar order; tasks of removed projects last.
    private func groups(_ tasks: [ScheduleTask]) -> [(UUID?, [ScheduleTask])] {
        var result: [(UUID?, [ScheduleTask])] = store.projects.compactMap { p in
            let mine = tasks.filter { $0.projectID == p.id }
            return mine.isEmpty ? nil : (p.id, mine)
        }
        let orphans = tasks.filter { store.project($0.projectID) == nil }
        if !orphans.isEmpty { result.append((nil, orphans)) }
        return result
    }

    private func section(_ projectID: UUID?, _ tasks: [ScheduleTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                Text(projectID.flatMap(store.project)?.name ?? String(localized: "Removed project"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let p = projectID.flatMap(store.project) {
                    IconButton(systemName: "plus", help: "New Scheduled Task…") { store.newScheduledTask(in: p) }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            rows(tasks)
        }
    }

    /// Flat rows with a hairline between them, like a list in Settings.
    private func rows(_ tasks: [ScheduleTask]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                if i > 0 {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 12)
                }
                ScheduleTaskRow(store: store, schedules: schedules, task: task)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No scheduled tasks yet").foregroundStyle(.secondary)
            Text("Run a prompt in a project at set times, in one session that each run resumes.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Button { store.newScheduledTask() } label: { Label("New Scheduled Task…", systemImage: "plus") }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .disabled(store.projects.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

/// A task in the list, drawn like a session card: what runs, and when.
private struct ScheduleTaskRow: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask
    @State private var hover = false

    private var selected: Bool { store.schedulePanel?.taskID == task.id }

    var body: some View {
        let run = schedules.shownRun(of: task.id)
        HStack(spacing: 12) {
            TaskStateGlyph(task: task, run: run)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(task.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .lineLimit(1)
                    AgentIcon(kind: task.kind, size: 12)
                }
                HStack(spacing: 5) {
                    Text(ScheduleText.when(task))
                    if run?.state == .failed {
                        Text("· \(String(localized: "Last run failed"))")
                            .foregroundStyle(ScheduleText.red)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !task.isDeleted {
                HStack(spacing: 4) {
                    IconButton(systemName: "play", help: "Run Now", large: true) { store.runScheduleNow(task.id) }
                        .disabled(schedules.openRun(of: task.id) != nil || store.project(task.projectID) == nil)
                    IconMenu(large: true) { ScheduleActions(store: store, schedules: schedules, task: task) }
                }
                .opacity(hover || selected ? 1 : 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(selected ? 0.09 : hover ? 0.05 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(task.isDeleted ? 0.6 : 1)
        .onHover { hover = $0 }
        .onTapGesture { store.showScheduledTask(task.id) }
        .contextMenu { if !task.isDeleted { ScheduleActions(store: store, schedules: schedules, task: task) } }
    }
}

/// Pause or Resume, Delete: for menus.
private struct ScheduleActions: View {
    let store: AppStore
    @ObservedObject var schedules: ScheduleStore
    let task: ScheduleTask

    var body: some View {
        Button("Run Now") { store.runScheduleNow(task.id) }
            .disabled(schedules.openRun(of: task.id) != nil || store.project(task.projectID) == nil)
        if task.enabled {
            Button("Pause") { schedules.setEnabled(task.id, false) }
        } else {
            Button("Resume") { schedules.setEnabled(task.id, true) }
                .disabled(store.project(task.projectID) == nil || !task.timing.canResume)
        }
        if let id = task.sessionID, !id.isEmpty {
            Button("Open Session") {
                store.openScheduleSession(kind: task.kind, sessionID: id, projectID: task.projectID, title: task.name)
            }
        }
        Divider()
        Button("Delete…") { store.confirmDeleteScheduledTask(task) }
    }
}

/// Like a session card's status: a spinner while running, a pause sign when
/// paused, red after a failed run, else nothing (the space stays, so names line up).
private struct TaskStateGlyph: View {
    let task: ScheduleTask
    let run: ScheduleRun?

    var body: some View {
        Group {
            if run?.state == .running {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else if !task.enabled && !task.isDeleted {
                Image(systemName: "pause.circle").font(.system(size: 15)).foregroundStyle(.secondary)
            } else if run?.state == .failed {
                Circle().fill(ScheduleText.red).frame(width: 9, height: 9)
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Panel

/// The task panel on the right: a task's prompt, settings and runs, or a new
/// task. Edits stay in the draft until Save.
struct SchedulePanelView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var schedules: ScheduleStore
    @State private var notice: String?
    @State private var visibleRuns = 15

    static let width: CGFloat = 420
    static let background = Color(red: 0.118, green: 0.118, blue: 0.125)

    private var panel: SchedulePanel? { store.schedulePanel }
    private var isNew: Bool { panel?.isNew ?? true }
    private var task: ScheduleTask? { panel?.taskID.flatMap(schedules.task) }
    private var readOnly: Bool { task?.isDeleted == true }
    /// Project and agent stay with the session once there is one.
    private var fixed: Bool { task.map(schedules.sessionFixed) ?? false }

    private var draft: Binding<ScheduleTask> {
        Binding(get: { store.schedulePanel?.draft ?? ScheduleTask(name: "", projectID: UUID(), kind: .claude, prompt: "", timing: ScheduleTiming()) },
                set: { store.schedulePanel?.draft = $0 })
    }

    private var problems: [String] { store.schedulePanelProblems }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("", text: draft.name, prompt: Text("Task name"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 19, weight: .semibold))
                    promptBox
                    sessionGroup
                    scheduleGroup
                    if task != nil { runsSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .disabled(readOnly)
            }
            if store.schedulePanelDirty { footer }
        }
        .frame(width: Self.width)
        .background(Self.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Text(statusTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.leading, 20)
            Spacer()
            if let task, !task.isDeleted {
                IconButton(systemName: "play", help: "Run Now") { store.runScheduleNow(task.id) }
                    .disabled(schedules.openRun(of: task.id) != nil || store.project(task.projectID) == nil)
                if task.enabled {
                    IconButton(systemName: "pause", help: "Pause") { schedules.setEnabled(task.id, false) }
                } else {
                    IconButton(systemName: "arrow.clockwise", help: "Resume") { schedules.setEnabled(task.id, true) }
                        .disabled(store.project(task.projectID) == nil || !task.timing.canResume)
                }
                IconMenu { ScheduleActions(store: store, schedules: schedules, task: task) }
            }
            IconButton(systemName: "xmark", help: "Close") { store.schedulePanel = nil }
                .padding(.trailing, 8)
        }
        .frame(height: TitleStrip.height)
        .background(WindowDragArea())
    }

    private var statusTitle: String {
        guard let task else { return String(localized: "New Scheduled Task") }
        if task.isDeleted { return String(localized: "Deleted") }
        return task.enabled ? String(localized: "Active") : String(localized: "Paused")
    }

    private var statusColor: Color {
        guard let task, !task.isDeleted else { return .secondary }
        return task.enabled ? Color(red: 0.35, green: 0.62, blue: 1.0) : .secondary
    }

    // MARK: Prompt

    private var promptBox: some View {
        ZStack(alignment: .topLeading) {
            if draft.wrappedValue.prompt.isEmpty {
                Text("What should the agent do? It runs in a session of its own that hasn't seen this one.")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: draft.prompt)
                .scrollContentBackground(.hidden)
        }
        .font(.system(size: 13, design: .monospaced))
        .lineSpacing(3)
        .frame(minHeight: 120, maxHeight: 300)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: Settings

    private var sessionGroup: some View {
        PanelGroup(title: "Details") {
            PanelRow("Project") {
                PanelMenu(selection: draft.projectID,
                          options: store.projects.map { ($0.id, $0.name) },
                          fallback: String(localized: "Removed project"))
                    .disabled(fixed)
                    .onChange(of: draft.wrappedValue.projectID) { _, id in
                        // Another project: its own default agent.
                        if !fixed, let p = store.project(id) { draft.wrappedValue.kind = store.defaultKind(p) }
                    }
            }
            PanelRow("Agent") {
                AgentIcon(kind: draft.wrappedValue.kind, size: 11)
                Menu {
                    ForEach(AgentKind.allCases) { kind in
                        Button(kind.name) { draft.wrappedValue.kind = kind }
                    }
                } label: {
                    let name = Text(draft.wrappedValue.kind.name)
                    fixed ? name : name + Text("  ") + MenuChevron.text
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(fixed)
            }
            PanelRow("Session", divider: false) {
                if let task, let id = task.sessionID, !id.isEmpty {
                    Button("Open Session") {
                        store.openScheduleSession(kind: task.kind, sessionID: id, projectID: task.projectID, title: task.name)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .cursor(.pointingHand)
                } else {
                    Text("Created by the first run").foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var scheduleGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelGroup(title: "Schedule") {
                PanelRow("Repeat") {
                    PanelMenu(selection: draft.timing.repeatKind,
                              options: [(.once, String(localized: "Once")), (.daily, String(localized: "Daily")),
                                        (.weekdays, String(localized: "Weekdays")), (.weekly, String(localized: "Weekly"))])
                }
                if draft.wrappedValue.timing.repeatKind == .weekly {
                    PanelRow("Days") { WeekdayPicker(weekdays: draft.timing.weekdays) }
                }
                if draft.wrappedValue.timing.repeatKind == .once {
                    PanelRow("Date") {
                        DatePicker("", selection: onceDay, displayedComponents: .date).labelsHidden().fixedSize()
                    }
                }
                PanelRow("Time", divider: false) {
                    DatePicker("", selection: timeOfDay, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                }
            }
            Text(nextLine)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private var nextLine: String {
        let t = draft.wrappedValue
        guard let next = t.timing.next(after: Date()) else { return String(localized: "No more plans") }
        if let task, !task.enabled, !store.schedulePanelDirty { return String(localized: "Paused") }
        return String(localized: "Next: \(ScheduleFormat.dateTime(next)) · \(ScheduleText.relative(next))")
    }

    /// The time of day, as a date (the picker shows the Mac's zone).
    private var timeOfDay: Binding<Date> {
        Binding(get: {
            let t = draft.wrappedValue.timing
            return t.calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = draft.wrappedValue.timing.calendar.dateComponents([.hour, .minute], from: date)
            draft.wrappedValue.timing.hour = c.hour ?? 9
            draft.wrappedValue.timing.minute = c.minute ?? 0
        })
    }

    private var onceDay: Binding<Date> {
        Binding(get: {
            let t = draft.wrappedValue.timing
            if let y = t.year, let m = t.month, let d = t.day,
               let date = t.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) { return date }
            return Date()
        }, set: { date in
            let c = draft.wrappedValue.timing.calendar.dateComponents([.year, .month, .day], from: date)
            draft.wrappedValue.timing.year = c.year
            draft.wrappedValue.timing.month = c.month
            draft.wrappedValue.timing.day = c.day
        })
    }

    // MARK: Runs

    private var runsSection: some View {
        let runs = task.map { schedules.runs(of: $0.id) } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text("Runs")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            if runs.isEmpty {
                Text("Not run yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
            ForEach(runs.prefix(visibleRuns)) { run in
                RunLine(store: store, task: task!, run: run)
            }
            if runs.count > visibleRuns {
                Button("Show Earlier Runs") { visibleRuns += 20 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let text = notice ?? problems.first {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(notice != nil ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel") { cancel() }
                .buttonStyle(PanelButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create and Enable" : "Save") { save() }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1) }
    }

    private func cancel() {
        notice = nil
        store.cancelSchedulePanel()
    }

    private func save() {
        notice = store.saveSchedulePanel()
    }
}

/// One run: its state and when; a click opens the session it ran in.
private struct RunLine: View {
    let store: AppStore
    let task: ScheduleTask
    let run: ScheduleRun
    @State private var hover = false

    private var canOpen: Bool { !(run.sessionID ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Group {
                    if run.state == .running {
                        ProgressView().controlSize(.mini).scaleEffect(0.65)
                    } else {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 12, height: 12)
                Text(ScheduleText.state(run)).foregroundStyle(.secondary)
                Text([ScheduleText.trigger(run.trigger), ScheduleText.phase(run)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(RelativeTime.short(run.startedAt))
                    .foregroundStyle(.tertiary)
                    .help(ScheduleFormat.dateTime(run.startedAt))
            }
            if let reason = run.reason {
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(run.state == .failed ? ScheduleText.red.opacity(0.9) : Color.secondary)
                    .padding(.leading, 19)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover && canOpen ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            guard let id = run.sessionID, !id.isEmpty else { return }
            store.openScheduleSession(kind: run.kind, sessionID: id, projectID: task.projectID, title: task.name)
        }
        .help(canOpen ? String(localized: "Open Session") : "")
    }

    private var color: Color {
        switch run.state {
        case .failed: return ScheduleText.red
        case .replied: return Color.white.opacity(0.55)
        case .running: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .skipped: return Color.white.opacity(0.22)
        }
    }
}

// MARK: - Panel pieces

/// A titled, rounded group of rows.
private struct PanelGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07)))
        }
    }
}

/// A label on the left, its control on the right.
private struct PanelRow<Value: View>: View {
    let label: LocalizedStringKey
    var divider = true
    @ViewBuilder let value: Value

    init(_ label: LocalizedStringKey, divider: Bool = true, @ViewBuilder value: () -> Value) {
        self.label = label
        self.divider = divider
        self.value = value()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label)
                Spacer(minLength: 8)
                value.foregroundStyle(.secondary)
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            if divider {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 14)
            }
        }
    }
}

/// A value that opens a menu of choices.
private struct PanelMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var fallback = "—"
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection = value }
            }
        } label: {
            let title = Text(options.first { $0.0 == selection }?.1 ?? fallback)
            enabled ? title + Text("  ") + MenuChevron.text : title
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The up-down mark after a menu's value.
private enum MenuChevron {
    static var text: Text {
        Text(Image(systemName: "chevron.up.chevron.down"))
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(.secondary)
    }
}

/// Rounded buttons in the panel's look; prominent for the main action.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.7 : 0.9)
                    : Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .opacity(enabled ? 1 : 0.45)
    }
}

private struct WeekdayPicker: View {
    @Binding var weekdays: [Int]

    var body: some View {
        let names = ScheduleFormat.weekdayNames
        HStack(spacing: 3) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    if on { weekdays.removeAll { $0 == day } } else { weekdays.append(day) }
                } label: {
                    Text(names[day - 1])
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .frame(minWidth: 32, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Text

enum ScheduleText {
    static let red = Color(red: 0.95, green: 0.42, blue: 0.42)

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

    /// "Every Sat 09:00 · in 3 days", "Paused · Every Sat 09:00"…
    static func when(_ task: ScheduleTask) -> String {
        let summary = task.timing.summary
        if task.isDeleted { return summary }
        if !task.enabled { return "\(String(localized: "Paused")) · \(summary)" }
        guard let next = task.nextPlan else { return "\(summary) · \(String(localized: "No more plans"))" }
        return "\(summary) · \(relative(next))"
    }

    /// "in 3 days", "in 2 hours".
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = ScheduleFormat.locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension ScheduleTiming {
    /// A once task whose time has passed can't be resumed as it is.
    var canResume: Bool { repeatKind != .once || (onceDate ?? .distantPast) > Date() }
}

// MARK: - Store actions

extension AppStore {
    /// The panel's draft of a task: its date filled in for the date picker.
    static func formDraft(_ task: ScheduleTask) -> ScheduleTask {
        var t = task
        if t.timing.year == nil {
            let c = t.timing.calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
            t.timing.year = c.year
            t.timing.month = c.month
            t.timing.day = c.day
        }
        return t
    }

    /// The panel has changes not saved yet (or a new task).
    var schedulePanelDirty: Bool {
        guard let panel = schedulePanel else { return false }
        guard let id = panel.taskID, let task = schedules.task(id) else { return true }
        func settings(_ t: ScheduleTask) -> [AnyHashable] {
            var timing = t.timing
            if timing.repeatKind != .once {
                timing.year = nil
                timing.month = nil
                timing.day = nil
            }
            if timing.repeatKind != .weekly { timing.weekdays = [] }
            return [t.name, t.prompt, t.projectID, t.kind, timing.repeatKind, timing.hour, timing.minute,
                    timing.weekdays.sorted(), timing.year, timing.month, timing.day]
        }
        return settings(panel.draft) != settings(task)
    }

    /// Why the panel's draft can't be saved yet.
    var schedulePanelProblems: [String] {
        guard let t = schedulePanel?.draft else { return [] }
        var p: [String] = []
        if t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append(String(localized: "Enter a name.")) }
        if t.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append(String(localized: "Enter a prompt.")) }
        if project(t.projectID) == nil { p.append(String(localized: "Choose a project.")) }
        if t.timing.repeatKind == .weekly && t.timing.weekdays.isEmpty { p.append(String(localized: "Choose at least one day.")) }
        if t.timing.repeatKind == .once && !t.timing.canResume { p.append(String(localized: "Choose a time in the future.")) }
        return p
    }

    /// Saves the panel's draft (creates a new task). Returns why it couldn't.
    @discardableResult
    func saveSchedulePanel() -> String? {
        guard let panel = schedulePanel else { return nil }
        if let problem = schedulePanelProblems.first { return problem }
        var t = panel.draft
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.prompt = t.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.timing.repeatKind != .once {
            t.timing.year = nil
            t.timing.month = nil
            t.timing.day = nil
        }
        if panel.isNew {
            schedules.create(t)
        } else if let problem = schedules.applyEdit(t) {
            return problem
        }
        showScheduledTask(t.id, page: false)
        return nil
    }

    /// Drops the panel's changes; a new task's panel closes.
    func cancelSchedulePanel() {
        guard let id = schedulePanel?.taskID, let task = schedules.task(id) else { return schedulePanel = nil }
        schedulePanel?.draft = Self.formDraft(task)
    }

    /// Opens a task in the panel; with `page`, on the scheduled-task page.
    func showScheduledTask(_ id: UUID, page: Bool = true) {
        guard let task = schedules.task(id) else { return }
        schedulePanel = SchedulePanel(taskID: id, draft: Self.formDraft(task))
        if page { showSchedules() }
    }

    func newScheduledTask(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        var timing = ScheduleTiming()
        let c = timing.calendar.dateComponents([.weekday], from: Date().addingTimeInterval(86400))
        timing.weekdays = [c.weekday ?? 7]
        let task = ScheduleTask(name: "", projectID: project.id, kind: defaultKind(project), prompt: "", timing: timing)
        schedulePanel = SchedulePanel(taskID: nil, draft: Self.formDraft(task))
    }

    /// The same panel, filled in by an agent.
    func newScheduledTask(filledIn task: ScheduleTask) {
        schedulePanel = SchedulePanel(taskID: nil, draft: Self.formDraft(task))
    }

    /// A task in the panel with an agent's changes filled in, not saved yet.
    func editScheduledTask(_ changed: ScheduleTask) {
        schedulePanel = SchedulePanel(taskID: changed.id, draft: Self.formDraft(changed))
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
