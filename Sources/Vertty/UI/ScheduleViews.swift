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
    @State private var showEnded = false

    var body: some View {
        let ended = schedules.activeTasks.filter { task in
            schedules.state(of: task) == .ended && schedules.openRun(of: task.id) == nil
        }
        let endedIDs = Set(ended.map(\.id))
        let active = schedules.activeTasks.filter { !endedIDs.contains($0.id) }
        let deleted = schedules.deletedTasks
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if active.isEmpty && ended.isEmpty {
                    emptyState
                } else {
                    ForEach(groups(active), id: \.0) { projectID, tasks in
                        section(projectID, tasks)
                    }
                }
                if !ended.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showEnded.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showEnded ? 90 : 0))
                                Text("Ended (\(ended.count))")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showEnded { rows(ended) }
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
        .onTapGesture { store.openScheduledTask(task.id) }
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
        if schedules.state(of: task) == .active {
            Button("Pause") { schedules.setEnabled(task.id, false) }
        } else {
            Button("Resume") { schedules.setEnabled(task.id, true) }
                .disabled(schedules.state(of: task) == .ended || store.project(task.projectID) == nil || !task.timing.canResume)
        }
        if schedules.state(of: task) != .ended {
            Button("End") { schedules.end(task.id) }
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
                if schedules.state(of: task) == .active {
                    IconButton(systemName: "pause", help: "Pause") { schedules.setEnabled(task.id, false) }
                } else {
                    IconButton(systemName: "arrow.clockwise", help: schedules.state(of: task) == .ended ? "Edit the schedule before resuming." : "Resume") { schedules.setEnabled(task.id, true) }
                        .disabled(schedules.state(of: task) == .ended || store.project(task.projectID) == nil || !task.timing.canResume)
                }
                IconMenu { ScheduleActions(store: store, schedules: schedules, task: task) }
            }
            IconButton(systemName: "xmark", help: "Close") { store.closeSchedulePanel() }
                .padding(.trailing, 8)
        }
        .frame(height: Chrome.titleStripHeight)
        .background(WindowDragArea())
    }

    private var statusTitle: String {
        guard let task else { return String(localized: "New Scheduled Task") }
        switch schedules.state(of: task) {
        case .active: return String(localized: "Active")
        case .paused: return String(localized: "Paused")
        case .ended: return String(localized: "Ended")
        case .deleted: return String(localized: "Deleted")
        }
    }

    private var statusColor: Color {
        guard let task, !task.isDeleted else { return .secondary }
        return schedules.state(of: task) == .active ? Color(red: 0.35, green: 0.62, blue: 1.0) : .secondary
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
                        DatePicker("", selection: onceDay, displayedComponents: .date)
                            .environment(\.timeZone, draft.wrappedValue.timing.timeZone)
                            .environment(\.calendar, draft.wrappedValue.timing.calendar)
                            .labelsHidden().fixedSize()
                    }
                }
                PanelRow("Time") {
                    DatePicker("", selection: timeOfDay, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, Self.clockCalendar.timeZone)
                        .environment(\.calendar, Self.clockCalendar)
                        .labelsHidden().fixedSize()
                }
                PanelRow("Time Zone", divider: false) {
                    ScheduleTimeZonePicker(selection: draft.timing.timeZoneID)
                }
            }
            Text("Times follow the selected zone, including daylight saving changes.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Text(nextLine)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private var nextLine: String {
        let t = draft.wrappedValue
        guard let next = t.timing.next(after: Date()) else { return String(localized: "No more plans") }
        if let task, task.endedAt != nil, !store.schedulePanelDirty { return String(localized: "No more plans") }
        if let task, !task.enabled, !store.schedulePanelDirty { return String(localized: "Paused") }
        let date = ScheduleFormat.dateTime(next, timeZone: t.timing.timeZone)
        let zoned = t.timing.timeZoneID.map { "\(date) · \($0)" } ?? date
        return String(localized: "Next: \(zoned) · \(ScheduleText.relative(next))")
    }

    /// A time-only picker needs a neutral date: a DST gap today must not change
    /// the stored hour, even if the task is meant to run on a different day.
    private static var clockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var timeOfDay: Binding<Date> {
        Binding(get: {
            let t = draft.wrappedValue.timing
            return Self.clockCalendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: t.hour, minute: t.minute))!
        }, set: { date in
            let c = Self.clockCalendar.dateComponents([.hour, .minute], from: date)
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

/// Searchable region names, with common US zones near the top.
private struct ScheduleTimeZonePicker: View {
    @Binding var selection: String?
    @State private var showing = false
    @State private var search = ""

    private static let zones: [String] = {
        let common = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "UTC"]
        return common + TimeZone.knownTimeZoneIdentifiers.sorted().filter { !common.contains($0) }
    }()

    private var title: String { selection ?? String(localized: "Follow System") }

    var body: some View {
        Button { search = ""; showing.toggle() } label: {
            (Text(title) + Text("  ") + MenuChevron.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $showing, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search time zones", text: $search)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        option(nil, String(localized: "Follow System") + " · " + TimeZone.current.identifier)
                        Divider().padding(.vertical, 4)
                        ForEach(Self.zones.filter {
                            search.isEmpty || $0.replacingOccurrences(of: "_", with: " ")
                                .localizedCaseInsensitiveContains(search.replacingOccurrences(of: "_", with: " "))
                        }, id: \.self) { zone in
                            option(zone, zone)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 330, height: 310)
        }
    }

    private func option(_ zone: String?, _ label: String) -> some View {
        Button {
            selection = zone
            showing = false
        } label: {
            HStack {
                Text(label).lineLimit(1)
                Spacer(minLength: 4)
                if selection == zone { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    timing.weekdays.sorted(), timing.year, timing.month, timing.day, timing.timeZoneID]
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
            guard schedules.create(t) else { return String(localized: "Couldn’t save the task.") }
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

    /// The user opens a task (its row, a link): its own panel stays as it
    /// is, another one may be left only after asking about its edits.
    func openScheduledTask(_ id: UUID, page: Bool = true) {
        if page { showSchedules() }
        guard schedulePanel?.taskID != id else { return }
        leaveSchedulePanel { [self] in showScheduledTask(id, page: false) }
    }

    /// A task link: opens the task's panel beside what's on screen, or
    /// closes it when it's already open.
    func toggleScheduledTask(_ id: UUID) {
        if schedulePanel?.taskID == id {
            closeSchedulePanel()
        } else {
            openScheduledTask(id, page: false)
        }
    }

    /// Closes the panel, after asking if that would lose edits.
    func closeSchedulePanel() {
        leaveSchedulePanel { [self] in schedulePanel = nil }
    }

    /// Typing that closing the panel would lose: changes to a task, or a new
    /// task's name or prompt.
    private var schedulePanelHasEdits: Bool {
        guard let panel = schedulePanel else { return false }
        guard panel.isNew else { return schedulePanelDirty }
        return !(panel.draft.name + panel.draft.prompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Closes or replaces the panel by running `leave`; if that would lose
    /// edits, only once the user chooses to discard them.
    private func leaveSchedulePanel(_ leave: @escaping () -> Void) {
        guard schedulePanelHasEdits else { return leave() }
        guard window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert.informativeText = String(localized: "The changes in the task panel haven’t been saved yet.")
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard Changes")).hasDestructiveAction = true
        let handle = { (answer: NSApplication.ModalResponse) in
            if answer == .alertSecondButtonReturn { leave() }
        }
        // A sheet on the window, like the first-launch question about sleep.
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func newScheduledTask(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        leaveSchedulePanel { [self] in openNewScheduledTask(in: project) }
    }

    private func openNewScheduledTask(in project: Project) {
        var timing = ScheduleTiming()
        let c = timing.calendar.dateComponents([.weekday], from: Date().addingTimeInterval(86400))
        timing.weekdays = [c.weekday ?? 7]
        let task = ScheduleTask(name: "", projectID: project.id, kind: defaultKind(project), prompt: "", timing: timing)
        schedulePanel = SchedulePanel(taskID: nil, draft: Self.formDraft(task))
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
