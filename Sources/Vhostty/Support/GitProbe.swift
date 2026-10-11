import Foundation

struct GitInfo: Equatable {
    var branch: String
    var toplevel: String
    /// Non-nil when cwd is inside a linked worktree (not the main checkout).
    var linkedWorktree: String?
}

struct PRInfo: Equatable {
    var number: Int
    var url: String
    var state: String // OPEN, MERGED, CLOSED
}

enum GitProbe {
    static func probe(_ cwd: String) -> GitInfo? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        guard let r = Proc.run("/usr/bin/git", [
            "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD", "--show-toplevel", "--absolute-git-dir", "--git-common-dir",
        ], timeout: 5), r.status == 0 else { return nil }
        let lines = r.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 4 else { return nil }

        var branch = lines[0]
        if branch == "HEAD",
           let sha = Proc.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--short", "HEAD"], timeout: 5)?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
            branch = "detached@\(sha)"
        }
        let toplevel = lines[1]
        let gitDir = realpath(lines[2])
        var common = lines[3]
        if !common.hasPrefix("/") { common = (cwd as NSString).appendingPathComponent(common) }
        common = realpath(common)

        let linked = gitDir != common ? (toplevel as NSString).lastPathComponent : nil
        return GitInfo(branch: branch, toplevel: toplevel, linkedWorktree: linked)
    }

    /// Paths of every worktree of the repository containing `path` (`git worktree list`).
    static func worktrees(_ path: String) -> [String] {
        guard FileManager.default.fileExists(atPath: path),
              let r = Proc.run("/usr/bin/git", ["-C", path, "worktree", "list", "--porcelain"], timeout: 5),
              r.status == 0 else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    /// The repository's `origin` remote URL, as configured.
    static func origin(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let r = Proc.run("/usr/bin/git", ["-C", path, "config", "--get", "remote.origin.url"], timeout: 5),
              r.status == 0 else { return nil }
        return r.stdout.nonEmpty
    }

    private static func realpath(_ path: String) -> String {
        (path as NSString).standardizingPath.withCString { cpath in
            guard let resolved = Darwin.realpath(cpath, nil) else { return (path as NSString).standardizingPath }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    // MARK: - Pull requests (via gh, cached)

    private static let prLock = NSLock()
    private static var prCache: [String: (PRInfo?, Date)] = [:]
    private static let prTTL: TimeInterval = 120

    static func isFeatureBranch(_ branch: String) -> Bool {
        !["main", "master", "HEAD"].contains(branch) && !branch.hasPrefix("detached@")
    }

    static func pullRequest(toplevel: String, branch: String) -> PRInfo? {
        guard isFeatureBranch(branch) else { return nil }
        return view(branch, cwd: toplevel, key: "\(toplevel)|\(branch)")
    }

    /// A PR Claude linked in the transcript (pr-link), looked up by URL or number so
    /// its state stays current after the session has left the PR's branch.
    static func pullRequest(ref: String, cwd: String) -> PRInfo? {
        view(ref, cwd: cwd, key: ref.contains("://") ? ref : "\(cwd)|#\(ref)")
    }

    private static func view(_ ref: String, cwd: String, key: String) -> PRInfo? {
        prLock.lock()
        if let (cached, at) = prCache[key], Date().timeIntervalSince(at) < prTTL {
            prLock.unlock()
            return cached
        }
        prLock.unlock()

        var info: PRInfo?
        if let gh = ShellEnvironment.which("gh"),
           let r = Proc.run(gh, ["pr", "view", ref, "--json", "number,url,state"], cwd: cwd, timeout: 15),
           r.status == 0,
           let obj = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any],
           let number = obj["number"] as? Int {
            info = PRInfo(number: number, url: obj["url"] as? String ?? "", state: obj["state"] as? String ?? "OPEN")
        }
        prLock.lock()
        prCache[key] = (info, Date())
        prLock.unlock()
        return info
    }

    static func invalidatePR(toplevel: String, branch: String) {
        prLock.lock()
        prCache.removeValue(forKey: "\(toplevel)|\(branch)")
        prLock.unlock()
    }
}
