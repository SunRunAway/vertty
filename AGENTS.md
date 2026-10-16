# Agent notes

## Workflow

- Only edit `README.md` and `README.zh-CN.md` when the user asks to edit `README.md`, and keep both versions in sync.
- When working in the main checkout, once a change is done and verified,
  commit it and push to `origin/master` without asking first.
- When the user asks you to work in a worktree, someone else is working in the
  main checkout. Commit in the worktree and stop there: don't push, merge into
  the main checkout, run `make install`, or remove the worktree until the user
  says whether it goes up as a PR or is merged locally. After it's merged,
  remove the worktree and its branch and fast-forward the main checkout.
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
  `VERTTY_SUPPORT_DIR=<scratch> VERTTY_DEBUG_SNAPSHOT=<scratch>`. Send input
  only with `to <uuid>` to tabs the test created. Never open, type into, or
  start sessions in the user's real projects.
- The user works in the installed copy (`/Applications/Vertty.app`). Start a
  test instance of `build/Vertty.app` only with `launch()` in
  `scripts/testapp.py`, in tests and by hand alike: it starts the app in the
  background, so it never comes in front of the user's windows. Running the
  binary directly brings it to the front. Stop the instance by the pid
  `launch()` returns; don't use `pkill -f`. Also stop any `claude attach`
  clients the test started, but never the user's own.

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
  `ai-title` of the new transcript. Vertty takes card titles from `ai-title`,
  so the card keeps the old title instead of looking like a new session. This
  is expected: leave it, and don't override Claude Code's naming.
- Claude Code only: don't follow the `continued-in` records Claude Code writes
  for sessions sent to the background; that handling was removed on purpose in
  814ac47. A `claude -r` typed into a tab is tracked through
  `~/.claude/sessions` (`LiveSessions`). Before re-adding any mechanism, check
  `git log -S` for whether it was removed on purpose.
- The default session kind (Claude / Codex) is a per-project setting, not a
  global one.
- After ⌘Q the Dock can keep showing Vertty as running in the background while
  processes it spawned (e.g. shell plugin helpers) are still alive. That isn't a
  Vertty bug, and it would happen the same in any terminal. Don't kill
  processes on quit to hide it.
