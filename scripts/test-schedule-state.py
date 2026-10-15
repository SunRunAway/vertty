#!/usr/bin/env python3
"""Exercise the production schedule model/store in a scratch directory."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='vhostty-schedule-state-') as directory:
    root = Path(directory)
    source = '''import Foundation
import Combine
enum AgentKind: String, Codable { case codex }
enum AppPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
'''
    for name in ['ScheduleModels.swift', 'ScheduleStore.swift']:
        source += (repo / 'Sources/Vhostty/Schedule' / name).read_text()
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
'''
    path = root / 'main.swift'
    path.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-sdk', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True)
