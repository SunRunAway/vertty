import Foundation

/// How often a scheduled task runs.
enum ScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekdays, weekly
    var id: String { rawValue }
}

/// When a task runs: wall-clock time in a fixed time zone (not every 24 hours).
struct ScheduleTiming: Codable, Equatable {
    var repeatKind: ScheduleRepeat = .weekly
    var hour = 9
    var minute = 0
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) for .weekly.
    var weekdays: [Int] = [7]
    /// The day of a .once task.
    var year: Int?
    var month: Int?
    var day: Int?
    var timeZone = TimeZone.current.identifier

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// The first planned time strictly after `date`. A time skipped by a DST jump
    /// runs at the first valid moment after it; a repeated time runs once.
    func next(after date: Date) -> Date? {
        let cal = calendar
        switch repeatKind {
        case .once:
            guard let at = onceDate, at > date else { return nil }
            return at
        case .daily:
            return nextMatch(cal, after: date, weekday: nil)
        case .weekdays:
            return (2...6).compactMap { nextMatch(cal, after: date, weekday: $0) }.min()
        case .weekly:
            return Set(weekdays).compactMap { nextMatch(cal, after: date, weekday: $0) }.min()
        }
    }

    var onceDate: Date? {
        guard let year, let month, let day else { return nil }
        let cal = calendar
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        guard let start = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        // Resolve through nextDate so a DST gap behaves like the repeating kinds.
        return cal.nextDate(after: start.addingTimeInterval(-1), matching: comps,
                            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private func nextMatch(_ cal: Calendar, after date: Date, weekday: Int?) -> Date? {
        var comps = DateComponents(hour: hour, minute: minute, second: 0)
        comps.weekday = weekday
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime,
                            repeatedTimePolicy: .first, direction: .forward)
    }

    var isValid: Bool {
        switch repeatKind {
        case .weekly: return !weekdays.isEmpty
        case .once: return onceDate != nil
        default: return true
        }
    }

    /// "Every Sat 09:00", "Weekdays 09:00", "Once Oct 17 09:00"…
    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch repeatKind {
        case .daily: return String(localized: "Daily \(time)")
        case .weekdays: return String(localized: "Weekdays \(time)")
        case .weekly:
            let names = ScheduleFormat.weekdayNames
            let days = weekdays.sorted { Self.mondayFirst($0) < Self.mondayFirst($1) }
                .map { names[($0 - 1) % 7] }.joined(separator: String(localized: ", "))
            return String(localized: "Every \(days) \(time)")
        case .once:
            let date = onceDate.map { ScheduleFormat.day($0, zone: zone) } ?? "?"
            return String(localized: "Once \(date) \(time)")
        }
    }

    var summaryWithZone: String { "\(summary) · \(timeZone)" }

    static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }
}

enum ScheduleFormat {
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    static var weekdayNames: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.shortWeekdaySymbols
    }

    static func day(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        return f.string(from: date)
    }

    /// Date and time, in the task's zone when given.
    static func dateTime(_ date: Date, zone: TimeZone? = nil) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone ?? .current
        f.setLocalizedDateFormatFromTemplate("MMMdEEEHHmm")
        return f.string(from: date)
    }
}

/// A scheduled task. It owns one session: created by its first run and resumed
/// by every later one.
struct ScheduleTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var projectID: UUID
    var kind: AgentKind
    var prompt: String
    var timing: ScheduleTiming
    var enabled = true
    var createdAt = Date()
    var deletedAt: Date?
    /// The task's session, once its first run created it.
    var sessionID: String?
    /// The next planned time not handled yet (nil: no more plans).
    var nextPlan: Date?
    /// Set when Vhostty paused the task because its project was removed or moved.
    var reviewNote: String?

    var isDeleted: Bool { deletedAt != nil }
    /// Project and agent are fixed once the task has its session.
    var isBound: Bool { !(sessionID ?? "").isEmpty }
}

enum RunTrigger: String, Codable {
    case scheduled, catchUp, manual
}

/// The four states the list shows.
enum RunState: String, Codable {
    case running, replied, failed, skipped
}

/// Detail of a running run.
enum RunPhase: String, Codable {
    case starting, executing, needsInput
}

/// One trigger of a task: scheduled, caught up, or run by hand.
struct ScheduleRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var taskID: UUID
    var trigger: RunTrigger
    var plannedAt: Date?
    var startedAt = Date()
    var endedAt: Date?
    var state: RunState
    var phase: RunPhase?
    var reason: String?
    /// The run's state is unknown: it blocks the task until the user ends the record.
    var unresolved: Bool?
    var resolvedByUser: Bool?
    /// A skip record that stands for several missed plans (the earliest is skippedFrom).
    var skippedCount: Int?
    var skippedFrom: Date?
    var kind: AgentKind
    var sessionID: String?
    var cwd: String?
    /// What this run was given, kept as it was then.
    var prompt: String
    var timingSummary: String

    /// Still holds the task: running, or unresolved.
    var isOpen: Bool { state == .running || unresolved == true }
}

enum DraftAction: String, Codable {
    case create, edit, pause, resume, delete, run
}

enum DraftStatus: String, Codable {
    case pending, approved, rejected, withdrawn
}

/// A change an agent asked for through the schedule skill. It does nothing until
/// a person confirms it in Vhostty.
struct ScheduleDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var action: DraftAction
    /// The task to change (all but create).
    var taskID: UUID?
    /// The proposed task (create, edit).
    var task: ScheduleTask?
    /// The task as it was when the edit was proposed, to show what changes.
    var base: ScheduleTask?
    var status: DraftStatus = .pending
    var decidedAt: Date?
    /// The session that asked.
    var sourceTabID: UUID?
    var sourceKind: AgentKind?
    var sourceSessionID: String?
    var sourceTitle: String?
}

struct ScheduleFile: Codable {
    var tasks: [ScheduleTask] = []
    var runs: [ScheduleRun] = []
    var drafts: [ScheduleDraft]? = nil
}
