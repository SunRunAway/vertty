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
    var keepsAwake = false
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
precondition(!SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
try! SleepProtection.authorizationRule.write(to: ownRule, atomically: true, encoding: .utf8)
precondition(SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
try! FileManager.default.removeItem(at: dir.appendingPathComponent("amphetamine_PowerProtect"))
precondition(SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
precondition(!SleepProtection.hasInstalledRule(at: ownRule, owner: getuid() + 1))
try! FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: ownRule.path)
precondition(!SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ownRule.path)
try! "".write(to: ownRule, atomically: true, encoding: .utf8)
precondition(!SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
try! FileManager.default.removeItem(at: ownRule)
write("other-rule", SleepProtection.authorizationRule)
try! FileManager.default.createSymbolicLink(at: ownRule, withDestinationURL: dir.appendingPathComponent("other-rule"))
precondition(!SleepProtection.hasInstalledRule(at: ownRule, owner: getuid()))
print("PASS own rule required; independent of Amphetamine; wrong owner, writable, empty and symlink rules rejected")
let store = AppStore()
let controller = SleepProtection(store: store)
let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
controller.menuItem = item
let on = String(localized: "Closed-Lid Sleep Protection While Tasks Run")
let off = String(localized: "Closed-Lid Sleep Protection While Tasks Run: Not Authorized…")
func settle(_ seconds: TimeInterval = 1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func value() -> String? { try? String(contentsOf: dir.appendingPathComponent("value"), encoding: .utf8) }
precondition(item.title == off && item.state == .off)
write("value", "0")
for outcome in ["fail", "cancel"] {
    write("authorization-result", outcome)
    controller.authorize()
    settle()
    precondition(item.title == off && item.state == .off && !controller.authorized, outcome)
    precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sleep-declined").path))
}
print("PASS failed or cancelled authorization stays unauthorized, writes no refusal")
write("authorization-result", "success")
controller.authorize()
wait("authorization did not check the item") { item.title == on && item.state == .on && controller.authorized }
print("PASS authorized item is checked")
store.keepsAwake = true
wait("busy period did not apply protection") { value() == "1" }
store.keepsAwake = false
wait("idle grace did not restore sleep", timeout: 25) { value() == "0" }
print("PASS busy period applies and restores")
write("fail")
store.keepsAwake = true
settle(2)
precondition(item.title == on && controller.authorized, "runtime error with the rule in place changed the item")
print("PASS runtime error with authorization intact keeps the item checked")
try! FileManager.default.removeItem(at: dir.appendingPathComponent("fail"))
store.keepsAwake = false
settle(17)
try! FileManager.default.removeItem(at: dir.appendingPathComponent("authorized"))
write("fail")
store.keepsAwake = true
wait("lost authorization not shown") { item.title == off && item.state == .off && !controller.authorized }
print("PASS runtime error after authorization is gone shows unauthorized")
controller.stop()
''')
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
subprocess.run(['swiftc', '-sdk', sdk, 'Sources/Vhostty/Support/SleepProtection.swift',
                str(root / 'stubs.swift'), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(root), VHOSTTY_DEBUG_SNAPSHOT=str(root), VHOSTTY_SLEEP_TEST_DIR=str(root))
subprocess.run([str(root / 'test')], env=env, check=True, timeout=120)
