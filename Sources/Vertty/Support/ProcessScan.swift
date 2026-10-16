import Darwin
import Foundation

/// Reads other processes of this user: their arguments and environment.
enum ProcessScan {
    struct Process {
        let pid: pid_t
        let args: [String]
        let env: [String: String]
    }

    /// The pids of this user's processes.
    static func userPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4  // processes may start in between
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    /// This user's processes whose environment has `key` = `value`.
    static func processes(withEnv key: String, _ value: String) -> [Process] {
        userPIDs().compactMap { pid in
            guard let (args, env) = argumentsAndEnvironment(pid), env[key] == value else { return nil }
            return Process(pid: pid, args: args, env: env)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// A process's arguments and environment, from KERN_PROCARGS2: argc, the
    /// executable path, argv, then the environment, all NUL-separated.
    static func argumentsAndEnvironment(_ pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        // The executable path, padded with NULs, then argc arguments (empty ones
        // too, each one NUL), then the environment.
        var rest = buf[MemoryLayout<Int32>.size..<size]
        guard let pathEnd = rest.firstIndex(of: 0) else { return nil }
        rest = rest[pathEnd...].drop { $0 == 0 }
        let strings = rest.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard strings.count >= Int(argc) else { return nil }
        let args = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for s in strings.dropFirst(Int(argc)) {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return (args, env)
    }
}
