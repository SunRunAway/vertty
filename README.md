<p align="center"><img src="docs/icon.png" width="128" alt="Vhostty icon"></p>

<h1 align="center">Vhostty</h1>

<p align="center"><b>A vertical-tab terminal built for Claude Code and Codex</b></p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Vhostty is a native macOS terminal supporting Claude Code and Codex, built on libghostty. It organizes active and historical sessions by project.

<p align="center"><img src="docs/screenshot.png" alt="Vhostty with two projects: Claude Code and Codex session cards showing status, branch, worktree and PR, with a freshly started Claude Code session on the right"></p>

The interface follows your system language (English or Simplified Chinese).

## Features

- **Projects and sessions**: organize Claude Code and Codex sessions by project, with branch, worktree and PR information.
- **Status and notifications**: track agent status in real time, with unread indicators and system notifications for task updates.
- **History and restore**: search and resume past sessions, and automatically save open sessions.
- **Remote control**: access and control sessions from an iPhone, iPad or another Mac.
- **Scheduled tasks**: run Claude Code and Codex tasks on a schedule, with natural language support for creating and managing them.
- **Sleep prevention**: prevent sleep with the lid closed and keep the display on while tasks run.
- **Bottom shell**: open a shell below each session that follows its current directory.
- **Ghostty configuration**: reuse your existing fonts, theme and keybindings.

## Installing

Apple Silicon Macs, macOS 14 or later:

```bash
brew tap SunRunAway/tap
brew install --cask SunRunAway/tap/vhostty
```

This installs Vhostty into `/Applications` using our [Homebrew tap](https://github.com/SunRunAway/homebrew-tap). Update with `brew update && brew upgrade --cask vhostty`.

The app isn't notarized by Apple. The cask automatically removes its quarantine attribute after installation and upgrades, so you don't need to manually allow it on first launch. This bypasses the quarantine-triggered Gatekeeper check for Vhostty. If you download the zip from [Releases](https://github.com/SunRunAway/vhostty/releases) in a browser instead, allow it under System Settings → Privacy & Security → "Open Anyway", or run `xattr -dr com.apple.quarantine /Applications/Vhostty.app`.

For source builds and debugging, see the [developer documentation](DEVELOPER.md) (in Chinese).
