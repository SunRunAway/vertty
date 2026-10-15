import Foundation

/// Builds the command that starts Claude Code (or Codex) inside a tab.
enum ClaudeLauncher {
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// Writes the extra settings file passed via `claude --settings`. It only adds
    /// hooks (merged with the user's own settings); the user's config is untouched.
    static func writeSettings() {
        guard !hookPath.isEmpty else { return }
        let hook: [String: Any] = ["type": "command", "command": ShellQuote.quote(hookPath), "timeout": 5]
        var hooks: [String: Any] = [:]
        for name in hookEvents {
            var entry: [String: Any] = ["hooks": [hook]]
            if name == "PostToolUse" { entry["matcher"] = "*" }
            hooks[name] = [entry]
        }
        let settings: [String: Any] = ["hooks": hooks]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: AppPaths.claudeSettings, options: .atomic)
        }
    }

    static func launcherPath(_ kind: AgentKind) -> String {
        (Bundle.main.resourcePath ?? "") + "/bin/vhostty-\(kind.rawValue)"
    }

    /// The shell command for a new tab: an interactive login shell (so the user's
    /// PATH and rc files apply) that runs the agent, then stays open as a normal shell.
    /// Claude gets the session id up front. Codex can't, so its terminal title is set
    /// to its activity spinner, the thread title and the thread id (cut to its first
    /// 29 characters), and AppStore.terminalTitleChanged reads the id from there.
    /// A scheduled run passes its prompt as the agent's prompt argument, never
    /// by typing into the terminal.
    static func command(kind: AgentKind, sessionID: String, resume: Bool, prompt: String? = nil) -> String {
        let shell = ShellQuote.quote(ShellEnvironment.shell)
        var args: String
        switch kind {
        case .claude: args = "\(resume ? "--resume" : "--session-id") \(sessionID)"
        case .codex:
            let title = "-c " + ShellQuote.quote(#"tui.terminal_title=["activity","thread-title","thread-id"]"#)
            args = resume ? "resume \(title) \(ShellQuote.quote(sessionID))" : title
        }
        // A leading "-" would read as an option.
        if let prompt { args += " " + ShellQuote.quote(prompt.hasPrefix("-") ? " " + prompt : prompt) }
        let inner = "\(ShellQuote.quote(launcherPath(kind))) \(args); exec \(shell) -l"
        // libghostty already runs this as `exec -l <command>` under /bin/bash.
        return "\(shell) -l -i -c \(ShellQuote.quote(inner))"
    }

    static func environment(tabID: UUID, scheduleRunID: UUID? = nil) -> [String: String] {
        var env = [
            "VHOSTTY_TAB_ID": tabID.uuidString,
            "VHOSTTY_SOCK": AppPaths.hookSocket,
            "VHOSTTY_CLAUDE_SETTINGS": AppPaths.claudeSettings.path,
            "VHOSTTY_HOOK": hookPath,
            // Serves the scheduled-task tools to Claude and Codex over MCP.
            "VHOSTTY_SCHEDULE_CLI": scheduleCLIPath,
        ]
        // Tells the launcher not to swap a scheduled resume for `claude attach`.
        if let scheduleRunID { env["VHOSTTY_SCHEDULE_RUN"] = scheduleRunID.uuidString }
        return env
    }

    static var scheduleCLIPath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vhostty-schedule").path ?? ""
    }

    static var hookPath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vhostty-hook").path ?? ""
    }
}
