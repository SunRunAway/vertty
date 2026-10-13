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
    var tabs: [Tab] = []
    var schedulePreparing: Set<Int> = []
}
struct Tab {
    var isLaunched = true
    var status: Status = .working
}
enum Status { case working, starting }
enum AppPaths {
    static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VHOSTTY_SUPPORT_DIR"]!)
}
''')
(root / 'main.swift').write_text('''import AppKit
let dir = AppPaths.support
func write(_ name: String, _ value: String = "") {
    try! value.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func wait(_ reason: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
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
let normal = String(localized: "Closed-Lid Sleep Protection…")
let failed = String(localized: "Closed-Lid Sleep Protection: Not Active…")
write("value", "0")
write("authorization-result", "fail")
controller.retry()
wait("authorization failure not reflected in menu") { item.title == failed }
precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sleep-declined").path))
print("PASS authorization failure updates real NSMenuItem without alert")
write("authorization-result", "cancel")
controller.configure() // Failed menu action retries directly; no onboarding alert.
for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
precondition(item.title == failed)
print("PASS cancelled retry retains failure and writes no refusal")
write("authorization-result", "success")
controller.configure()
wait("successful retry did not clear failure") { item.title == normal }
write("fail")
store.tabs = [Tab()]
wait("runtime failure did not update menu") { item.title == failed }
print("PASS runtime failure updates menu without alert")
try! FileManager.default.removeItem(at: dir.appendingPathComponent("fail"))
// Wait for the failed watchdog to finish cleanup before requesting another instance.
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
controller.configure()
wait("runtime retry did not recover") { item.title == normal }
wait("recovered protection not active") { (try? String(contentsOf: dir.appendingPathComponent("value"))) == "1" }
controller.stop()
wait("stop failed to restore sleep") { (try? String(contentsOf: dir.appendingPathComponent("value"))) == "0" }
print("PASS menu retry restores normal title and sleep protection")
''')
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
subprocess.run(['swiftc', '-sdk', sdk, 'Sources/Vhostty/Support/SleepProtection.swift',
                str(root / 'stubs.swift'), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(root), VHOSTTY_DEBUG_SNAPSHOT=str(root), VHOSTTY_SLEEP_TEST_DIR=str(root))
subprocess.run([str(root / 'test')], env=env, check=True, timeout=35)
