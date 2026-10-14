import Foundation
import Darwin
import AppKit
import Carbon

// Unprivileged lease: only the two fixed pmset commands run through sudo.
// Vhostty starts it when tasks begin and closes stdin when they end; an app
// crash or force-quit closes the pipe too, so sleep is restored either way.
let args = CommandLine.arguments
let test = args.firstIndex(of: "--test-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
// Writes to a closed stdout must not kill us before sleep is restored.
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    // Treat a signal like the lease ending: closing stdin ends the wait below.
    s.setEventHandler { close(STDIN_FILENO) }; s.resume(); return s
}
func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
/// nil means denied, timed out, or unreadable. Never asks for automation consent;
/// Vhostty requests it at launch.
func amphetamineProtectsSleep() -> Bool? {
    if let test {
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
    guard AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, typeWildCard, false) == noErr else { return nil }
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
func release() -> Bool {
    guard disabled() != false else { return true }
    if amphetamineProtectsSleep() == true { return true }
    return setDisabled(false)
}
func say(_ line: String) { _ = (line + "\n").withCString { write(STDOUT_FILENO, $0, strlen($0)) } }
// Enabling protection never depends on Amphetamine or its automation permission.
guard disabled() == true || setDisabled(true) else { exit(1) }
say("active")
// Others can set the value back to 0 during the lease (Amphetamine does when it
// launches, quits or ends a session), so check every 5 s and re-apply.
var byte: UInt8 = 0
while true {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    if poll(&descriptor, 1, 5_000) == 0 {
        if disabled() == false { say(setDisabled(true) ? "active" : "error") }
        continue
    }
    if read(STDIN_FILENO, &byte, 1) <= 0 { break }
}
let restored = release()
withExtendedLifetime(signals) {}
exit(restored ? 0 : 1)
