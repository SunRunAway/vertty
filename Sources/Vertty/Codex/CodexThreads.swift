import Foundation
import SQLite3

/// Codex sessions ("threads"), read from the index Codex keeps in
/// ~/.codex/state_<n>.sqlite.
enum CodexThreads {
    struct Thread {
        let id: String
        let cwd: String
        let title: String?
        let firstPrompt: String?
        let branch: String?
        let modified: Date
        let rolloutPath: String
    }

    /// Where Codex keeps its data: CODEX_HOME as the tabs' shells see it.
    static var home: URL {
        if let dir = ShellEnvironment.codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]?.nonEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    /// The newest state database (the number goes up with Codex's schema).
    static func database() -> URL? { newest("state_") }

    /// The newest database named <prefix><n>.sqlite in CODEX_HOME.
    private static func newest(_ prefix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let best = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite"),
                  let n = Int(name.dropFirst(prefix.count).dropLast(7)) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        return best.map { home.appendingPathComponent($0.1) }
    }

    /// Sessions a person started (not subagents, reviews or automations).
    private static let interactive = """
        archived = 0 AND source IN ('cli', 'vscode') AND ifnull(nullif(thread_source, ''), 'user') = 'user'
        """
    private static let columns = """
        id, cwd, name, title, git_branch, updated_at, rollout_path
        """

    static func thread(id: String) -> Thread? {
        guard !id.isEmpty else { return nil }
        return query("SELECT \(columns) FROM threads WHERE id = ?", [id])?.first
    }

    /// The saved thread with this id: .some(nil) when there's none, nil when
    /// the database couldn't be read.
    static func lookUp(id: String) -> Thread?? {
        guard let rows = query("SELECT \(columns) FROM threads WHERE id = ?", [id]) else { return nil }
        return .some(rows.first)
    }

    /// The one saved thread whose id starts with `prefix` (hex digits and dashes),
    /// nil if there's none or more than one.
    static func thread(idPrefix prefix: String) -> Thread? {
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        guard let rows = query("SELECT \(columns) FROM threads WHERE id LIKE ? LIMIT 2", [prefix + "%"]) else { return nil }
        return rows.count == 1 ? rows[0] : nil
    }

    /// Recent sessions started in a project or any worktree of its repository, newest first.
    /// nil means the read failed, not that the project has no history.
    static func history(projectPath: String, limit: Int = 40) -> [SessionSummary]? {
        let dirs = directories(projectPath)
        let marks = dirs.map { _ in "?" }.joined(separator: ",")
        guard let rows = query("""
            SELECT \(columns) FROM threads
            WHERE \(interactive) AND preview <> '' AND cwd IN (\(marks))
            ORDER BY updated_at DESC LIMIT ?
            """, dirs + [min(limit, Int(Int32.max))]),
              let gone = removedWorktreeThreads(projectPath, dirs: dirs) else { return nil }
        let threads = (rows + gone).sorted { $0.modified > $1.modified }.prefix(limit)
        return threads.compactMap { t in
            guard let title = t.title ?? t.firstPrompt else { return nil }
            return SessionSummary(id: t.id, title: title, modified: t.modified,
                                  path: URL(fileURLWithPath: t.rolloutPath), kind: .codex)
        }
    }

    /// Sessions of the project's repository (same origin) whose worktree is gone from
    /// `git worktree list`: those in Codex's own worktrees ($CODEX_HOME/worktrees/<id>/<project
    /// folder name>), and those whose directory no longer exists. A subdirectory of the
    /// project is another project, so it never counts.
    private static func removedWorktreeThreads(_ projectPath: String, dirs: [String]) -> [Thread]? {
        guard let origin = GitProbe.origin(projectPath) else { return [] }
        var base = origin
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix(".git") { base.removeLast(4) }
        let marks = dirs.map { _ in "?" }.joined(separator: ",")
        guard let rows = query("""
            SELECT \(columns) FROM threads
            WHERE \(interactive) AND preview <> '' AND git_origin_url IN (?, ?) AND cwd NOT IN (\(marks))
            """, [base, base + ".git"] + dirs) else { return nil }
        let worktrees = home.appendingPathComponent("worktrees").path + "/"
        let name = (projectPath as NSString).lastPathComponent
        let insides = [projectPath, realpath(projectPath)].map { $0 + "/" }
        return rows.filter { t in
            guard !insides.contains(where: t.cwd.hasPrefix) else { return false }
            if t.cwd.hasPrefix(worktrees) {
                let rest = t.cwd.dropFirst(worktrees.count).split(separator: "/")
                if rest.count == 2 && rest[1] == name { return true }
            }
            return !FileManager.default.fileExists(atPath: t.cwd)
        }
    }

    private static func directories(_ projectPath: String) -> [String] {
        var dirs = [projectPath]
        for path in [realpath(projectPath)] + GitProbe.worktrees(projectPath) where !dirs.contains(path) {
            dirs.append(path)
        }
        return dirs
    }

    private static func realpath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Prompt search

    /// For each of these threads with a user message containing `query`, the first
    /// such message, from the thread history database Codex keeps beside the state one.
    /// The raw JSON is filtered first (fast), then the text parts of what's left.
    static func promptMatches(_ query: String, threadIDs: Set<String>) -> [String: PromptSnippet] {
        guard !threadIDs.isEmpty,
              let ids = try? JSONSerialization.data(withJSONObject: Array(threadIDs)),
              let messages = rows(newest("thread_history_"), """
                SELECT i.thread_id, MIN(i.rollout_ordinal), json_extract(part.value, '$.text')
                FROM thread_items AS i, json_each(i.item_json, '$.content') AS part
                WHERE i.item_type = 'userMessage' AND i.thread_id IN (SELECT value FROM json_each(?))
                  AND i.item_json LIKE ? ESCAPE '\\' AND json_extract(part.value, '$.text') LIKE ? ESCAPE '\\'
                GROUP BY i.thread_id
                """, [String(decoding: ids, as: UTF8.self),
                      "%" + likeEscaped(jsonEscaped(query)) + "%", "%" + likeEscaped(query) + "%"], { stmt in
                    text(stmt, 0).map { ($0, text(stmt, 2) ?? "") }
                })
        else { return [:] }
        var result: [String: PromptSnippet] = [:]
        for (id, text) in messages {
            result[id] = PromptSnippet(text, query: query)
        }
        return result
    }

    /// How far a prompt given to a thread at `since` got: whether it was submitted
    /// (a user message with that text), whether Codex gave its final answer in that
    /// turn, and the turn's status (completed, failed, interrupted, inProgress) when
    /// recorded. nil when the history can't be read.
    static func turnProgress(threadID: String, prompt: String, since: Date)
        -> (submitted: Bool, answered: Bool, status: String?)? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let turns = rows(newest("thread_history_"), """
            SELECT turn_id, json_extract(part.value, '$.text')
            FROM thread_items AS i, json_each(i.item_json, '$.content') AS part
            WHERE i.thread_id = ? AND i.item_type = 'userMessage' AND i.created_at_ms >= ?
            ORDER BY i.rollout_ordinal DESC
            """, [threadID, Int(since.timeIntervalSince1970 * 1000)], { stmt -> String? in
                guard let turn = self.text(stmt, 0),
                      self.text(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return nil }
                return turn
            })
        else { return nil }
        guard let turn = turns.first else { return (false, false, nil) }
        guard let answers = rows(newest("thread_history_"), """
            SELECT 1 FROM thread_items
            WHERE thread_id = ? AND turn_id = ? AND item_type = 'agentMessage'
              AND json_extract(item_json, '$.phase') = 'final_answer'
            LIMIT 1
            """, [threadID, turn], { _ in true })
        else { return nil }
        let status = rows(newest("thread_history_"), "SELECT status FROM thread_turns WHERE thread_id = ? AND turn_id = ?",
                          [threadID, turn], { self.text($0, 0) })?.first
        return (true, !answers.isEmpty, status)
    }

    /// The query as it appears inside a JSON string written by Codex (serde_json).
    private static func jsonEscaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    private static func likeEscaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "\\" || c == "%" || c == "_" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    // MARK: - SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }

    private static func query(_ sql: String, _ binds: [Any]) -> [Thread]? {
        rows(database(), sql, binds) { stmt in
            guard let id = text(stmt, 0) else { return nil }
            return Thread(
                id: id,
                cwd: text(stmt, 1) ?? "",
                title: text(stmt, 2)?.nonEmpty,
                firstPrompt: text(stmt, 3).flatMap(oneLine),
                branch: text(stmt, 4)?.nonEmpty,
                modified: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5))),
                rolloutPath: text(stmt, 6) ?? "")
        }
    }

    /// Runs a read-only query on a Codex database; a missing database has no rows.
    private static func rows<T>(_ url: URL?, _ sql: String, _ binds: [Any], _ row: (OpaquePointer?) -> T?) -> [T]? {
        guard let url else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        func failed() -> [T]? {
            NSLog("Vertty: Codex state query failed: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        // macOS SQLite cannot recreate missing WAL/SHM files on a READONLY
        // connection after Codex's last writer closes. Allow that bookkeeping,
        // but forbid SQL writes and never create the database itself.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return failed() }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else { return failed() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return failed()
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            if let n = value as? Int {
                sqlite3_bind_int64(stmt, Int32(i + 1), sqlite3_int64(n))
            } else {
                sqlite3_bind_text(stmt, Int32(i + 1), "\(value)", -1, transient)
            }
        }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { return failed() }
            if let value = row(stmt) { rows.append(value) }
        }
    }

    private static func oneLine(_ s: String) -> String? {
        let line = s.split(whereSeparator: \.isNewline).lazy.compactMap { String($0).nonEmpty }.first
        return line.map { String($0.prefix(120)) }
    }
}
