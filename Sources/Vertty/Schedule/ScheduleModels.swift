import Foundation

/// How often a scheduled task runs.
enum ScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekdays, weekly
    var id: String { rawValue }
}

/// When a task runs: wall-clock time in the selected time zone (not every 24 hours).
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

    /// nil follows the Mac; a region identifier follows that region's DST rules.
    var timeZoneID: String?

    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// The first planned time strictly after `date`. A time skipped by a DST jump
    /// runs at the first valid moment after it; a repeated time runs once.
    func next(after date: Date) -> Date? {
        guard let at = nextCandidate(after: date) else { return nil }
        // The second pass of a time repeated when clocks go back: that time already ran.
        let cal = calendar
        let wall: (Date) -> DateComponents = { cal.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        if [1800.0, 3600.0].contains(where: { wall(at.addingTimeInterval(-$0)) == wall(at) }) {
            return next(after: at)
        }
        return at
    }

    private func nextCandidate(after date: Date) -> Date? {
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
        guard let timeZoneID else { return wallTimeSummary }
        return "\(wallTimeSummary) · \(timeZoneID)"
    }

    private var wallTimeSummary: String {
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
            let date = onceDate.map { ScheduleFormat.day($0, timeZone: timeZone) } ?? "?"
            return String(localized: "Once \(date) \(time)")
        }
    }

    static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }
}

enum ScheduleFormat {
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    static var weekdayNames: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.shortWeekdaySymbols
    }

    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        return f.string(from: date)
    }

    static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
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
    /// Ended by hand: no more plans until its schedule changes.
    var endedAt: Date?

    var isDeleted: Bool { deletedAt != nil }
    /// Project and agent are fixed once the task has its session.
    var isBound: Bool { !(sessionID ?? "").isEmpty }
}

/// Scheduling lifecycle, independent of the outcome of any individual run.
enum ScheduleState: String {
    case active, paused, ended, deleted
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
    /// When the agent was started (after checking and stopping the session).
    var launchedAt: Date?
    var endedAt: Date?
    var state: RunState
    var phase: RunPhase?
    var reason: String?
    var kind: AgentKind
    var sessionID: String?
    var cwd: String?
}

struct ScheduleFile: Codable {
    var tasks: [ScheduleTask] = []
    var runs: [ScheduleRun] = []
}

/// Stable links also work after deletion, when the task is kept as history.
extension ScheduleTask {
    var link: URL { URL(string: "vertty://schedule/\(id.uuidString)")! }

    static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "vertty", url.host == "schedule",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
