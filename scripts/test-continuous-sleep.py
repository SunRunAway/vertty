#!/usr/bin/env python3
"""Real sleep controller/menu and helper, with a fake clock and isolated power backend.
No windows, administrator authorization, or host power changes.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(tempfile.mkdtemp(prefix='vertty-continuous-sleep-', dir='/private/tmp'))
print(f'Artifacts: {root}', flush=True)
shutil.copy('Resources/vertty-sleep.sudoers', root / 'vertty-sleep.sudoers')
shutil.copy('build/Vertty.app/Contents/MacOS/vertty-sleep', root / 'vertty-sleep')
(root / 'stubs.swift').write_text('''import AppKit
final class AppStore { var workingAgentCount = 0 }
enum AppPaths {
    static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VERTTY_SUPPORT_DIR"]!)
}
''')
(root / 'main.swift').write_text('''import AppKit
let dir = AppPaths.support
func write(_ name: String, _ value: String = "") {
    try! value.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func read(_ name: String) -> String? {
    try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
}
func wait(_ reason: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(condition(), reason)
}
func settle(_ seconds: TimeInterval = 1.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
var clock = Date()
let store = AppStore()
let controller = SleepProtection(store: store, now: { clock })
let tasks = NSMenuItem(title: "", action: nil, keyEquivalent: "")
controller.menuItem = tasks
let parent = controller.makeContinuousMenuItem()
let menuTitle = String(localized: "Continuous Closed-Lid Sleep Protection")
let choices = parent.submenu!.items.filter { $0.action != nil }
let durations = [900, 1800, 3600, 7200, 10800, 21600, 43200, 86400]
precondition(choices.map(\\.tag) == [-1] + durations + [0])
func choose(_ seconds: Int) {
    let item = choices.first { $0.tag == seconds }!
    precondition(item.isEnabled)
    _ = item.target!.perform(item.action!, with: item)
}
func selected(_ seconds: Int) -> Bool {
    choices.filter { $0.state == .on }.map(\\.tag) == [seconds]
}
write("sleep-asked")
write("value", "0")
controller.start()
precondition(!controller.on && selected(-1) && parent.state == .off)
// Exercise the authorization completion without opening its prompt.
for outcome in ["cancel", "fail"] {
    write("authorization-result", outcome)
    controller.authorize(continuousDuration: 900)
    settle()
    precondition(!controller.authorized && !controller.on && selected(-1) && read("value") == "0")
}
write("authorization-result", "success")
controller.authorize(continuousDuration: 900)
wait("manual authorization did not start protection while idle") { read("value") == "1" }
precondition(controller.authorized && !controller.on && tasks.state == .off && selected(900))
precondition(read("sleep-off") != nil, "manual authorization changed next-launch task preference")
print("PASS independent manual authorization, cancellation and failure")

for duration in durations {
    choose(duration)
    precondition(selected(duration) && parent.state == .on)
    precondition(controller.continuousUntil == clock.addingTimeInterval(Double(duration)))
    precondition(parent.title == menuTitle + String(format: " %02d:%02d", duration / 3600, duration % 3600 / 60))
    precondition(!parent.submenu!.items[0].isHidden && !parent.submenu!.items[0].title.isEmpty)
}
clock = clock.addingTimeInterval(10)
choose(86400)
precondition(controller.continuousUntil == clock.addingTimeInterval(86400), "reselect did not restart deadline")
clock = clock.addingTimeInterval(15 * 3600 + 30 * 60)
wait("countdown did not refresh") { parent.title == menuTitle + " 08:30" }
clock = clock.addingTimeInterval(7 * 3600 + 31 * 60)
wait("countdown below one hour did not refresh") { parent.title == menuTitle + " 00:59" }
clock = clock.addingTimeInterval(59 * 60 - 1)
wait("last partial minute rounded down") { parent.title == menuTitle + " 00:01" }
clock = clock.addingTimeInterval(1)
wait("deadline did not release idle protection") { selected(-1) && read("value") == "0" }
precondition(parent.state == .off && parent.submenu!.items[0].isHidden && parent.title == menuTitle)
print("PASS all durations, selection, renewed deadline and expiry while idle")

choose(0)
wait("indefinite did not acquire") { read("value") == "1" }
clock = clock.addingTimeInterval(366 * 86400)
settle()
precondition(selected(0) && controller.continuousUntil == nil && read("value") == "1")
precondition(parent.title == menuTitle + " ♾️")
precondition(parent.submenu!.items[0].isHidden)
// Turning task mode on/off while busy must preserve the manual lease.
store.workingAgentCount = 1
controller.toggle()
precondition(controller.on)
controller.toggle()
precondition(!controller.on && selected(0))
settle()
precondition(read("value") == "1")
choose(-1)
wait("manual off with task mode disabled did not restore") { read("value") == "0" }
print("PASS indefinite duration and task toggle independence")

controller.toggle()
wait("task mode did not acquire") { read("value") == "1" }
choose(900)
clock = clock.addingTimeInterval(900)
wait("manual timer did not expire during task") { selected(-1) }
precondition(read("value") == "1" && tasks.state == .on)
choose(1800)
choose(-1)
settle()
precondition(read("value") == "1", "manual off interrupted running task")
choose(0)
store.workingAgentCount = 0
settle()
precondition(read("value") == "1", "task completion interrupted manual protection")
choose(-1)
wait("both modes inactive did not restore") { read("value") == "0" }
print("PASS expiry/off preserves tasks; task completion preserves manual protection")

// Rapid Off -> On must wait for the previous helper's restore, then acquire again.
choose(0)
wait("rapid toggle setup") { read("value") == "1" }
choose(-1)
choose(900)
settle(2)
precondition(read("value") == "1" && selected(900), "old restore overwrote new lease")
choose(-1)
wait("rapid toggle cleanup") { read("value") == "0" }
print("PASS rapid Off -> On serializes helper restoration")

// The manual lease uses the existing Amphetamine watchdog and release policy.
choose(0)
wait("watchdog setup") { read("value") == "1" }
write("value", "0")
wait("manual lease did not reapply after external reset", timeout: 8) { read("value") == "1" }
write("amphetamine", "true,true")
choose(-1)
settle()
precondition(read("value") == "1", "manual release overrode active Amphetamine")
write("amphetamine", "true,false")
choose(0)
settle()
choose(-1)
wait("inactive Amphetamine closed-lid protection blocked restore") { read("value") == "0" }
print("PASS manual watchdog reapply and Amphetamine compatibility")

choose(0)
wait("stop setup") { read("value") == "1" }
controller.stop()
wait("stop did not restore") { read("value") == "0" }
precondition(selected(-1) && tasks.state == .off)
let relaunched = SleepProtection(store: store)
relaunched.start()
precondition(relaunched.continuousDuration == nil, "manual session survived restart")
relaunched.stop()
print("PASS app stop restores and restart does not restore manual session")
''')
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
subprocess.run(['swiftc', '-sdk', sdk, 'Sources/Vertty/Support/SleepProtection.swift',
                str(root / 'stubs.swift'), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
env = dict(os.environ, VERTTY_SUPPORT_DIR=str(root), VERTTY_DEBUG_SNAPSHOT=str(root),
           VERTTY_SLEEP_TEST_DIR=str(root))
subprocess.run([str(root / 'test')], env=env, check=True, timeout=120)
