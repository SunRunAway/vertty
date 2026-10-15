<p align="center"><img src="docs/icon.png" width="128" alt="Vhostty icon"></p>

<h1 align="center">Vhostty</h1>

<p align="center"><b>A vertical-tab terminal built for Claude Code and Codex</b></p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Vhostty is a native macOS terminal for running several Claude Code and Codex sessions at once. Each session is a card in the left sidebar, and the card shows the agent's state (working / waiting for permission / waiting for input / done), the current branch, the worktree and the PR, so you don't have to switch to each one to check on it.

The terminal engine is [Ghostty](https://ghostty.org) (libghostty), and it uses your existing Ghostty config. The app shell is written in SwiftUI/AppKit, with no web technology involved.

> Vhostty = **V**ertical + G**hostty**: Ghostty's tabs, turned on their side and moved into a sidebar.

<p align="center"><img src="docs/screenshot.png" alt="Vhostty with two projects: Claude Code and Codex session cards showing status, branch, worktree and PR, with a freshly started Claude Code session on the right"></p>

The interface follows your system language (English or Simplified Chinese).

## Features

- **Projects on the left**: each project is bound to a directory.
- **Session cards under each project**: each session is one Claude Code or Codex terminal. A card has 4 lines:
  1. The session title, with a status icon and a Claude or Codex icon in front. Claude's title comes from its auto-generated title or `/rename`, Codex's from its thread title
  2. The branch last recorded by that session (other sessions switching branches in the same checkout do not change it)
  3. The worktree name, or 「主工作区」 (main worktree) when not in a worktree
  4. The PR number, e.g. `#123`, colored by state: open green / merged purple / closed red. Click it to open the PR in your browser
- **New session**: `cd`s into the project directory and starts `claude` or `codex`. A project's ⋯ menu has both; "Set Default Session" picks, per project, which one ⌘T and the ✎ button start; a project that hasn't picked one uses the global default (see [Configuration](#configuration)). When the agent exits, the terminal stays in your shell. A new Codex session is matched to its card once you send its first message. Codex cards connect to an app server Vhostty runs for them (`codex app-server`, stopped when Vhostty quits), which is how they get Vhostty's built-in skill. Inside Vhostty, Codex's terminal title is set by Vhostty (it reads the session id from there), so your `tui.terminal_title` setting doesn't apply in its cards.
- **Live status**:
  - Spinner = the agent is working
  - ✋ = waiting for you to approve a permission (Claude only)
  - No status icon = idle, with no unread reminder
  - Blue dot = finished in the background and you haven't looked yet
  - Hollow circle = not started
- **Background notifications**: these are the agent's own terminal notifications (Claude Code and Codex both send OSC 9 in Ghostty), so your notification settings in Claude or Codex are respected. When the session isn't selected or the window is in the background, Vhostty turns them into macOS system notifications; clicking one jumps to that session. Claude usually only notifies after finishing and waiting about 60 seconds for you, but the blue dot on the card and the Dock badge update immediately (via Claude Code hooks, or Codex's terminal title).
- **Session history**: each project lists its recent Claude and Codex sessions; click one to resume it with `claude --resume` or `codex resume`. Sessions from worktrees you've since removed stay listed. Initially five past sessions are shown; Show More adds ten at a time until all are visible. Collapsing the project resets this to five. The search button finds sessions by title, session id, or the prompts you typed in them. History and open search results refresh automatically when session files change, with a five-minute fallback scan.
- **Autosave**: all session cards are saved on quit. On next launch a session is only restored when you click its card, so you don't get a pile of agents starting at once.
- **Sidebar**: the button at the top right of the sidebar hides it; the button beside the window controls shows it again. ⌃⌘S also toggles it.
- **Bottom shell**: every session can pull up a plain shell below the agent (⌘J, ⌃`, or the button at the right of the title bar), in the same directory the agent is currently in. The divider between the two is draggable, and whether the panel is open is saved with the session.
- **Closed-lid sleep protection**: keep tasks running with the lid closed, then restore normal sleep when they finish. Compatible with Amphetamine: Vhostty preserves its active closed-display sleep protection. Vhostty asks once at first launch; if you didn't allow it, turn it on later from Vhostty → Closed-Lid Sleep Protection While Tasks Run: Not Authorized…. Once authorized, the same item turns it on or off.
- **Don't Let the Display Turn Off**: off by default. When checked in the Vhostty menu, the display doesn't turn off while tasks run, even with the lid closed. No authorization needed.
- **Scheduled tasks**: "Scheduled Tasks" above the projects lists them; a project's ⋯ menu has "New Scheduled Task…". A task runs a prompt once, daily, on weekdays or on chosen days of the week, at a time on the Mac's clock. Its first run starts a new Claude or Codex session in a background card (marked with a clock); every later run resumes that same session, passing the prompt on the agent's command line. If that session is open in a card when the task fires, its agent is stopped first, which can interrupt what you're doing there. Runs only happen while Vhostty is running and the Mac is awake; after missed runs, only the latest one is caught up. Each task keeps its runs (running / done / error / skipped) with their reasons.
  You can also ask the agent in a session, e.g. "every Monday at 8, check this project for outdated dependencies": a built-in skill for Claude, or built-in tools for Codex (only in sessions Vhostty starts; nothing is installed into your Claude or Codex config), opens the usual New Scheduled Task panel on the right of the window, filled in. Nothing is saved until you confirm it; Cancel drops it. Changing a task opens its panel the same way, and deleting asks first; pausing, resuming or running one takes effect at once.
- **Remote control**: check Vhostty → Allow Remote Connections (off by default, remembered), and another device can use this Mac's sessions: the Vhostty iOS app (iPhone and iPad), or Vhostty on another Mac (File → Connect to Remote Computer…). While it's on, the menu shows the port and the connected device under it; on the other device, enter this Mac's address and that port. One device at a time: a new one takes over and the old one shows that it was connected elsewhere. A remote device sees the projects, cards and history, opens a card's terminal, starts, resumes and closes sessions, and gets the sessions' notifications while connected. A session's terminal size follows whoever entered, resized or typed last; leaving gives it back this Mac's size. The connection is unencrypted and has no password: anyone who can reach the port can use your sessions, so keep it to networks you trust, such as a VPN.
- **Reuses your Ghostty config**: reads your Ghostty config (fonts, theme, keybindings) from `~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘T | New session in the current project (of that project's default kind) |
| ⇧⌘O | Add project |
| ⇧⌘K | Connect to a remote computer |
| ⌘W | Close the current session (asks first if the agent is still running) |
| ⌘1…9 | Switch to the Nth session |
| ⇧⌘[ / ⇧⌘] | Previous / next session |
| ⌃⌘S | Show/hide the sidebar |
| ⌘J / ⌃` | Show/hide the bottom shell |
| ⌥⌘↑ / ⌥⌘↓ | Focus Agent / focus the bottom shell |
| ⌘+ / ⌘- / ⌘0 | Increase / decrease / reset font size |

Right-click a session card or a project for more actions. Session cards and projects can also be dragged to reorder.

## Configuration

Vhostty reads these environment variables from your login shell (the same shell its tabs run, rc files included), so set them in e.g. `~/.zshrc` and restart Vhostty:

| Variable | Effect |
|---|---|
| `VHOSTTY_DEFAULT_AGENT` | `claude` or `codex`: the global default session kind, used by every project that hasn't picked its own under "Set Default Session". When unset, Vhostty uses what it found installed on its first launch: Claude if `claude` was there, else Codex if `codex` was. |
| `VHOSTTY_REMOTE_PORT` | The port remote devices connect to when Allow Remote Connections is on. Default `58563`. If it isn't a valid port or can't be used, the menu shows "Failed to start" and why under the item. |

## Installing

Apple Silicon Macs, macOS 14 or later:

```bash
curl -fsSL https://raw.githubusercontent.com/SunRunAway/vhostty/master/scripts/install.sh | bash
```

This downloads the latest build from [Releases](https://github.com/SunRunAway/vhostty/releases) into `/Applications`. Run it again to update.

The app isn't notarized by Apple. If you download the zip from the Releases page in a browser instead, macOS will refuse to open it. Allow it under System Settings → Privacy & Security → "Open Anyway", or run `xattr -dr com.apple.quarantine /Applications/Vhostty.app`.

## Building

To build from source instead:

You only need the Command Line Tools and zig; **Xcode is not required**.

```bash
brew install zig          # needs 0.15.2 (required by Ghostty 1.3.1)
git clone --recursive https://github.com/SunRunAway/vhostty.git
cd vhostty
make                      # the first build compiles libghostty, about 5 minutes
make install              # copies to /Applications/Vhostty.app
```

The iOS app (iPhone and iPad) is in `iOS/Vhostty.xcodeproj` and does need Xcode. Build its terminal library first with `scripts/build-ghostty-ios.sh` (the same Ghostty as the Mac app, a few minutes), then open the project, pick your team under Signing, and run it on your device.

## Development

How it works, how the build avoids Xcode, and how to debug are covered in [DEVELOPER.md](DEVELOPER.md) (in Chinese).
