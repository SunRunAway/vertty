#!/usr/bin/env python3
"""Exercise the actual DisplayAwake controller without opening windows.
Holds a real display-sleep assertion for a few seconds; needs no authorization.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(tempfile.mkdtemp(prefix='vhostty-display-', dir='/private/tmp'))
print(f'Artifacts: {root}', flush=True)
(root / 'stubs.swift').write_text('''import Foundation
final class AppStore {
    var workingAgentCount = 0
}
enum AppPaths {
    static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VHOSTTY_SUPPORT_DIR"]!)
}
''')
(root / 'main.swift').write_text('''import Foundation
func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }
func assertionListed() -> Bool {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "assertions"]
    p.standardOutput = pipe; try! p.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.contains("pid \\(getpid())(") && text.contains("Vhostty tasks are running")
}
let store = AppStore()
let display = DisplayAwake(store: store)
display.start()
store.workingAgentCount = 1
settle()
precondition(!display.enabled && !display.holding, "off by default but holding")
print("PASS off by default")
display.setEnabled(true)
settle()
precondition(display.enabled && display.holding && assertionListed(), "working task without assertion")
print("PASS working task holds the display assertion")
store.workingAgentCount = 0
settle()
precondition(!display.holding && !assertionListed(), "idle still holding")
print("PASS idle releases it")
let relaunched = DisplayAwake(store: store)
precondition(relaunched.enabled, "setting not remembered")
store.workingAgentCount = 1
display.setEnabled(false)
settle()
precondition(!display.enabled && !display.holding && !assertionListed(), "turned off still holding")
print("PASS turning off releases it and is remembered")
''')
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
subprocess.run(['swiftc', '-sdk', sdk, 'Sources/Vhostty/Support/DisplayAwake.swift',
                str(root / 'stubs.swift'), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(root))
subprocess.run([str(root / 'test')], env=env, check=True, timeout=60)
