#!/usr/bin/env python3
"""Exercise the production schedule model/store in a scratch directory."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='vertty-schedule-state-') as directory:
    root = Path(directory)
    source = '''import Foundation
import Combine
enum AgentKind: String, Codable { case codex }
enum AppPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
'''
    for name in ['ScheduleModels.swift', 'ScheduleStore.swift']:
        source += (repo / 'Sources/Vertty/Schedule' / name).read_text()
    source += '''
let store = ScheduleStore()
var task = ScheduleTask(name: "Fixture", projectID: UUID(), kind: .codex, prompt: "hello",
    timing: ScheduleTiming(repeatKind: .once, hour: 9, minute: 0, year: 2020, month: 1, day: 1))
assert(store.create(task))
func state(_ expected: ScheduleState) {
    assert(store.state(of: store.task(task.id)!) == expected)
}
state(.active)
store.setEnabled(task.id, false)
state(.paused) // Past but never executed is not ended.
store.setEnabled(task.id, true)
state(.paused) // An expired plan cannot resume.
store.modify(task.id) { $0.enabled = true }
var run = ScheduleRun(taskID: task.id, trigger: .scheduled, plannedAt: task.timing.onceDate,
    state: .running, kind: .codex)
store.add(run)
state(.active) // Claiming the last plan is not finishing it.
for result in [RunState.replied, .failed, .skipped] {
    store.modifyRun(run.id) { $0.state = result }
    state(.ended)
}
store.setEnabled(task.id, false)
state(.ended)
store.setEnabled(task.id, true)
state(.ended)
let manual = ScheduleRun(taskID: task.id, trigger: .manual, state: .running, kind: .codex)
store.add(manual)
state(.ended)
assert(store.openRun(of: task.id) != nil) // The list can expose the manual run.
store.modifyRun(manual.id) { $0.state = .replied }
state(.ended)
var edit = store.task(task.id)!
edit.timing.year = 2099
assert(store.applyEdit(edit) == nil)
state(.active)
assert(store.task(task.id)!.nextPlan != nil)
store.setEnabled(task.id, false)
state(.paused)
edit = store.task(task.id)!
edit.timing.repeatKind = .daily
assert(store.applyEdit(edit) == nil)
state(.paused)
assert(store.task(task.id)!.nextPlan == nil)
store.setEnabled(task.id, true)
state(.active)
assert(store.task(task.id)!.nextPlan != nil)
assert(store.delete(task.id))
state(.deleted)
store.setEnabled(task.id, true)
state(.deleted)
// An old manual run cannot mark a different expired, unexecuted plan as ended.
var other = task
other.id = UUID()
assert(store.create(other))
store.add(ScheduleRun(taskID: other.id, trigger: .manual, state: .replied, kind: .codex))
assert(store.state(of: store.task(other.id)!) == .active)
// Reload preserves the derived lifecycle.
let restored = ScheduleStore()
restored.load()
assert(restored.state(of: restored.task(task.id)!) == .deleted)
print("PASS: schedule lifecycle, reruns, edits, pause/resume and deletion")
// Existing files without a zone still follow the system.
let legacy = Data(#"{"repeatKind":"daily","hour":9,"minute":30,"weekdays":[7]}"#.utf8)
let decodedLegacy = try JSONDecoder().decode(ScheduleTiming.self, from: legacy)
assert(decodedLegacy.timeZoneID == nil)
func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
var ny = ScheduleTiming(repeatKind: .daily, hour: 9, minute: 30, timeZoneID: "America/New_York")
for (after, expected) in [
    ("2026-03-07T00:00:00Z", "2026-03-07T14:30:00Z"),
    ("2026-03-08T00:00:00Z", "2026-03-08T13:30:00Z"),
    ("2026-10-31T00:00:00Z", "2026-10-31T13:30:00Z"),
    ("2026-11-01T00:00:00Z", "2026-11-01T14:30:00Z")
] { assert(ny.next(after: instant(after)) == instant(expected), expected) }
// Spring's nonexistent 02:30 moves to 03:00; fall's 01:30 runs only once.
ny.hour = 2
assert(ny.next(after: instant("2026-03-08T00:00:00Z")) == instant("2026-03-08T07:00:00Z"))
ny.hour = 1
assert(ny.next(after: instant("2026-11-01T00:00:00Z")) == instant("2026-11-01T05:30:00Z"))
assert(ny.next(after: instant("2026-11-01T05:30:00Z")) == instant("2026-11-02T06:30:00Z"))
ny.hour = 9
ny.repeatKind = .weekdays
assert(ny.next(after: instant("2026-03-06T15:00:00Z")) == instant("2026-03-09T13:30:00Z"))
ny.repeatKind = .weekly
ny.weekdays = [1]
assert(ny.next(after: instant("2026-10-31T00:00:00Z")) == instant("2026-11-01T14:30:00Z"))
ny.repeatKind = .once
ny.year = 2026; ny.month = 11; ny.day = 1
assert(ny.onceDate == instant("2026-11-01T14:30:00Z"))
// Switching zones retains wall-clock fields; formatting uses the task's date.
ny.timeZoneID = "Asia/Tokyo"
assert(ny.hour == 9 && ny.minute == 30 && ny.day == 1)
assert(ny.onceDate == instant("2026-11-01T00:30:00Z"))
assert(ny.summary.contains("Asia/Tokyo"))
ny.repeatKind = .daily
ny.timeZoneID = "America/New_York"
var fixed = ScheduleTask(name: "New York", projectID: UUID(), kind: .codex, prompt: "hello", timing: ny)
assert(store.create(fixed))
let due = instant("2026-01-01T14:30:00Z")
store.modify(fixed.id) { $0.nextPlan = due }
let oldSystemZone = NSTimeZone.default
NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
store.timeZoneChanged()
assert(store.task(fixed.id)!.nextPlan == due) // Do not drop a due fixed-zone plan.
assert(store.task(fixed.id)!.timing.timeZone.identifier == "America/New_York")
assert(ScheduleTiming().calendar.timeZone == .current)
NSTimeZone.default = oldSystemZone
let persisted = ScheduleStore()
persisted.load()
assert(persisted.task(fixed.id)!.timing.timeZoneID == "America/New_York")
var changedZone = persisted.task(fixed.id)!
changedZone.timing.timeZoneID = "America/Los_Angeles"
assert(persisted.applyEdit(changedZone) == nil)
assert(persisted.task(fixed.id)!.nextPlan! > Date())
assert(persisted.task(fixed.id)!.timing.hour == 9)
print("PASS: legacy decoding, region persistence, DST transitions, weekdays, weekly, once and system-zone changes")

// A never-run task survives removal, restart and re-addition with a new project ID.
let oldProject = UUID(), newProject = UUID()
let projectPath = AppPaths.support.appendingPathComponent("project").path
var unrun = ScheduleTask(name: "Never run", projectID: oldProject, projectPath: projectPath,
    kind: .codex, prompt: "hello", timing: ScheduleTiming(repeatKind: .daily))
assert(store.create(unrun))
let relinked = ScheduleStore()
relinked.load()
let beforeRelink = relinked.task(unrun.id)!
relinked.projectAdded(newProject, path: projectPath + "-other", known: [])
assert(relinked.task(unrun.id) == beforeRelink)
relinked.projectAdded(newProject, path: projectPath, known: [oldProject])
assert(relinked.task(unrun.id) == beforeRelink) // Never steal from an existing project.
relinked.projectAdded(newProject, path: projectPath, known: [])
var expected = beforeRelink
expected.projectID = newProject
assert(relinked.task(unrun.id) == expected) // Preserve every other field, including nextPlan.
let reloaded = ScheduleStore()
reloaded.load()
assert(reloaded.task(unrun.id) == expected)

// Legacy tasks decode without a path and get it from their existing project.
var legacyTask = unrun
legacyTask.id = UUID()
legacyTask.projectPath = nil
assert(reloaded.create(legacyTask))
let legacyReloaded = ScheduleStore()
legacyReloaded.load()
assert(legacyReloaded.task(legacyTask.id)!.projectPath == nil)
legacyReloaded.rememberProjectPath(oldProject, path: projectPath)
legacyReloaded.projectAdded(newProject, path: projectPath, known: [])
assert(legacyReloaded.task(legacyTask.id)!.projectID == newProject)

// A changed directory supersedes historical run paths, including for bound tasks.
let movedPath = projectPath + "-moved"
legacyReloaded.modify(unrun.id) { $0.sessionID = "existing-session" }
let history = ScheduleRun(taskID: unrun.id, trigger: .manual, state: .replied,
    kind: .codex, cwd: projectPath)
legacyReloaded.add(history)
legacyReloaded.rememberProjectPath(newProject, path: movedPath)
let beforeMove = legacyReloaded.task(unrun.id)!
let movedProject = UUID()
legacyReloaded.projectAdded(movedProject, path: projectPath, known: [])
assert(legacyReloaded.task(unrun.id) == beforeMove)
legacyReloaded.projectAdded(movedProject, path: movedPath, known: [])
assert(legacyReloaded.task(unrun.id)!.sessionID == "existing-session")
assert(legacyReloaded.task(unrun.id)!.projectID == movedProject)
assert(legacyReloaded.run(history.id) == history)

// Older orphaned tasks still recover through their run history.
legacyTask.id = UUID()
assert(legacyReloaded.create(legacyTask))
legacyReloaded.add(ScheduleRun(taskID: legacyTask.id, trigger: .manual, state: .replied,
    kind: .codex, cwd: projectPath))
legacyReloaded.projectAdded(newProject, path: projectPath, known: [])
assert(legacyReloaded.task(legacyTask.id)!.projectID == newProject)
assert(legacyReloaded.task(legacyTask.id)!.projectPath == projectPath)
var reassigned = legacyReloaded.task(legacyTask.id)!
reassigned.projectID = movedProject
reassigned.projectPath = movedPath
assert(legacyReloaded.applyEdit(reassigned) == nil)
assert(legacyReloaded.task(legacyTask.id)!.projectPath == movedPath)
print("PASS: project re-add before first run, persistence, legacy recovery, directory edits and session preservation")

'''
    path = root / 'main.swift'
    path.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-sdk', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True)
