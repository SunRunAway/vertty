import AppKit
import Foundation

extension AppStore {
    func startSchedules() {
        schedules.load()
        for project in projects {
            schedules.rememberProjectPath(project.id, path: project.path)
        }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.runDueSchedules()
        }
        // Give the login shell environment a moment, then catch up on missed plans.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runDueSchedules() }
    }

    func runDueSchedules() {
        for due in schedules.claimDue() {
            startRun(due.task, plannedAt: due.plannedAt, trigger: due.trigger)
        }
    }

    /// "Run Now": the saved configuration, once; the plan stays as it is.
    func runScheduleNow(_ id: UUID) {
        guard let task = schedules.task(id), !task.isDeleted, schedules.openRun(of: id) == nil else { return }
        startRun(task, plannedAt: nil, trigger: .manual)
    }

    private func startRun(_ task: ScheduleTask, plannedAt: Date?, trigger: RunTrigger) {
        var run = ScheduleRun(taskID: task.id, trigger: trigger, plannedAt: plannedAt, state: .running, phase: .starting,
                              kind: task.kind)
        if schedules.openRun(of: task.id) != nil {
            run.state = .skipped
            run.phase = nil
            run.endedAt = Date()
            run.reason = String(localized: "The previous run hasn't finished.")
            schedules.add(run)
            return
        }
        guard let project = project(task.projectID) else {
            return fail(&run, String(localized: "The task's project is no longer in Vertty."))
        }
        guard FileManager.default.fileExists(atPath: project.path) else {
            return fail(&run, String(localized: "The project directory doesn't exist: \(project.path)"))
        }
        run.cwd = project.path
        schedules.add(run)
        startNewSession(run.id, task, project)
    }

    private func startNewSession(_ runID: UUID, _ task: ScheduleTask, _ project: Project) {
        let sessionID = task.kind.isClaudeCode ? UUID().uuidString.lowercased() : ""
        let tab = TabSession(projectID: project.id, kind: task.kind, sessionID: sessionID, cwd: project.path, title: task.name)
        tab.scheduleTaskID = task.id
        insertAtTopOfProject(tab)
        if !sessionID.isEmpty { schedules.modifyRun(runID) { $0.sessionID = sessionID } }
        schedules.modifyRun(runID) { $0.launchedAt = Date() }
        launch(tab, prompt: task.prompt, scheduleRunID: runID)
    }

    // MARK: - Following a run

    /// Claude's hooks for a card running a scheduled turn.
    func scheduleHook(_ tab: TabSession, _ event: HookEvent) {
        guard let runID = tab.scheduleRunID, let run = schedules.run(runID), run.state == .running else { return }
        switch event.name {
        case "SessionStart":
            bindSession(tab, run)
        case "UserPromptSubmit":
            bindSession(tab, run)
            schedules.modifyRun(runID) { $0.phase = .executing }
        case "Notification":
            if tab.status == .needsInput { schedules.modifyRun(runID) { $0.phase = .needsInput } }
        case "Stop":
            guard run.phase != .starting else { return }
            finish(tab, runID)
        case "SessionEnd":
            tab.scheduleRunID = nil
            schedules.modifyRun(runID) { self.markFailed(&$0, String(localized: "Claude exited before the turn finished.")) }
        default:
            break
        }
    }

    func scheduleSessionKnown(_ tab: TabSession) {
        guard let runID = tab.scheduleRunID, let run = schedules.run(runID) else { return }
        bindSession(tab, run)
    }

    private func bindSession(_ tab: TabSession, _ run: ScheduleRun) {
        guard !tab.sessionID.isEmpty else { return }
        if run.sessionID != tab.sessionID { schedules.modifyRun(run.id) { $0.sessionID = tab.sessionID } }
        if let task = schedules.task(run.taskID), task.sessionID != tab.sessionID {
            schedules.modify(task.id) { $0.sessionID = tab.sessionID }
        }
    }

    private func finish(_ tab: TabSession, _ runID: UUID) {
        tab.scheduleRunID = nil
        scheduleIdleSince.removeValue(forKey: runID)
        schedules.modifyRun(runID) { r in
            r.state = .replied
            r.phase = nil
            r.endedAt = Date()
        }
    }

    /// Polled with the other card info (every few seconds): what hooks can't tell.
    func evaluateScheduleRuns() {
        for run in schedules.runs where run.state == .running {
            guard let tab = tabs.first(where: { $0.scheduleRunID == run.id }) else {
                // Launched, and no card carries it any more.
                schedules.modifyRun(run.id) { self.markFailed(&$0, String(localized: "The session's card was closed during the run.")) }
                continue
            }
            guard tab.surface != nil else { continue }
            let age = Date().timeIntervalSince(run.launchedAt ?? run.startedAt)
            if tab.status == .exited {
                tab.scheduleRunID = nil
                schedules.modifyRun(run.id) { self.markFailed(&$0, String(localized: "\(run.kind.name) exited before the turn finished.")) }
                continue
            }
            switch run.kind {
            case .claude, .deepseekClaude: evaluateClaude(run, tab, age)
            case .codex: evaluateCodex(run, tab, age)
            }
        }
    }

    private func evaluateClaude(_ run: ScheduleRun, _ tab: TabSession, _ age: TimeInterval) {
        switch run.phase {
        case .starting?:
            // No Claude process ever showed up (not installed, failed to start…).
            if age > 45, livePIDs[tab.id] == nil, !tab.hooksActive {
                tab.scheduleRunID = nil
                schedules.modifyRun(run.id) { self.markFailed(&$0, String(localized: "Claude didn't start.")) }
            }
        case .executing?, .needsInput?:
            if tab.status == .working, run.phase == .needsInput {
                schedules.modifyRun(run.id) { $0.phase = .executing }
            }
            if tab.status == .needsInput, run.phase != .needsInput {
                schedules.modifyRun(run.id) { $0.phase = .needsInput }
            }
            // Idle without a Stop hook: the turn was cut short (Esc).
            if tab.status == .idle && !tab.titleBusy {
                let since = scheduleIdleSince[run.id] ?? Date()
                scheduleIdleSince[run.id] = since
                if Date().timeIntervalSince(since) > 10 {
                    tab.scheduleRunID = nil
                    scheduleIdleSince.removeValue(forKey: run.id)
                    schedules.modifyRun(run.id) { self.markFailed(&$0, String(localized: "The turn was interrupted.")) }
                }
            } else {
                scheduleIdleSince.removeValue(forKey: run.id)
            }
        case nil:
            break
        }
    }

    /// Codex runs no hooks: its thread history tells whether the prompt went in
    /// and whether the turn got its final answer.
    private func evaluateCodex(_ run: ScheduleRun, _ tab: TabSession, _ age: TimeInterval) {
        let threadID = tab.sessionID
        guard !threadID.isEmpty else {
            if age > 120 {
                tab.scheduleRunID = nil
                schedules.modifyRun(run.id) {
                    self.markFailed(&$0, String(localized: "Couldn't confirm that the session was created or the prompt submitted."))
                }
            }
            return
        }
        guard let prompt = schedules.task(run.taskID)?.prompt else { return }
        let since = run.startedAt.addingTimeInterval(-5)
        let idle = tab.status == .idle && !tab.titleBusy
        infoQueue.async { [weak self] in
            let progress = CodexThreads.turnProgress(threadID: threadID, prompt: prompt, since: since)
            DispatchQueue.main.async {
                guard let self, let progress, tab.scheduleRunID == run.id,
                      let current = self.schedules.run(run.id), current.state == .running else { return }
                if progress.answered || progress.status == "completed" {
                    self.finish(tab, run.id)
                } else if progress.status == "failed" || progress.status == "interrupted" {
                    tab.scheduleRunID = nil
                    self.schedules.modifyRun(run.id) {
                        self.markFailed(&$0, progress.status == "failed"
                            ? String(localized: "Codex reported an error in this turn.")
                            : String(localized: "The turn was interrupted."))
                    }
                } else if progress.submitted {
                    if current.phase == .starting { self.schedules.modifyRun(run.id) { $0.phase = .executing } }
                    // Submitted, idle, and no status recorded for the turn.
                    if progress.status == nil && idle && age > 120 {
                        tab.scheduleRunID = nil
                        self.schedules.modifyRun(run.id) {
                            self.markFailed(&$0, String(localized: "The turn stopped without an answer or a recorded status."))
                        }
                    }
                } else if idle && age > 60 {
                    // The thread may be open elsewhere (Codex then refuses the prompt).
                    tab.scheduleRunID = nil
                    self.schedules.modifyRun(run.id) {
                        self.markFailed(&$0, String(localized: "The prompt wasn't submitted. The session may be open somewhere else."))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func fail(_ run: inout ScheduleRun, _ reason: String) {
        markFailed(&run, reason)
        schedules.add(run)
    }

    func markFailed(_ run: inout ScheduleRun, _ reason: String) {
        run.state = .failed
        run.phase = nil
        run.reason = reason
        run.endedAt = Date()
    }

    func openScheduleSession(kind: AgentKind, sessionID: String, projectID: UUID, title: String) {
        if let tab = tabs.first(where: { $0.sessionID == sessionID }) {
            if let p = project(tab.projectID), !p.expanded { toggleExpanded(p) }
            return select(tab, keepingSchedulePanel: true)
        }
        guard let project = project(projectID) else { return }
        let summary = SessionSummary(id: sessionID, title: title, modified: Date(), path: URL(fileURLWithPath: "/"), kind: kind)
        resumeSession(summary, in: project, keepingSchedulePanel: true)
    }

    func showSchedules() {
        showingSchedules = true
        showInContainer(nil)
    }
}
