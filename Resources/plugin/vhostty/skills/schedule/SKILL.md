---
name: schedule
description: Create, change, pause, resume, delete, run or list Vhostty scheduled tasks — prompts Vhostty runs on this Mac at set times ("every Saturday at 9 check dependencies", "move the dependency check to Sunday", "pause that task", "what's scheduled?"). In a Vhostty session, use this for any such request instead of cloud routines, cron, /loop or launchd.
---

# Vhostty scheduled tasks

Vhostty (the terminal app this session runs in) can run a prompt on a schedule: once, daily, on weekdays, or on chosen days of the week, at a time on this Mac's clock. A task's first run starts a new session in its project; later runs resume that same session. Runs happen only while Vhostty is running and the Mac is awake.

Pause, resume and run take effect at once. Create, edit and delete don't: they open Vhostty's own form (new task, edit task) or delete confirmation, filled in, in front of the user, and take effect only if the user confirms there; if they cancel, nothing is kept. Never say a task was created, changed or deleted unless `list` or `show` shows it.

## The command

Run `"$VHOSTTY_SCHEDULE_CLI" <command>` (an absolute path Vhostty sets in this session's environment). It prints JSON; `"ok": false` comes with an `"error"`. It talks to Vhostty over a local Unix socket; if a sandbox blocks that, rerun it outside the sandbox.

- `list` — tasks, with ids. Use it first when a request refers to an existing task.
- `show <task-id>` — one task and its recent runs.
- `create --name … --prompt … --repeat … --time HH:MM [--days …] [--date …] [--project …] [--agent …]`
- `edit <task-id> [any of those options]` — only what changes.
- `pause|resume|run <task-id>` — done at once; `run` runs it once now.
- `delete <task-id>` — asks the user to confirm.

Options:
- `--repeat once|daily|weekdays|weekly`; weekly needs `--days mon,tue,wed,thu,fri,sat,sun` (any subset); once needs `--date YYYY-MM-DD` in the future.
- `--time` is 24-hour, in this Mac's time zone.
- `--project` defaults to this session's project and `--agent` to this session's agent (claude or codex); they can't change once the task has run.
- For a long prompt, `--prompt-file -` reads it from stdin (use a quoted heredoc).

## How to handle a request

1. Get what's needed: what to do, when (days and time), and which project if it isn't this one. If the time, day or target task is unclear, ask; don't guess. If several tasks could match, ask which.
2. Write the prompt so it stands alone: the task runs later in a fresh session that hasn't seen this conversation, so include the context it needs (files, goals, what to report) rather than "as discussed".
3. Pick a short name for the task.
4. Run the command. For create or edit, tell the user the form is open in Vhostty for them to check and confirm, and mention what you filled in (name, schedule).
5. If they ask whether it went through, check with `list` or `show`.

The session you're in isn't the task's session: the task gets its own on its first run.
