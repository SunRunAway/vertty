import AppKit
import Foundation

/// Starting and following scheduled runs. A task's first run starts a new session
/// in a new card; every later run resumes that session with the prompt as the
/// agent's argument. If the session is open in a card, that card's agent is
/// stopped first (a known v1 trade-off: it can interrupt the user).
extension AppStore {
    func startSchedules() {
        schedules.load()
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
                              kind: task.kind, sessionID: task.sessionID)
        if schedules.openRun(of: task.id) != nil {
            run.state = .skipped
            run.phase = nil
            run.endedAt = Date()
            run.reason = String(localized: "The previous run hasn't finished.")
            schedules.add(run)
            return
        }
        guard let project = project(task.projectID) else {
            return fail(&run, String(localized: "The task's project is no longer in Vhostty."))
        }
        guard FileManager.default.fileExists(atPath: project.path) else {
            return fail(&run, String(localized: "The project directory doesn't exist: \(project.path)"))
        }
        run.cwd = project.path
        schedules.add(run)
        let runID = run.id
        schedulePreparing.insert(runID)
        let sessionID = task.sessionID ?? ""
        let kind = task.kind
        // A first run whose session id wasn't confirmed: look for that session
        // before starting yet another one.
        let earlier = sessionID.isEmpty
            ? schedules.runs(of: task.id).filter { $0.kind == kind }.compactMap(\.sessionID).first { !$0.isEmpty } : nil
        infoQueue.async { [weak self] in
            let check = sessionID.isEmpty
                ? Self.checkSession(kind: kind, sessionID: earlier, confirmed: false, projectPath: project.path)
                : Self.checkSession(kind: kind, sessionID: sessionID, confirmed: true, projectPath: project.path)
            DispatchQueue.main.async {
                guard let self, self.schedules.run(runID)?.state == .running else {
                    self?.schedulePreparing.remove(runID)
                    return
                }
                switch check {
                case .new:
                    self.startFirstSession(runID, task, project)
                case .resume(let id, let cwd):
                    if task.sessionID != id { self.schedules.modify(task.id) { $0.sessionID = id } }
                    self.schedules.modifyRun(runID) { $0.sessionID = id; $0.cwd = cwd }
                    self.resumeSession(runID, task, id, project)
                case .fail(let reason):
                    self.schedulePreparing.remove(runID)
                    self.schedules.modifyRun(runID) { self.markFailed(&$0, reason) }
                }
            }
        }
    }

    private enum SessionCheck {
        case new
        case resume(String, cwd: String?)
        case fail(String)
    }

    /// Whether the task's session can be resumed, off the main thread. A session
    /// running outside Vhostty (another terminal, a background job) isn't touched:
    /// resuming it there would fork it. An unconfirmed id (a first run that may
    /// not have got as far as creating its session) that isn't found means new.
    private static func checkSession(kind: AgentKind, sessionID: String?, confirmed: Bool, projectPath: String) -> SessionCheck {
        guard let sessionID, !sessionID.isEmpty else { return .new }
        let fm = FileManager.default
        switch kind {
        case .claude:
            guard let url = Transcript.locate(sessionID: sessionID, projectPath: projectPath) else {
                return confirmed ? .fail(String(localized: "The task's session record can't be found.")) : .new
            }
            if LiveSessions.backgroundJobRunning(sessionID: sessionID) {
                return .fail(String(localized: "The session is running as a background job (claude attach). It wasn't touched."))
            }
            let cwd = Transcript.read(url)?.cwd
            if let cwd, !fm.fileExists(atPath: cwd) {
                return .fail(String(localized: "The session's directory doesn't exist: \(cwd)"))
            }
            return .resume(sessionID, cwd: cwd)
        case .codex:
            guard let found = CodexThreads.lookUp(id: sessionID) else {
                return .fail(String(localized: "Codex's session records couldn't be read."))
            }
            guard let thread = found else {
                return confirmed ? .fail(String(localized: "The task's session record can't be found.")) : .new
            }
            if !thread.cwd.isEmpty, !fm.fileExists(atPath: thread.cwd) {
                return .fail(String(localized: "The session's directory doesn't exist: \(thread.cwd)"))
            }
            return .resume(sessionID, cwd: thread.cwd.nonEmpty)
        }
    }

    /// The first run: a new card on top of the project, started in the background.
    private func startFirstSession(_ runID: UUID, _ task: ScheduleTask, _ project: Project) {
        let sessionID = task.kind == .claude ? UUID().uuidString.lowercased() : ""
        let tab = TabSession(projectID: project.id, kind: task.kind, sessionID: sessionID, cwd: project.path, title: task.name)
        tab.scheduleTaskID = task.id
        insertAtTopOfProject(tab)
        if !sessionID.isEmpty { schedules.modifyRun(runID) { $0.sessionID = sessionID } }
        launchRun(tab, task, runID)
    }

    private func launchRun(_ tab: TabSession, _ task: ScheduleTask, _ runID: UUID) {
        schedulePreparing.remove(runID)
        schedules.modifyRun(runID) { $0.launchedAt = Date() }
        launch(tab, prompt: task.prompt, scheduleRunID: runID)
    }

    /// A later run: stop the session's card if it's running, then resume in it
    /// (or in a new card when none is open).
    private func resumeSession(_ runID: UUID, _ task: ScheduleTask, _ sessionID: String, _ project: Project) {
        let tab = tabs.first { $0.kind == task.kind && $0.sessionID == sessionID }
        infoQueue.async { [weak self] in
            // Claude: a live process of this session outside that card is someone else's.
            let outside = task.kind == .claude
                ? LiveSessions.processes(sessionID: sessionID).filter { $0.tab == nil || $0.tab != tab?.id } : []
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.schedules.run(runID)?.state == .running else { self.schedulePreparing.remove(runID); return }
                // Meanwhile the card may have moved to another session (/clear, /new,
                // /resume) or another card may have opened this one: check again.
                guard self.tabs.first(where: { $0.kind == task.kind && $0.sessionID == sessionID }) === tab,
                      tab.map({ t in self.tabs.contains { $0 === t } }) ?? true else {
                    return self.resumeSession(runID, task, sessionID, project)
                }
                guard outside.isEmpty else {
                    self.schedulePreparing.remove(runID)
                    return self.schedules.modifyRun(runID) {
                        self.markFailed(&$0, String(localized: "The session is open outside this Vhostty window. It wasn't touched."))
                    }
                }
                guard let tab else {
                    let card = TabSession(projectID: project.id, kind: task.kind, sessionID: sessionID, cwd: project.path,
                                          title: task.name)
                    card.scheduleTaskID = task.id
                    self.insertAtTopOfProject(card)
                    self.launchRun(card, task, runID)
                    return
                }
                // Even with its terminal gone, the card's agent may not be (a stop
                // that couldn't be confirmed): check before starting another.
                self.stopAndResume(tab, runID: runID, task: task)
            }
        }
    }

    /// Ends the card's terminal (its agent with it), waits until that agent is
    /// really gone, then resumes in the same card. Never starts a second instance.
    private func stopAndResume(_ tab: TabSession, runID: UUID, task: ScheduleTask) {
        scheduleStoppingTabs.insert(tab.id)
        // The run joins the card only once it relaunches: hooks of the instance
        // being stopped (its SessionEnd) aren't this run's.
        tab.scheduleRunID = nil
        let wasShown = tab.id == selectedTabID
        if wasShown { showInContainer(nil) }
        tab.surface = nil
        let tabID = tab.id
        let sessionID = tab.sessionID
        let kind = tab.kind
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            var signalled = false
            var alive = Self.agentProcesses(kind: kind, tabID: tabID, sessionID: sessionID)
            while !alive.isEmpty && Date() < deadline {
                // The terminal hung up on it; give it a few seconds, then ask once more.
                if !signalled && deadline.timeIntervalSinceNow < 6 {
                    alive.forEach { kill($0, SIGTERM) }
                    signalled = true
                }
                Thread.sleep(forTimeInterval: 0.25)
                alive = Self.agentProcesses(kind: kind, tabID: tabID, sessionID: sessionID)
            }
            let stopped = alive.isEmpty
            // Let hook events the old instance sent reach the app before the new one starts.
            if stopped { Thread.sleep(forTimeInterval: 0.5) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scheduleStoppingTabs.remove(tabID)
                guard self.schedules.run(runID)?.state == .running else { self.schedulePreparing.remove(runID); return }
                guard self.tabs.contains(where: { $0 === tab }), tab.kind == kind, tab.sessionID == sessionID else {
                    self.schedulePreparing.remove(runID)
                    return self.schedules.modifyRun(runID) {
                        self.markFailed(&$0, String(localized: "The session's card changed while it was being stopped, so nothing was resumed."))
                    }
                }
                guard stopped else {
                    self.schedulePreparing.remove(runID)
                    return self.schedules.modifyRun(runID) {
                        self.markFailed(&$0, String(localized: "The session's earlier instance couldn't be confirmed stopped, so it wasn't resumed."))
                    }
                }
                self.launchRun(tab, task, runID)
                if tab.id == self.selectedTabID { self.showInContainer(tab) }
            }
        }
    }

    /// The agent processes still running for a card: Claude by its session
    /// registry, Codex by the TUI started with Vhostty's title option.
    private static func agentProcesses(kind: AgentKind, tabID: UUID, sessionID: String) -> [pid_t] {
        switch kind {
        case .claude:
            // Also its hook helper: a SessionEnd hook still on its way would land on the resumed run.
            let helpers = ProcessScan.processes(withEnv: "VHOSTTY_TAB_ID", tabID.uuidString).filter { p in
                let name = (p.args.first.map { ($0 as NSString).lastPathComponent }) ?? ""
                return name == "claude" || name == "vhostty-hook"
            }.map(\.pid)
            return Array(Set(LiveSessions.processes(sessionID: sessionID).filter { $0.tab == tabID }.map(\.pid) + helpers))
        case .codex:
            return ProcessScan.processes(withEnv: "VHOSTTY_TAB_ID", tabID.uuidString)
                .filter { $0.args.contains { $0.contains("tui.terminal_title") } }.map(\.pid)
        }
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

    /// A first-run Codex card learned its thread id.
    func scheduleSessionKnown(_ tab: TabSession) {
        guard let runID = tab.scheduleRunID, let run = schedules.run(runID) else { return }
        bindSession(tab, run)
    }

    /// The session a first run created becomes the task's for good.
    private func bindSession(_ tab: TabSession, _ run: ScheduleRun) {
        guard !tab.sessionID.isEmpty else { return }
        if run.sessionID != tab.sessionID { schedules.modifyRun(run.id) { $0.sessionID = tab.sessionID } }
        if let task = schedules.task(run.taskID), !task.isBound {
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
        for run in schedules.runs where run.state == .running && !schedulePreparing.contains(run.id) {
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
            case .claude: evaluateClaude(run, tab, age)
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

    /// Opens a run's (or task's) session: its card, or a resumed card when closed.
    func openScheduleSession(kind: AgentKind, sessionID: String, projectID: UUID, title: String) {
        if let tab = tabs.first(where: { $0.sessionID == sessionID }) {
            if let p = project(tab.projectID), !p.expanded { toggleExpanded(p) }
            return select(tab)
        }
        guard let project = project(projectID) else { return }
        let summary = SessionSummary(id: sessionID, title: title, modified: Date(), path: URL(fileURLWithPath: "/"), kind: kind)
        resumeSession(summary, in: project)
    }

    func showSchedules() {
        showingSchedules = true
        showInContainer(nil)
    }
}
