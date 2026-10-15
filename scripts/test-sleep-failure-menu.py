#!/usr/bin/env python3
"""Exercise the actual controller and NSMenuItem without opening windows/alerts."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(tempfile.mkdtemp(prefix='vhostty-sleep-menu-', dir='/private/tmp'))
print(f'Artifacts: {root}', flush=True)
shutil.copy('Resources/vhostty-sleep.sudoers', root / 'vhostty-sleep.sudoers')
shutil.copy('build/Vhostty.app/Contents/MacOS/vhostty-sleep', root / 'vhostty-sleep')
(root / 'stubs.swift').write_text('''import AppKit
final class AppStore {
    var workingAgentCount = 0
}
enum AppPaths {
    static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VHOSTTY_SUPPORT_DIR"]!)
}
''')
(root / 'main.swift').write_text('''import AppKit
let dir = AppPaths.support
func write(_ name: String, _ value: String = "") {
    try! value.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func wait(_ reason: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(condition(), reason)
}
// Validate the production file checker without touching /etc or opening an alert.
precondition(SleepProtection.authorizationRule.contains("%admin ALL=(root) NOPASSWD:"))
let ownRule = dir.appendingPathComponent("vhostty_sleep")
write("amphetamine_PowerProtect", SleepProtection.authorizationRule)
precondition(!SleepProtection.hasInstalledRule(at: ownRule))
try! SleepProtection.authorizationRule.write(to: ownRule, atomically: true, encoding: .utf8)
precondition(SleepProtection.hasInstalledRule(at: ownRule))
try! "".write(to: ownRule, atomically: true, encoding: .utf8)
precondition(!SleepProtection.hasInstalledRule(at: ownRule))
try! FileManager.default.removeItem(at: ownRule)
print("PASS own rule required; independent of Amphetamine; other content rejected")
let store = AppStore()
let controller = SleepProtection(store: store)
let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
controller.menuItem = item
let named = String(localized: "Closed-Lid Sleep Protection While Tasks Run")
let unauthorized = String(localized: "Closed-Lid Sleep Protection While Tasks Run: Not Authorized…")
let asked = dir.appendingPathComponent("sleep-asked")
let off = dir.appendingPathComponent("sleep-off")
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func settle(_ seconds: TimeInterval = 1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func value() -> String? { try? String(contentsOf: dir.appendingPathComponent("value"), encoding: .utf8) }
/// A fresh launch; it would block on a modal alert if it asked.
func relaunch() -> (SleepProtection, NSMenuItem) {
    let c = SleepProtection(store: store), i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    c.menuItem = i; c.start(); return (c, i)
}
precondition(item.title == unauthorized && item.state == .off)
write("value", "0")
for outcome in ["fail", "cancel"] {
    write("authorization-result", outcome)
    controller.authorize()
    settle()
    precondition(item.title == unauthorized && item.state == .off && !controller.authorized, outcome)
    precondition(!exists(asked), "a failed or cancelled authorization counted as a decision")
}
print("PASS failed or cancelled authorization stays unauthorized and records nothing")
write("authorization-result", "success")
controller.authorize()
wait("authorization did not turn it on") { item.title == named && item.state == .on && controller.on }
precondition(exists(asked))
print("PASS authorization turns it on, checks the item and counts as decided")
store.workingAgentCount = 1
wait("busy period did not apply protection") { value() == "1" }
store.workingAgentCount = 0
wait("idle did not restore sleep") { value() == "0" }
print("PASS busy period applies and restores")
controller.toggle()
precondition(item.title == named && item.state == .off && !controller.on && exists(off))
store.workingAgentCount = 1
settle(2)
precondition(value() == "0", "turned off but still protecting")
var (later, laterItem) = relaunch()
precondition(laterItem.title == named && laterItem.state == .off && !later.on)
print("PASS turning off stops protection and stays off after relaunch without asking")
controller.toggle()
precondition(item.state == .on && controller.on && !exists(off))
wait("turning on during a task did not apply protection") { value() == "1" }
store.workingAgentCount = 0
wait("idle did not restore sleep") { value() == "0" }
print("PASS turning on with authorization applies protection without asking")
// Rule deleted after authorizing once: launch doesn't ask, even after a cancelled retry.
try! FileManager.default.removeItem(at: dir.appendingPathComponent("authorized"))
(later, laterItem) = relaunch()
precondition(laterItem.title == unauthorized && !later.on)
write("authorization-result", "cancel")
later.authorize()
settle()
(later, laterItem) = relaunch()
precondition(laterItem.title == unauthorized && !later.on)
print("PASS once decided, launch never asks again")
write("authorization-result", "success")
controller.authorize()
wait("re-authorization did not turn it on") { controller.on }
write("fail")
store.workingAgentCount = 1
settle(2)
precondition(item.state == .on && controller.authorized, "runtime error with the rule in place changed the item")
print("PASS runtime error with authorization intact keeps it on")
try! FileManager.default.removeItem(at: dir.appendingPathComponent("fail"))
store.workingAgentCount = 0
settle()
try! FileManager.default.removeItem(at: dir.appendingPathComponent("authorized"))
write("fail")
store.workingAgentCount = 1
wait("lost authorization not shown") { item.title == unauthorized && item.state == .off && !controller.authorized }
print("PASS runtime error after authorization is gone shows unauthorized")
controller.stop()
''')
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
subprocess.run(['swiftc', '-sdk', sdk, 'Sources/Vhostty/Support/SleepProtection.swift',
                str(root / 'stubs.swift'), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(root), VHOSTTY_DEBUG_SNAPSHOT=str(root), VHOSTTY_SLEEP_TEST_DIR=str(root))
subprocess.run([str(root / 'test')], env=env, check=True, timeout=120)
