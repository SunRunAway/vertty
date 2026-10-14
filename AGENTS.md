# Agent notes

## Workflow

- When a change is done and verified, commit it and push to `origin/master`
  without asking first.
- For changes that only touch documentation (including `AGENTS.md`, README
  files, and `docs/`) or test scripts (`scripts/test-*`), verify the text and
  links, then commit and push without building, running tests, starting test
  instances, or running `make install`.
- After pushing changes that affect the app's code, bundled resources, or
  build configuration, run `make install` without asking.
- `scripts/bundle.sh` (and so `make app` / `make install`) runs `sandbox-exec`
  internally, so it fails inside another sandbox. Run the build unsandboxed.

## Testing

- Test against a scratch state dir and the debug driver only (see DEVELOPER.md):
  `VHOSTTY_SUPPORT_DIR=<scratch> VHOSTTY_DEBUG_SNAPSHOT=<scratch>`. Send input
  only with `to <uuid>` to tabs the test created. Never open, type into, or
  start sessions in the user's real projects.
- The user works in the installed copy (`/Applications/Vhostty.app`). Start the
  test instance from `build/Vhostty.app/Contents/MacOS/Vhostty`, save `$!`, and
  stop it by that PID. Don't use `pkill -f`: an absolute-path pattern misses an
  instance started from the relative path. Also stop any `claude attach` clients
  the test started, but never the user's own.

## Design decisions (keep unless the user says otherwise)

- No tab bar at the top. Sessions are four-line cards in the left sidebar
  (title / branch / worktree / PR). New cards go at the top of their project.
- System notifications come from the agent's own OSC 9/777 notifications
  through Ghostty, not from hooks.
- The bottom shell panel is toggled by one icon button at the right end of the
  title strip above the terminal, a menu item under View, and the ⌘J and ⌃`
  shortcuts. It stays out of the empty-state hints.
- Don't dim the unfocused pane.
- No renaming of session titles from the sidebar. The claude CLI can only name
  a session at launch (`--name`) or by typing `/rename` inside it, and typing
  into the terminal is fragile. If it can't be done cleanly, don't do it.
- Claude Code only: a Claude session can be sent to the background (a job you
  reattach with `claude attach`). Running `/clear` in such a job starts a new
  session with a new id, but Claude Code writes the job's old name as the first
  `ai-title` of the new transcript. Vhostty takes card titles from `ai-title`,
  so the card keeps the old title instead of looking like a new session. This
  is expected: leave it, and don't override Claude Code's naming.
- Claude Code only: don't follow the `continued-in` records Claude Code writes
  for sessions sent to the background; that handling was removed on purpose in
  814ac47. A `claude -r` typed into a tab is tracked through
  `~/.claude/sessions` (`LiveSessions`). Before re-adding any mechanism, check
  `git log -S` for whether it was removed on purpose.
- The default session kind (Claude / Codex) is a per-project setting, not a
  global one.
- After ⌘Q the Dock can keep showing Vhostty as running in the background while
  processes it spawned (e.g. shell plugin helpers) are still alive. That isn't a
  Vhostty bug, and it would happen the same in any terminal. Don't kill
  processes on quit to hide it.
