import Foundation
import Darwin

// Unprivileged watchdog: only the two fixed pmset commands run through sudo.
// A pipe lease makes app crashes/force-quit release protection without UI cleanup.
let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
let test = args.count == 4 && args[2] == "--test-dir" ? URL(fileURLWithPath: args[3]) : nil
let marker = directory.appendingPathComponent("sleep-owned")
let status = directory.appendingPathComponent("sleep-status")
let lock = open(directory.appendingPathComponent("sleep.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(3) }
func report(_ value: String) { try? value.write(to: status, atomically: true, encoding: .utf8) }
func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
func externalApp() -> Bool {
    if let test { return FileManager.default.fileExists(atPath: test.appendingPathComponent("amphetamine").path) }
    return run("/usr/bin/pgrep", ["-x", "Amphetamine"]).0 == 0
}
func disabled() -> Bool? {
    let output: String
    if let test { output = (try? String(contentsOf: test.appendingPathComponent("value"))) ?? "" }
    else { let r = run("/usr/bin/pmset", ["-g"]); guard r.0 == 0 else { return nil }; output = r.1 }
    if test != nil { return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
    for line in output.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        if fields.first == "SleepDisabled", fields.count == 2 { return fields[1] == "1" }
    }
    return nil
}
func setDisabled(_ value: Bool) -> Bool {
    if let test {
        if FileManager.default.fileExists(atPath: test.appendingPathComponent("fail").path) { return false }
        do { try (value ? "1" : "0").write(to: test.appendingPathComponent("value"), atomically: true, encoding: .utf8); return true } catch { return false }
    }
    return run("/usr/bin/sudo", ["-n", "-k", "/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"]).0 == 0
}
var owned = FileManager.default.fileExists(atPath: marker.path)
func release() {
    guard owned else { return }
    // Never switch off another app's protection. Keep the recovery marker.
    guard !externalApp() else { report("external"); return }
    if setDisabled(false) {
        owned = false; try? FileManager.default.removeItem(at: marker); report("idle")
    } else { report("error") }
}
release() // Recover a previous watchdog that was itself killed.
var lastBusy: TimeInterval = -100
var pending = ""
var done = false
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    // Wake poll by closing stdin; normal app shutdown uses pipe EOF.
    s.setEventHandler { close(STDIN_FILENO) }; s.resume(); return s
}
while !done {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    let ready = poll(&descriptor, 1, 15_000)
    if ready <= 0 { break } // Parent hung or stopped renewing its lease.
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count <= 0 { break }
    pending += String(decoding: bytes.prefix(count), as: UTF8.self)
    while let end = pending.firstIndex(of: "\n") {
        let command = String(pending[..<end]); pending.removeSubrange(...end)
        if command == "1" { lastBusy = ProcessInfo.processInfo.systemUptime }
        else if command != "0" { done = true; break }
    }
    if done { break }
    let busy = ProcessInfo.processInfo.systemUptime - lastBusy < 15
    if externalApp() { report("external"); continue }
    if !busy { release(); if !owned { report("idle") }; continue }
    guard let current = disabled() else { report("error"); continue }
    if current && !owned { report("external"); continue }
    if !owned {
        // Journal before the global mutation, so a killed helper can recover it.
        do { try Data().write(to: marker, options: .atomic); owned = true }
        catch { report("error"); continue }
    }
    if current || setDisabled(true) { report("active") } else { report("error") }
}
release()
withExtendedLifetime(signals) {}
