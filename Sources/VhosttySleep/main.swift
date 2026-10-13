import Foundation
import Darwin
import AppKit
import Carbon

// Unprivileged watchdog: only the two fixed pmset commands run through sudo.
// A pipe lease makes app crashes/force-quit release protection without UI cleanup.
let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
let test = args.count == 4 && args[2] == "--test-dir" ? URL(fileURLWithPath: args[3]) : nil
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
/// nil means denied, timed out, or unreadable.
func amphetamineProtectsSleep(requestPermission: Bool = false) -> Bool? {
    if let test, !FileManager.default.fileExists(atPath: test.appendingPathComponent("live-amphetamine").path) {
        guard FileManager.default.fileExists(atPath: test.appendingPathComponent("amphetamine").path) else { return false }
        let state = (try? String(contentsOf: test.appendingPathComponent("amphetamine"), encoding: .utf8)) ?? ""
        switch state {
        case "true,true": return true
        case "true,false", "false,true", "false,false": return false
        default: return nil
        }
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.if.Amphetamine").first else { return false }
    // Address the running PID so a race with quitting cannot launch Amphetamine.
    let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
    let eventClass: AEEventClass = 0x616d7068 // amph, from Amphetamine.sdef
    guard AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, typeWildCard, requestPermission) == noErr else { return nil }
    func query(_ eventID: AEEventID) -> Bool? {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                                          targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3),
              (reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0) == 0,
              let value = reply.paramDescriptor(forKeyword: keyDirectObject)?.coerce(toDescriptorType: typeBoolean) else { return nil }
        return value.booleanValue
    }
    guard let active = query(0x63416374), // cAct: session is active
          let closed = query(0x43444d4b) else { return nil } // CDMK: closed display mode enabled
    return active && closed
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
func release() {
    guard disabled() != false else { report("idle"); return }
    if amphetamineProtectsSleep() == true { report("external"); return }
    report(setDisabled(false) ? "idle" : "error")
}
// This is the only place that may request macOS automation consent.
// Later checks (including after the parent exits) must never prompt.
let initialAmphetamineState = amphetamineProtectsSleep(requestPermission: true)
if let test, FileManager.default.fileExists(atPath: test.appendingPathComponent("live-amphetamine").path) {
    try? (initialAmphetamineState.map(String.init) ?? "error").write(to: test.appendingPathComponent("amphetamine-result"), atomically: true, encoding: .utf8)
}
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
    if !busy { release(); continue }
    // Enabling protection never depends on Amphetamine or its automation permission.
    if disabled() == true || setDisabled(true) { report("active") } else { report("error") }
}
release()
withExtendedLifetime(signals) {}
