import AppKit

// When Vertty is started from inside another terminal (or a Claude Code
// session), don't leak that parent's session markers into our terminals.
for key in ProcessInfo.processInfo.environment.keys
where key.hasPrefix("CLAUDE") || key.hasPrefix("GHOSTTY_") || key == "AI_AGENT" || key == "TMPPREFIX" {
    unsetenv(key)
}
// Nor the variables a Vertty card sets for its own session.
for key in ["VERTTY_TAB_ID", "VERTTY_SOCK", "VERTTY_CLAUDE_SETTINGS", "VERTTY_HOOK", "VERTTY_SCHEDULE_CLI",
            "VERTTY_SCHEDULE_RUN"] {
    unsetenv(key)
}
var tmpBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
if confstr(_CS_DARWIN_USER_TEMP_DIR, &tmpBuf, tmpBuf.count) > 0 {
    setenv("TMPDIR", String(cString: tmpBuf), 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
