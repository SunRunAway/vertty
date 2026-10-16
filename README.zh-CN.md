<p align="center"><img src="docs/icon.png" width="128" alt="Vertty icon"></p>

<h1 align="center">Vertty</h1>

<p align="center"><b>为 agents 打造的终端，支持按项目分组的标签、iOS 远程访问和定时任务。</b></p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

Vertty 是一个为 agents 打造的 macOS 原生终端（基于 libghostty），按项目组织活跃和历史会话。

<p align="center"><img src="docs/screenshot.png" alt="Vertty 截图：两个项目，Claude Code 和 Codex 的会话卡片上显示状态、分支、worktree 和 PR，右边是一个刚打开的新 Claude Code 会话"></p>

## 功能

- **项目与会话管理**：按项目组织会话、跟踪 agent 状态，并恢复历史对话。
- **远程控制**：通过 iPhone、iPad 或另一台 Mac 访问和操作会话，可用内置的 Tailscale（两端登录即可）或自行组网连接。
- **定时任务**：按计划运行 Claude Code 和 Codex 任务，支持用自然语言创建和管理。
- **防止睡眠**：任务运行时支持防合盖睡眠和保持屏幕常亮。
- **底部终端**：在会话下方打开跟随当前目录的 shell。
- **Ghostty 配置**：沿用已有的字体、主题和快捷键配置。

## 支持的 Agents

目前支持 Claude Code 和 Codex。

## 安装

适用于 Apple Silicon 的 Mac，macOS 14 及以上：

```bash
brew tap SunRunAway/tap
brew install --cask SunRunAway/tap/vertty
```

它会通过我们的 [Homebrew tap](https://github.com/SunRunAway/homebrew-tap) 将 Vertty 安装到 `/Applications`。更新请运行 `brew update && brew upgrade --cask vertty`。

不使用 Homebrew 的安装方式见[手动安装](docs/manual-installation.zh-CN.md)。

从源码构建与开发调试见[开发文档](DEVELOPER.md)。
