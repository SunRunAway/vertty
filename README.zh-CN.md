<p align="center"><img src="docs/icon.png" width="128" alt="Vhostty icon"></p>

<h1 align="center">Vhostty</h1>

<p align="center"><b>为 Claude Code 和 Codex 打造的垂直标签终端</b></p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

Vhostty 是一个 macOS 原生终端，专门用来同时跑好几个 Claude Code 和 Codex 会话。每个会话是左侧栏里的一张卡片，卡片上直接显示 agent 的状态（干活中 / 等你确认 / 等你输入 / 已完成）、所在分支、worktree 和 PR，不用挨个切过去看。

终端引擎是 [Ghostty](https://ghostty.org)（libghostty），直接沿用你的 Ghostty 配置；外壳用 SwiftUI/AppKit 写，没有用任何 Web 技术。

> Vhostty = **V**ertical + G**hostty**：把 Ghostty 的标签页竖过来，放进左侧栏。

<p align="center"><img src="docs/screenshot.png" alt="Vhostty 截图：两个项目，Claude Code 和 Codex 的会话卡片上显示状态、分支、worktree 和 PR，右边是一个正在工作的 Codex 会话"></p>

## 功能

- **左侧是项目**：每个项目绑定一个目录。
- **项目下面是会话卡片**：每个会话就是一个 Claude Code 或 Codex 终端。卡片有 4 行：
  1. 会话标题，前面带状态图标和 Claude / Codex 图标。Claude 的标题来自它自动生成的标题或 `/rename`，Codex 的来自它的会话标题
  2. 会话最后记录的分支（同一工作区的其他会话切分支不会覆盖它）
  3. worktree 名称；不在 worktree 里时显示「主工作区」
  4. PR 号，比如 `#123`。颜色表示状态：open 绿 / merged 紫 / closed 红，点击会在浏览器打开
- **新建会话**：自动 `cd` 到项目目录，然后启动 `claude` 或 `codex`。项目的 ⋯ 菜单里两种都有；「设置默认会话」按项目分别设置，决定在这个项目里 ⌘T 和 ✎ 按钮新建哪一种；没设置过的项目用全局默认（见[配置](#配置)）。agent 退出后，终端会留在你的 shell 里。新建的 Codex 会话在你发出第一条消息后才会和卡片对上。Codex 卡片连接 Vhostty 为它们启动的 app server（`codex app-server`，Vhostty 退出时停止），内置 skill 就是这样加载的。Vhostty 卡片里 Codex 的终端标题由 Vhostty 设置（会话 ID 从这里读），所以你的 `tui.terminal_title` 设置在卡片里不生效。
- **状态实时显示**：
  - 转圈 = agent 正在干活
  - ✋ = 等你确认权限（仅 Claude）
  - 无状态图标 = 空闲，没有未读提醒
  - 蓝点 = 在后台干完了、你还没看
  - 空心圆 = 未启动
- **后台通知**：通知直接用 agent 自带的终端通知（Claude Code 和 Codex 在 Ghostty 里都会发 OSC 9），所以会遵守你在 Claude 或 Codex 里的通知设置。会话没被选中或窗口在后台时，Vhostty 把它转成 macOS 系统通知，点击会跳到对应会话。Claude 一般在干完活、等你约 60 秒后才发通知；卡片上的蓝点和 Dock 角标则会立即更新（Claude 靠 Claude Code 的 hooks，Codex 靠它的终端标题）。
- **历史会话**：每个项目下面列出最近的 Claude 和 Codex 会话，点一下就用 `claude --resume` 或 `codex resume` 恢复。worktree 删掉以后，里面的会话也还在列表里。历史默认显示 5 条，每点一次“显示更多”追加 10 条，直到全部显示；折叠项目后恢复为 5 条。搜索按钮可以按标题、会话 ID 或你发过的提示词找会话。会话文件变化时，历史列表和打开的搜索结果会自动刷新，并保留每五分钟一次的兜底扫描。
- **自动保存**：退出时保存所有会话卡片。下次打开时，点哪个卡片才恢复哪个会话，不会一次性启动一堆 agent。
- **底部终端**：每个会话都能在 agent 下面拉出一个普通 shell（⌘J、⌃`，或标题栏右侧的按钮），目录跟 agent 当前所在目录一致。两块之间的分隔条可以拖动，面板开关状态会随会话保存。
- **防合盖睡眠**：让任务在合盖后继续运行，结束后恢复正常睡眠。兼容 Amphetamine：它正在开启防合盖睡眠时，Vhostty 不会关闭这项保护。首次启动时会询问一次；没有允许的话，以后可以在 Vhostty → 任务运行时防合盖睡眠：未授权… 中开启。授权后菜单项会打勾。
- **定时任务**：项目列表上方的「定时任务」列出所有任务，项目的 ⋯ 菜单里有「新建定时任务」。任务可以单次、每天、工作日或每周指定几天，在本机时间的某个时刻运行一段提示词。首次运行在后台新建一个 Claude 或 Codex 会话（卡片带小钟标记），之后每次都 resume 同一个会话，提示词通过 agent 的命令行参数传入。到点时如果这个会话开在某张卡片里，会先停掉它的 agent，可能打断你在里面的操作。只在 Vhostty 运行且电脑醒着时执行；错过多次时只补跑最近一次。每个任务保留运行记录（运行中 / 已完成 / 异常 / 已跳过）及原因。
  也可以直接在会话里跟 agent 说，比如“每周一早上 8 点检查这个项目有没有过期依赖”：Claude 用内置 skill、Codex 用内置工具（只在 Vhostty 启动的会话里加载，不往你的 Claude 或 Codex 配置里装任何东西），会在窗口右侧打开平时用的“新建定时任务”侧栏，参数已经填好。你点确认才保存，点取消就作废。修改任务同样打开它的侧栏，删除前也会先问你；暂停、恢复和立即运行直接生效。
- **复用 Ghostty 配置**：直接读取你的 Ghostty 配置（字体、主题、快捷键），在 `~/.config/ghostty/config` 或 `~/Library/Application Support/com.mitchellh.ghostty/config`。

## 快捷键

| 快捷键 | 作用 |
|---|---|
| ⌘T | 在当前项目新建会话（该项目的默认会话类型） |
| ⇧⌘O | 添加项目 |
| ⌘W | 关闭当前会话（agent 还在运行时会先问你） |
| ⌘1…9 | 切换到第 N 个会话 |
| ⇧⌘[ / ⇧⌘] | 上一个 / 下一个会话 |
| ⌃⌘S | 显示/隐藏侧栏 |
| ⌘J / ⌃` | 显示/隐藏底部终端 |
| ⌥⌘↑ / ⌥⌘↓ | 聚焦 Agent / 聚焦底部终端 |
| ⌘+ / ⌘- / ⌘0 | 字体放大 / 缩小 / 还原 |

会话卡片和项目都可以右键，里面有更多操作。会话卡片还能拖动排序。

## 配置

Vhostty 从你的登录 shell 读取下面的环境变量（和它的标签页跑的是同一个 shell，rc 文件也算），所以写在 `~/.zshrc` 之类的文件里，然后重启 Vhostty：

| 变量 | 作用 |
|---|---|
| `VHOSTTY_DEFAULT_AGENT` | `claude` 或 `codex`：全局默认会话类型，所有没在「设置默认会话」里单独设置的项目都用它。没设置时，用 Vhostty 首次启动时检测到已安装的那个：装了 `claude` 就是 Claude，否则装了 `codex` 就是 Codex。 |

## 安装

适用于 Apple Silicon 的 Mac，macOS 14 及以上：

```bash
curl -fsSL https://raw.githubusercontent.com/SunRunAway/vhostty/master/scripts/install.sh | bash
```

它会从 [Releases](https://github.com/SunRunAway/vhostty/releases) 下载最新版本装到 `/Applications`。以后再运行一次就是更新。

App 没有经过 Apple 公证。如果你是用浏览器从 Releases 页面下载的 zip，macOS 会拒绝打开，需要到「系统设置 → 隐私与安全性」里点「仍要打开」，或者执行 `xattr -dr com.apple.quarantine /Applications/Vhostty.app`。

## 构建

想自己从源码编译的话：

只需要 Command Line Tools 和 zig，**不需要 Xcode**。

```bash
brew install zig          # 需要 0.15.2（Ghostty 1.3.1 的要求）
git clone --recursive https://github.com/SunRunAway/vhostty.git
cd vhostty
make                      # 第一次会先编译 libghostty，大约 5 分钟
make install              # 拷贝到 /Applications/Vhostty.app
```

## 开发

实现原理、免 Xcode 构建的处理方式、调试方法见 [DEVELOPER.md](DEVELOPER.md)。
