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
let declined = dir.appendingPathComponent("sleep-declined")
func settle(_ seconds: TimeInterval = 1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func value() -> String? { try? String(contentsOf: dir.appendingPathComponent("value"), encoding: .utf8) }
precondition(item.title == unauthorized && item.state == .off)
write("value", "0")
for outcome in ["fail", "cancel"] {
    write("authorization-result", outcome)
    controller.authorize()
    settle()
    precondition(item.title == unauthorized && item.state == .off && !controller.authorized, outcome)
    precondition(!FileManager.default.fileExists(atPath: declined.path))
}
print("PASS failed or cancelled authorization stays unauthorized, writes no refusal")
write("authorization-result", "success")
controller.authorize()
wait("authorization did not turn it on") { item.title == named && item.state == .on && controller.on }
print("PASS authorization turns it on and checks the item")
store.workingAgentCount = 1
wait("busy period did not apply protection") { value() == "1" }
store.workingAgentCount = 0
wait("idle did not restore sleep") { value() == "0" }
print("PASS busy period applies and restores")
// Turned off from the menu: no protection, remembered, no prompt at the next launch.
controller.toggle()
precondition(item.title == named && item.state == .off && !controller.on && FileManager.default.fileExists(atPath: declined.path))
store.workingAgentCount = 1
settle(2)
precondition(value() == "0", "turned off but still protecting")
let relaunched = SleepProtection(store: store)
let relaunchedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
relaunched.menuItem = relaunchedItem
relaunched.start() // Would block on a modal alert if it asked.
precondition(relaunchedItem.title == named && relaunchedItem.state == .off && !relaunched.on)
print("PASS turning off stops protection and stays off after relaunch without asking")
// Turned back on while authorized: no prompt.
controller.toggle()
precondition(item.state == .on && controller.on && !FileManager.default.fileExists(atPath: declined.path))
wait("turning on during a task did not apply protection") { value() == "1" }
store.workingAgentCount = 0
wait("idle did not restore sleep") { value() == "0" }
print("PASS turning on with authorization applies protection without asking")
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
