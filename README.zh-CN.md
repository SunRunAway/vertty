<p align="center"><img src="docs/icon.png" width="128" alt="Vhostty icon"></p>

<h1 align="center">Vhostty</h1>

<p align="center"><b>为 Claude Code 和 Codex 打造的垂直标签终端</b></p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

Vhostty 是一个支持 Claude Code 和 Codex 的 macOS 原生终端（基于 libghostty），按项目组织活跃和历史会话。

<p align="center"><img src="docs/screenshot.png" alt="Vhostty 截图：两个项目，Claude Code 和 Codex 的会话卡片上显示状态、分支、worktree 和 PR，右边是一个刚打开的新 Claude Code 会话"></p>

## 功能

- **项目与会话管理**：按项目组织 Claude Code 和 Codex 会话，展示分支、worktree 和 PR。
- **状态与通知**：实时显示 agent 状态，通过未读标记和系统通知提醒任务进展。
- **历史与恢复**：搜索、恢复历史会话，并自动保存打开的会话。
- **远程控制**：通过 iPhone、iPad 或另一台 Mac 访问和操作会话。
- **定时任务**：按计划运行 Claude Code 和 Codex 任务，支持用自然语言创建和管理。
- **防止睡眠**：任务运行时支持防合盖睡眠和保持屏幕常亮。
- **底部终端**：在会话下方打开跟随当前目录的 shell。
- **Ghostty 配置**：沿用已有的字体、主题和快捷键配置。

## 安装

适用于 Apple Silicon 的 Mac，macOS 14 及以上：

```bash
curl -fsSL https://raw.githubusercontent.com/SunRunAway/vhostty/master/scripts/install.sh | bash
```

它会从 [Releases](https://github.com/SunRunAway/vhostty/releases) 下载最新版本装到 `/Applications`。以后再运行一次就是更新。

App 没有经过 Apple 公证。如果你是用浏览器从 Releases 页面下载的 zip，macOS 会拒绝打开，需要到「系统设置 → 隐私与安全性」里点「仍要打开」，或者执行 `xattr -dr com.apple.quarantine /Applications/Vhostty.app`。

从源码构建与开发调试见[开发文档](DEVELOPER.md)。
