import Foundation

/// Scheduled tasks and their runs, saved in schedules.json beside the app state.
/// Planning lives here; starting runs is AppStore's (ScheduleRunner.swift).
final class ScheduleStore: ObservableObject {
    @Published private(set) var tasks: [ScheduleTask] = []
    @Published private(set) var runs: [ScheduleRun] = []
    @Published private(set) var drafts: [ScheduleDraft] = []

    private var url: URL { AppPaths.support.appendingPathComponent("schedules.json") }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder.schedule.decode(ScheduleFile.self, from: data) else { return }
        tasks = file.tasks
        runs = file.runs
        drafts = file.drafts ?? []
        // Runs left running by the last launch: their terminals are gone, but
        // whether their turn finished is unknown, so don't count them as done.
        var changed = false
        for i in runs.indices where runs[i].state == .running {
            runs[i].state = .failed
            runs[i].phase = nil
            runs[i].unresolved = true
            runs[i].reason = String(localized: "Vhostty quit while this run was going. Its result is unknown.")
            changed = true
        }
        if changed { save() }
    }

    /// Written at once: a claimed plan must be on disk before its prompt goes out.
    @discardableResult
    func save() -> Bool {
        let file = ScheduleFile(tasks: tasks, runs: runs, drafts: drafts)
        do {
            try JSONEncoder.schedule.encode(file).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Vhostty: couldn't save scheduled tasks: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Queries

    func task(_ id: UUID) -> ScheduleTask? { tasks.first { $0.id == id } }

    var activeTasks: [ScheduleTask] { tasks.filter { !$0.isDeleted } }
    var deletedTasks: [ScheduleTask] { tasks.filter(\.isDeleted).sorted { $0.deletedAt! > $1.deletedAt! } }

    /// The task whose session this is.
    func task(forSession id: String) -> ScheduleTask? {
        guard !id.isEmpty else { return nil }
        return tasks.first { $0.sessionID == id }
    }

    func runs(of taskID: UUID) -> [ScheduleRun] {
        runs.filter { $0.taskID == taskID }.sorted { $0.startedAt > $1.startedAt }
    }

    func run(_ id: UUID) -> ScheduleRun? { runs.first { $0.id == id } }

    /// The run still holding the task (running or unresolved), if any.
    func openRun(of taskID: UUID) -> ScheduleRun? {
        runs.last { $0.taskID == taskID && $0.isOpen }
    }

    /// What the list shows: an open run first (a later skip mustn't hide it), else the latest.
    func shownRun(of taskID: UUID) -> ScheduleRun? {
        openRun(of: taskID) ?? runs.last { $0.taskID == taskID }
    }

    // MARK: - Changes

    func create(_ task: ScheduleTask) {
        var t = task
        t.createdAt = Date()
        t.nextPlan = t.enabled ? t.timing.next(after: Date()) : nil
        tasks.append(t)
        save()
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
        if t.isBound && (edit.projectID != t.projectID || edit.kind != t.kind) {
            return String(localized: "The task has its session now, so its project and agent can't change.")
        }
        t.name = edit.name
        t.prompt = edit.prompt
        t.projectID = edit.projectID
        t.kind = edit.kind
        if edit.timing != t.timing {
            t.timing = edit.timing
            t.nextPlan = t.enabled ? t.timing.next(after: Date()) : nil
        }
        tasks[i] = t
        save()
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
        modify(id) { t in
            t.enabled = enabled
            t.nextPlan = enabled ? t.timing.next(after: Date()) : nil
            if enabled { t.reviewNote = nil }
        }
    }

    func delete(_ id: UUID) {
        modify(id) { t in
            t.deletedAt = Date()
            t.enabled = false
            t.nextPlan = nil
        }
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

    /// "End this record": frees the task from an unresolved run. Stops nothing.
    func endRecord(_ id: UUID) {
        modifyRun(id) { r in
            r.unresolved = nil
            r.resolvedByUser = true
            if r.state == .running {
                r.state = .failed
                r.phase = nil
            }
            r.endedAt = r.endedAt ?? Date()
        }
    }

    /// A project was removed or moved: pause its tasks until the user checks them.
    func projectChanged(_ projectID: UUID, note: String) {
        for i in tasks.indices where tasks[i].projectID == projectID && !tasks[i].isDeleted {
            tasks[i].enabled = false
            tasks[i].nextPlan = nil
            tasks[i].reviewNote = note
        }
        save()
    }

    // MARK: - Drafts

    var pendingDrafts: [ScheduleDraft] { drafts.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt } }

    func draft(_ id: UUID) -> ScheduleDraft? { drafts.first { $0.id == id } }

    /// Adds a draft; the same request already waiting is returned instead of a duplicate.
    func submit(_ draft: ScheduleDraft) -> ScheduleDraft {
        if let same = pendingDrafts.first(where: { d in
            d.action == draft.action && d.taskID == draft.taskID && d.sourceTabID == draft.sourceTabID
                && Self.sameContent(d.task, draft.task)
        }) { return same }
        drafts.append(draft)
        save()
        return draft
    }

    private static func sameContent(_ a: ScheduleTask?, _ b: ScheduleTask?) -> Bool {
        guard var a, var b else { return a == nil && b == nil }
        a.id = b.id
        a.createdAt = b.createdAt
        return a == b
    }

    func decide(_ id: UUID, _ status: DraftStatus, taskID: UUID? = nil) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), drafts[i].status == .pending else { return }
        drafts[i].status = status
        drafts[i].decidedAt = Date()
        if let taskID { drafts[i].taskID = taskID }
        save()
    }

    // MARK: - Planning

    struct Due {
        let task: ScheduleTask
        let plannedAt: Date
        let trigger: RunTrigger
    }

    /// Takes every plan that is due. Only the latest plan of a task runs; earlier
    /// ones (missed while asleep or quit) become one skip record. Each plan is
    /// claimed (saved as handled) before it's returned, so it can't run twice.
    func claimDue(now: Date = Date()) -> [Due] {
        let before = (tasks, runs)
        var due: [Due] = []
        for i in tasks.indices {
            let t = tasks[i]
            guard t.enabled, !t.isDeleted, let first = t.nextPlan, first <= now else { continue }
            var plans = [first]
            while plans.count < 10_000, let n = t.timing.next(after: plans.last!), n <= now { plans.append(n) }
            let latest = plans.removeLast()
            if let missed = plans.last {
                runs.append(ScheduleRun(
                    taskID: t.id, trigger: .catchUp, plannedAt: missed, endedAt: now, state: .skipped,
                    reason: String(localized: "Missed while Vhostty wasn't running or the Mac was asleep. Only the latest one is caught up."),
                    skippedCount: plans.count, skippedFrom: plans.first,
                    kind: t.kind, sessionID: t.sessionID, prompt: t.prompt, timingSummary: t.timing.summaryWithZone))
            }
            tasks[i].nextPlan = t.timing.next(after: now)
            // Late by more than a couple of minutes: that's catching up, not on time.
            due.append(Due(task: tasks[i], plannedAt: latest, trigger: now.timeIntervalSince(latest) > 120 ? .catchUp : .scheduled))
        }
        // Unsaved, a claim could run again after a restart: then don't run it now.
        if !due.isEmpty && !save() {
            (tasks, runs) = before
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
