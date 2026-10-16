import Foundation

/// Scheduled tasks and their runs, saved in schedules.json beside the app state.
/// Planning lives here; starting runs is AppStore's (ScheduleRunner.swift).
final class ScheduleStore: ObservableObject {
    @Published private(set) var tasks: [ScheduleTask] = []
    @Published private(set) var runs: [ScheduleRun] = []

    private var url: URL { AppPaths.support.appendingPathComponent("schedules.json") }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let file: ScheduleFile
        do {
            file = try JSONDecoder.schedule.decode(ScheduleFile.self, from: data)
        } catch {
            // Unreadable (damaged, or written by a newer Vertty): keep it aside
            // rather than let the next save overwrite it with nothing.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("Vertty: couldn't read scheduled tasks (%@); moved to %@", error.localizedDescription, aside.path)
            return
        }
        tasks = file.tasks
        runs = file.runs
        // Runs left running by the last launch: their terminals are gone.
        var changed = false
        for i in runs.indices where runs[i].state == .running {
            runs[i].state = .failed
            runs[i].phase = nil
            runs[i].reason = String(localized: "Vertty quit during the run.")
            changed = true
        }
        if changed { save() }
    }

    /// Written at once: a claimed plan must be on disk before its prompt goes out.
    @discardableResult
    func save() -> Bool {
        let file = ScheduleFile(tasks: tasks, runs: runs)
        do {
            try JSONEncoder.schedule.encode(file).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Vertty: couldn't save scheduled tasks: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Queries

    func task(_ id: UUID) -> ScheduleTask? { tasks.first { $0.id == id } }

    var activeTasks: [ScheduleTask] { tasks.filter { !$0.isDeleted } }
    var deletedTasks: [ScheduleTask] { tasks.filter(\.isDeleted).sorted { $0.deletedAt! > $1.deletedAt! } }

    /// Ended by hand, or by the scheduled run for the current one-time plan.
    /// Manual reruns do not change the scheduling lifecycle.
    func state(of task: ScheduleTask) -> ScheduleState {
        if task.isDeleted { return .deleted }
        if task.endedAt != nil { return .ended }
        if !task.enabled { return .paused }
        if task.timing.repeatKind == .once, task.nextPlan == nil,
           let plannedAt = task.timing.onceDate,
           let run = runs.last(where: {
               $0.taskID == task.id && $0.trigger != .manual && $0.plannedAt == plannedAt
           }), run.state != .running {
            return .ended
        }
        return .active
    }

    /// Project and agent are fixed once the task has its session, or while its
    /// first run is creating it.
    func sessionFixed(_ task: ScheduleTask) -> Bool {
        task.isBound || openRun(of: task.id) != nil
    }

    /// The task whose session this is.
    func task(forSession id: String) -> ScheduleTask? {
        guard !id.isEmpty else { return nil }
        return tasks.first { $0.sessionID == id }
    }

    func runs(of taskID: UUID) -> [ScheduleRun] {
        runs.filter { $0.taskID == taskID }.sorted { $0.startedAt > $1.startedAt }
    }

    func run(_ id: UUID) -> ScheduleRun? { runs.first { $0.id == id } }

    /// The task's run going on now, if any.
    func openRun(of taskID: UUID) -> ScheduleRun? {
        runs.last { $0.taskID == taskID && $0.state == .running }
    }

    /// What the list shows: a running run first (a later skip mustn't hide it), else the latest.
    func shownRun(of taskID: UUID) -> ScheduleRun? {
        openRun(of: taskID) ?? runs.last { $0.taskID == taskID }
    }

    // MARK: - Changes

    @discardableResult
    func create(_ task: ScheduleTask) -> Bool {
        var t = task
        t.createdAt = Date()
        t.nextPlan = t.enabled ? t.timing.next(after: Date()) : nil
        tasks.append(t)
        guard save() else {
            tasks.removeLast()
            return false
        }
        return true
    }

    /// Applies an edit's settings (name, prompt, schedule, project, agent) to the
    /// task as it is now, keeping what the scheduler changed meanwhile (next plan,
    /// session). Edits only affect later runs; a new time rule plans from now on,
    /// without catching up what the old rule missed. Returns why it can't apply.
    @discardableResult
    func applyEdit(_ edit: ScheduleTask) -> String? {
        guard let i = tasks.firstIndex(where: { $0.id == edit.id }), !tasks[i].isDeleted else {
            return String(localized: "The task no longer exists.")
        }
        var t = tasks[i]
        // The task may have got its session since the edit was made.
        if sessionFixed(t) && (edit.projectID != t.projectID || edit.kind != t.kind) {
            return String(localized: "The task has its session now, so its project and agent can't change.")
        }
        t.name = edit.name
        t.prompt = edit.prompt
        t.projectID = edit.projectID
        t.kind = edit.kind
        if edit.timing != t.timing {
            t.timing = edit.timing
            // A task ended by hand starts again with its new schedule.
            t.endedAt = nil
            t.nextPlan = t.enabled ? t.timing.next(after: Date()) : nil
        }
        let previous = tasks[i]
        tasks[i] = t
        guard save() else {
            tasks[i] = previous
            return String(localized: "Couldn’t save the task.")
        }
        return nil
    }

    func modify(_ id: UUID, _ body: (inout ScheduleTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&tasks[i])
        save()
    }

    /// Pause keeps the current run going. Resume plans from now: nothing missed
    /// while paused (or before) is caught up.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let task = task(id), !task.isDeleted, state(of: task) != .ended else { return }
        if enabled && task.timing.next(after: Date()) == nil { return }
        modify(id) { t in
            t.enabled = enabled
            t.nextPlan = enabled ? t.timing.next(after: Date()) : nil
        }
    }

    /// Ends the task by hand: no more plans, a run going on keeps going.
    /// Editing its schedule enables it again, even if it was paused.
    @discardableResult
    func end(_ id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let previous = tasks[i]
        tasks[i].endedAt = Date()
        tasks[i].enabled = true
        tasks[i].nextPlan = nil
        guard save() else {
            tasks[i] = previous
            return false
        }
        return true
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let previous = tasks[i]
        tasks[i].deletedAt = Date()
        tasks[i].enabled = false
        tasks[i].nextPlan = nil
        guard save() else {
            tasks[i] = previous
            return false
        }
        return true
    }

    func add(_ run: ScheduleRun) {
        runs.append(run)
        save()
    }

    func modifyRun(_ id: UUID, _ body: (inout ScheduleRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[i])
        save()
    }

    /// A project was added again after being removed: its tasks (found by the
    /// directory their runs used) go back to it.
    func projectAdded(_ projectID: UUID, path: String, known: Set<UUID>) {
        var changed = false
        for i in tasks.indices where !known.contains(tasks[i].projectID) {
            let id = tasks[i].id
            guard runs.contains(where: { $0.taskID == id && $0.cwd == path }) else { continue }
            tasks[i].projectID = projectID
            changed = true
        }
        if changed { save() }
    }

    /// The Mac's time zone changed: plans follow its wall clock.
    func timeZoneChanged() {
        for i in tasks.indices where tasks[i].enabled && !tasks[i].isDeleted && tasks[i].endedAt == nil {
            tasks[i].nextPlan = tasks[i].timing.next(after: Date())
        }
        save()
    }

    // MARK: - Planning

    struct Due {
        let task: ScheduleTask
        let plannedAt: Date
        let trigger: RunTrigger
    }

    /// Takes every plan that is due. Only the latest plan of a task runs; earlier
    /// ones (missed while asleep or quit) are dropped. Each plan is
    /// claimed (saved as handled) before it's returned, so it can't run twice.
    func claimDue(now: Date = Date()) -> [Due] {
        let before = tasks
        var due: [Due] = []
        for i in tasks.indices {
            let t = tasks[i]
            guard t.enabled, !t.isDeleted, let first = t.nextPlan, first <= now else { continue }
            var plans = [first]
            while plans.count < 10_000, let n = t.timing.next(after: plans.last!), n <= now { plans.append(n) }
            // Missed plans: only the latest runs.
            let latest = plans.last!
            tasks[i].nextPlan = t.timing.next(after: now)
            // Late by more than a couple of minutes: that's catching up, not on time.
            due.append(Due(task: tasks[i], plannedAt: latest, trigger: now.timeIntervalSince(latest) > 120 ? .catchUp : .scheduled))
        }
        // Unsaved, a claim could run again after a restart: then don't run it now.
        if !due.isEmpty && !save() {
            tasks = before
            return []
        }
        return due
    }
}

extension JSONEncoder {
    static var schedule: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var schedule: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
