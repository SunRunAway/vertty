<p align="center"><img src="docs/icon.png" width="128" alt="Vertty icon"></p>

<h1 align="center">Vertty</h1>

<p align="center"><b>A vertical-tab terminal built for Claude Code and Codex, organized by project</b></p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Vertty is a native macOS terminal supporting Claude Code and Codex, built on libghostty. It organizes active and historical sessions by project.

<p align="center"><img src="docs/screenshot.png" alt="Vertty with two projects: Claude Code and Codex session cards showing status, branch, worktree and PR, with a freshly started Claude Code session on the right"></p>

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
brew install --cask SunRunAway/tap/vertty
```

This installs Vertty into `/Applications` using our [Homebrew tap](https://github.com/SunRunAway/homebrew-tap). Update with `brew update && brew upgrade --cask vertty`.

For installation without Homebrew, see [manual installation](docs/manual-installation.md).

For source builds and debugging, see the [developer documentation](DEVELOPER.md) (in Chinese).
