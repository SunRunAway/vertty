import Foundation

/// Requests from `vhostty-schedule` (the MCP server agents get their
/// scheduled-task tools from). Agents can read tasks, and pause, resume or run
/// one, as the user can with one click. Creating, editing or deleting only opens the form or
/// confirmation the user would use anyway, filled in: nothing is saved unless
/// the user confirms it there, and cancelling leaves nothing behind.
extension AppStore {
    func handleScheduleRequest(_ request: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = ["op", "taskID", "fields", "tabID", "cwd"]
        if let extra = request.keys.first(where: { !allowed.contains($0) }) {
            return error("Unknown request field: \(extra)")
        }
        guard let op = request["op"] as? String else { return error("Missing op.") }
        let source = (request["tabID"] as? String).flatMap(UUID.init(uuidString:)).flatMap(tab(withID:))
        let cwd = request["cwd"] as? String
        let taskID = (request["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let fields = request["fields"] as? [String: Any] ?? [:]

        switch op {
        case "list":
            return ["ok": true, "tasks": schedules.tasks.filter { !$0.isDeleted }.map(describe)]
        case "show":
            guard let id = taskID, let task = schedules.task(id) else { return error("No task with that id.") }
            var d = describe(task)
            d["recentRuns"] = schedules.runs(of: id).prefix(10).map(describe)
            return ["ok": true, "task": d]
        case "pause", "resume", "run":
            // The same one click as in the window: the task is one the user confirmed.
            guard let id = taskID, let task = schedules.task(id), !task.isDeleted else { return error("No task with that id.") }
            if !fields.isEmpty { return error("\(op) takes no fields.") }
            switch op {
            case "pause":
                schedules.setEnabled(id, false)
            case "resume":
                guard project(task.projectID) != nil, task.timing.canResume else {
                    return error("This task can't be resumed as it is: its project is gone or its one-time date has passed. Edit it first.")
                }
                schedules.setEnabled(id, true)
            default:
                guard project(task.projectID) != nil else { return error("The task's project is gone.") }
                guard schedules.openRun(of: id) == nil else { return error("The task is running now.") }
                runScheduleNow(id)
            }
            return ["ok": true, "task": describe(schedules.task(id)!)]
        case "create", "edit", "delete":
            guard !schedulePanelDirty, !scheduleAsking else {
                return error("A scheduled-task form is already open in Vhostty. Ask the user to finish it, then try again.")
            }
            if op == "create" {
                switch filledTask(nil, fields, source: source, cwd: cwd) {
                case .failure(let e): return error(e.message)
                case .success(let task): newScheduledTask(filledIn: task)
                }
                return opened("The New Scheduled Task form")
            }
            guard let id = taskID, let task = schedules.task(id), !task.isDeleted else { return error("No task with that id.") }
            if op == "delete" {
                if !fields.isEmpty { return error("delete takes no fields.") }
                askDeleteScheduledTask(task)
                return opened("The delete confirmation")
            }
            switch filledTask(task, fields, source: source, cwd: cwd) {
            case .failure(let e): return error(e.message)
            case .success(let changed):
                if changed == task { return error("Nothing would change.") }
                editScheduledTask(changed)
            }
            return opened("The Edit Scheduled Task form")
        default:
            return error("Unknown op: \(op)")
        }
    }

    private func opened(_ what: String) -> [String: Any] {
        ["ok": true,
         "message": "\(what) is open in Vhostty, filled in. Nothing changes unless the user confirms it there; cancelling drops it. Use list or show to see whether it took effect."]
    }

    struct APIError: Error { let message: String }

    /// Builds the task a create or edit fills in. Project and agent come from the
    /// asking session unless given, and can't change once the task has its session.
    private func filledTask(_ existing: ScheduleTask?, _ f: [String: Any], source: TabSession?,
                           cwd: String?) -> Result<ScheduleTask, APIError> {
        let known: Set<String> = ["name", "prompt", "repeat", "days", "date", "time", "project", "agent"]
        if let extra = f.keys.first(where: { !known.contains($0) }) { return .failure(APIError(message: "Unknown field: \(extra)")) }
        func str(_ k: String) -> String? { (f[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }

        var project: Project?
        if let p = str("project") {
            project = projects.first { $0.path == p || $0.name == p || $0.id.uuidString == p.uppercased() }
            guard project != nil else { return .failure(APIError(message: "No Vhostty project matches \(p).")) }
        }
        var kind: AgentKind?
        if let a = str("agent") {
            guard let k = AgentKind(rawValue: a.lowercased()) else { return .failure(APIError(message: "agent must be claude or codex.")) }
            kind = k
        }
        if let existing, schedules.sessionFixed(existing) {
            if let project, project.id != existing.projectID {
                return .failure(APIError(message: "The project is fixed once the task has its session."))
            }
            if let kind, kind != existing.kind {
                return .failure(APIError(message: "The agent is fixed once the task has its session."))
            }
        }
        var t: ScheduleTask
        if let existing {
            t = existing
        } else {
            guard let p = project ?? source.flatMap({ self.project($0.projectID) })
                    ?? cwd.flatMap({ dir in projects.filter { dir == $0.path || dir.hasPrefix($0.path + "/") }
                        .max { $0.path.count < $1.path.count } }) else {
                return .failure(APIError(message: "Say which project (--project): this isn't inside a Vhostty project."))
            }
            project = p
            t = ScheduleTask(name: "", projectID: p.id, kind: kind ?? source?.kind ?? defaultKind(p), prompt: "",
                             timing: ScheduleTiming())
            // No made-up schedule: the agent should ask rather than leave these out.
            guard str("repeat") != nil, str("time") != nil else {
                return .failure(APIError(message: "repeat and time are required."))
            }
            t.timing.weekdays = []
        }
        if let project { t.projectID = project.id }
        if let kind { t.kind = kind }
        if let v = str("name") { t.name = v }
        if let v = f["prompt"] as? String { t.prompt = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let v = str("repeat") {
            guard let r = ScheduleRepeat(rawValue: v.lowercased()) else {
                return .failure(APIError(message: "repeat must be once, daily, weekdays or weekly."))
            }
            t.timing.repeatKind = r
        }
        if let v = str("time") {
            let parts = v.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                return .failure(APIError(message: "time must be HH:MM (24-hour)."))
            }
            t.timing.hour = parts[0]
            t.timing.minute = parts[1]
        }
        if let v = str("days") {
            let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            var days: [Int] = []
            for d in v.lowercased().split(separator: ",") {
                guard let n = names[String(d.trimmingCharacters(in: .whitespaces).prefix(3))] else {
                    return .failure(APIError(message: "days are mon,tue,wed,thu,fri,sat,sun."))
                }
                if !days.contains(n) { days.append(n) }
            }
            t.timing.weekdays = days
        }
        if let v = str("date") {
            let parts = v.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return .failure(APIError(message: "date must be YYYY-MM-DD.")) }
            t.timing.year = parts[0]
            t.timing.month = parts[1]
            t.timing.day = parts[2]
        }
        if t.timing.repeatKind != .once {
            t.timing.year = nil
            t.timing.month = nil
            t.timing.day = nil
        }
        if t.name.isEmpty { return .failure(APIError(message: "name is required.")) }
        if t.prompt.isEmpty { return .failure(APIError(message: "prompt is required.")) }
        if t.timing.repeatKind == .weekly && t.timing.weekdays.isEmpty {
            return .failure(APIError(message: "weekly needs days."))
        }
        if t.timing.repeatKind == .once && t.timing.onceDate == nil {
            return .failure(APIError(message: "once needs a date."))
        }
        if t.timing.repeatKind == .once && !t.timing.canResume {
            return .failure(APIError(message: "once needs a date and time in the future."))
        }
        return .success(t)
    }

    // MARK: - Descriptions

    private func describe(_ t: ScheduleTask) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id.uuidString, "name": t.name, "agent": t.kind.rawValue, "prompt": t.prompt,
            "project": project(t.projectID).map { ["name": $0.name, "path": $0.path] } ?? NSNull(),
            "schedule": t.timing.summary, "repeat": t.timing.repeatKind.rawValue,
            "time": String(format: "%02d:%02d", t.timing.hour, t.timing.minute),
            "enabled": t.enabled, "deleted": t.isDeleted,
            "nextRun": t.enabled ? (t.nextPlan.map(iso) ?? NSNull()) : NSNull(),
            "lastRunState": schedules.shownRun(of: t.id)?.state.rawValue ?? NSNull(),
        ]
        if t.timing.repeatKind == .weekly {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            d["days"] = t.timing.weekdays.sorted().map { names[$0 - 1] }.joined(separator: ",")
        }
        if t.timing.repeatKind == .once, let y = t.timing.year, let m = t.timing.month, let day = t.timing.day {
            d["date"] = String(format: "%04d-%02d-%02d", y, m, day)
        }
        return d
    }

    private func describe(_ r: ScheduleRun) -> [String: Any] {
        ["trigger": r.trigger.rawValue, "state": r.state.rawValue, "startedAt": iso(r.startedAt),
         "reason": r.reason ?? NSNull()]
    }


    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func error(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
}
