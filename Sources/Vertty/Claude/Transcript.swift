import Foundation

/// What we can learn about a Claude Code session from its JSONL transcript
/// (~/.claude/projects/<encoded cwd>/<session id>.jsonl).
struct TranscriptInfo {
    var customTitle: String?
    var aiTitle: String?
    var summary: String?
    var firstPrompt: String?
    var prNumber: Int?
    var prURL: String?
    /// nil = no worktree-state record seen; .some(nil) = explicitly left the worktree.
    var worktree: (name: String, path: String)??
    var cwd: String?
    var gitBranch: String?
    var modified: Date = .distantPast

    var bestTitle: String? { customTitle ?? aiTitle ?? summary ?? firstPrompt }
}

enum Transcript {
    static let projectsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")

    /// Claude Code stores transcripts in a directory named after the cwd with
    /// every non-alphanumeric character replaced by "-".
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func locate(sessionID: String, projectPath: String) -> URL? {
        let fm = FileManager.default
        let direct = projectsDir.appendingPathComponent(encode(projectPath)).appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return nil }
        for dir in dirs {
            let candidate = projectsDir.appendingPathComponent(dir).appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Reading

    private static let cacheLock = NSLock()
    private static var cache: [String: TranscriptInfo] = [:]

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Parses the tail of a transcript (cached by modification date).
    static func read(_ url: URL, tailBytes: Int = 1 << 20) -> TranscriptInfo? {
        guard let mtime = modificationDate(url) else { return nil }
        cacheLock.lock()
        if let cached = cache[url.path], cached.modified == mtime {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()

        var info = TranscriptInfo()
        info.modified = mtime
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial line

        var needCwd = true
        for line in lines.reversed() {
            let s = String(decoding: line, as: UTF8.self)
            if info.customTitle == nil, s.contains("\"type\":\"custom-title\"") {
                info.customTitle = (json(s)?["customTitle"] as? String)?.nonEmpty
            } else if info.aiTitle == nil, s.contains("\"type\":\"ai-title\"") {
                info.aiTitle = (json(s)?["aiTitle"] as? String)?.nonEmpty
            } else if info.summary == nil, s.contains("\"type\":\"summary\"") {
                info.summary = (json(s)?["summary"] as? String)?.nonEmpty
            } else if info.prNumber == nil, s.contains("\"type\":\"pr-link\"") {
                let obj = json(s)
                info.prNumber = obj?["prNumber"] as? Int
                info.prURL = obj?["prUrl"] as? String
            } else if info.worktree == nil, s.contains("\"type\":\"worktree-state\"") {
                if let ws = json(s)?["worktreeSession"] as? [String: Any],
                   let path = ws["worktreePath"] as? String {
                    let name = (ws["worktreeName"] as? String) ?? (path as NSString).lastPathComponent
                    info.worktree = .some((name: name, path: path))
                } else {
                    info.worktree = .some(nil)
                }
            } else if needCwd, s.contains("\"cwd\":"), s.contains("\"type\":\"user\"") || s.contains("\"type\":\"assistant\"") {
                if let obj = json(s), let cwd = obj["cwd"] as? String {
                    info.cwd = cwd
                    info.gitBranch = obj["gitBranch"] as? String
                    needCwd = false
                }
            }
        }

        if info.customTitle == nil && info.aiTitle == nil && info.summary == nil {
            info.firstPrompt = firstPrompt(url)
        }

        cacheLock.lock()
        cache[url.path] = info
        cacheLock.unlock()
        return info
    }

    /// The first real user message, used as a title of last resort.
    static func firstPrompt(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let s = String(decoding: line, as: UTF8.self)
            guard s.contains("\"type\":\"user\""), let obj = json(s),
                  let message = obj["message"] as? [String: Any] else { continue }
            if obj["isMeta"] as? Bool == true { continue }
            var text: String?
            if let str = message["content"] as? String {
                text = str
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  !t.hasPrefix("<"), !t.hasPrefix("Caveat:") else { continue }
            return String(t.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        }
        return nil
    }

    /// Transcript directories for a project: its own, plus those of every worktree
    /// of its repository (`git worktree list`, like Ctrl+W in Claude Code's /resume).
    /// A session's transcript moves to a worktree's directory once it enters it.
    /// Claude Code's own worktrees (<project>/.claude/worktrees/<name>) count even
    /// after they're removed: their sessions still resume from the project.
    static func transcriptDirs(projectPath: String) -> [URL] {
        let own = encode(projectPath)
        var names = [own]
        for path in GitProbe.worktrees(projectPath) where !names.contains(encode(path)) {
            names.append(encode(path))
        }
        let claudeWorktrees = own + "--claude-worktrees-"
        let all = (try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path)) ?? []
        for name in all.sorted() where name.hasPrefix(claudeWorktrees) && !names.contains(name) {
            names.append(name)
        }
        return names.map { projectsDir.appendingPathComponent($0) }
    }

    /// Recent sessions for a project directory, newest first.
    static func history(projectPath: String, limit: Int = 40) -> [SessionSummary] {
        let fm = FileManager.default
        let files = transcriptDirs(projectPath: projectPath).flatMap { dir in
            (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
        }

        let dated: [(URL, Date)] = files.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }.sorted { $0.1 > $1.1 }

        var result: [SessionSummary] = []
        for (url, date) in dated {
            if result.count >= limit { break }
            guard let info = read(url, tailBytes: 256 * 1024), let title = info.bestTitle else { continue }
            result.append(SessionSummary(
                id: url.deletingPathExtension().lastPathComponent,
                title: title, modified: date, path: url))
        }
        return result
    }

    // MARK: - Prompt search

    /// Claude Code's prompt history (what Ctrl+R searches): every prompt typed,
    /// with its session id and any pasted text.
    static let promptHistory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/history.jsonl")

    /// For each of these sessions with a typed prompt containing `query`, the first such prompt.
    static func promptMatches(_ query: String, sessionIDs: Set<String>) -> [String: PromptSnippet] {
        guard !sessionIDs.isEmpty, let data = try? Data(contentsOf: promptHistory) else { return [:] }
        var result: [String: PromptSnippet] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = obj["sessionId"] as? String, sessionIDs.contains(id), result[id] == nil else { continue }
            var texts = [obj["display"] as? String]
            if let pasted = obj["pastedContents"] as? [String: Any] {
                texts += pasted.sorted { $0.key < $1.key }.map { ($0.value as? [String: Any])?["content"] as? String }
            }
            result[id] = texts.lazy.compactMap { $0.flatMap { PromptSnippet($0, query: query) } }.first
        }
        return result
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
