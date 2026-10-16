import Darwin
import Foundation

/// The Claude Code sessions running in each tab, found without hooks: Claude
/// Code keeps ~/.claude/sessions/<pid>.json for every running process, and a
/// `claude` typed into the tab's shell (after the first one exits) inherits the
/// tab's VERTTY_TAB_ID.
enum LiveSessions {
    struct Entry {
        let pid: pid_t
        let sessionID: String
        let cwd: String?
        let startedAt: Double
    }

    static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")

    private static let lock = NSLock()
    /// Tab id from each process's environment, keyed by pid and start time (pids get reused).
    private static var tabOfProcess: [String: UUID?] = [:]

    /// The interactive session running in each tab. With several (a `claude`
    /// started by Claude itself), the one started first is the tab's own.
    static func scan() -> [UUID: Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [:] }
        var result: [UUID: Entry] = [:]
        var live: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sessionID = (obj["sessionId"] as? String)?.nonEmpty,
                  (obj["kind"] as? String ?? "interactive") == "interactive",
                  let started = processStart(pid) else { continue }
            let key = "\(pid)@\(started)"
            live.insert(key)
            guard let tab = tab(of: pid, key: key) else { continue }
            let entry = Entry(pid: pid, sessionID: sessionID, cwd: obj["cwd"] as? String,
                              startedAt: (obj["startedAt"] as? NSNumber)?.doubleValue ?? started)
            if let other = result[tab], other.startedAt <= entry.startedAt { continue }
            result[tab] = entry
        }
        lock.lock()
        tabOfProcess = tabOfProcess.filter { live.contains($0.key) }
        lock.unlock()
        return result
    }

    private static func tab(of pid: pid_t, key: String) -> UUID? {
        lock.lock()
        if let cached = tabOfProcess[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // An unreadable environment (not ours yet, or gone) is retried next time.
        guard let env = ProcessScan.argumentsAndEnvironment(pid)?.1 else { return nil }
        let tab = env["VERTTY_TAB_ID"].flatMap(UUID.init(uuidString:))
        lock.lock()
        tabOfProcess[key] = tab
        lock.unlock()
        return tab
    }

    /// Start time of a live process (seconds since 1970), nil if it's gone.
    private static func processStart(_ pid: pid_t) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// Live interactive processes of a session, wherever they run: the pid and
    /// the Vertty tab it belongs to (nil outside Vertty or in another instance).
    static func processes(sessionID: String) -> [(pid: pid_t, tab: UUID?)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["sessionId"] as? String == sessionID,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let started = processStart(pid) else { return nil }
            return (pid, tab(of: pid, key: "\(pid)@\(started)"))
        }
    }

    /// Whether the session runs as a background job (sent away with ←), which
    /// `claude attach` reopens. Same check as the vertty-claude launcher.
    static func backgroundJobRunning(sessionID: String) -> Bool {
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/jobs/\(sessionID.prefix(8))/state.json")
        guard let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["sessionId"] as? String == sessionID else { return false }
        let state = obj["state"] as? String ?? ""
        return state != "done" && state != "stopped"
    }
}
