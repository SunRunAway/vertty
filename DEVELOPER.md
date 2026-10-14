# Vhostty 开发者文档

给想了解实现或参与开发的人看。使用说明见 [README](README.zh-CN.md)。

## 工作原理

### Claude 是怎么启动的

每个会话用的命令大致是：

```
$SHELL -l -i -c 'vhostty-claude --session-id <uuid>; exec $SHELL -l'
```

- `vhostty-claude` 实际执行的是 `claude --settings <Vhostty 的 hooks 配置> ...`。这份 hooks 配置会和你自己的 `~/.claude/settings.json` **合并**，你自己的配置不会被改动。
- 会话 ID 由 Vhostty 生成，所以它确切知道每张卡片对应哪个 Claude 会话，之后也能 `--resume` 恢复。
- Claude 退出后在同一个 tab 里手动跑 `claude -r <id>` 也会被跟踪：Claude Code 为每个运行中的进程写 `~/.claude/sessions/<pid>.json`，Vhostty 从进程环境变量里的 `VHOSTTY_TAB_ID` 认出它属于哪张卡片，把卡片切到那个会话。这样起的 claude 不带 hooks，状态只能靠终端标题。

### Codex 会话

Codex 每张卡片跑的是 `vhostty-codex -c tui.terminal_title=…`（新建）或 `vhostty-codex resume -c tui.terminal_title=… <id>`（恢复），它只是调用 `codex`，退出后通过 `vhostty-hook` 告诉 App。和 Claude 的不同：

- Codex 不能预先指定会话 ID，进程上也看不出它在跑哪个会话。所以 Vhostty 用 `-c` 把卡片里 Codex 的终端标题设成 `["activity","thread-title","thread-id"]`，卡片从自己的终端标题里读 ID：`thread-id` 被截成前 29 个字符加 `...`，一直都在；会话还没起名时，`thread-title` 显示完整 ID。
- Codex 在发出第一条消息时才保存会话，没保存的会话不能 `codex resume`。所以读到的 ID（或前缀）先记在 `codexThreadID`，等 Codex 的会话索引 `~/.codex/state_<n>.sqlite` 的 `threads` 表里有且只有一个会话以它开头，才把那个会话的完整 ID 作为卡片的会话 ID。在 Codex 里用 `/new`、`/resume` 换了会话，标题里的 ID 变了，卡片也跟着换。
- 不注入 Codex hooks（Codex 的 hooks 要用户手动信任）。状态来自终端标题：有转圈就是工作中。启动和恢复时 Codex 也会转一会儿，这一段不算一轮工作。
- 历史会话、标题、分支也来自 `threads` 表（只列用户自己发起的会话，不含子代理、自动化和已归档的）。除了 cwd 是项目目录或现存 worktree 的会话，同一仓库（`git_origin_url` 和项目的 origin 一致）里 worktree 已删除的会话也算：cwd 在 Codex 自己的 worktree 目录 `$CODEX_HOME/worktrees/<id>/<项目目录名>` 下，或者 cwd 已经不存在。项目的子目录算别的项目，不计入。
- Codex 的数据目录是 `CODEX_HOME`（默认 `~/.codex`）。卡片里的 Codex 由交互式登录 shell 启动，所以 Vhostty 启动时也用 `$SHELL -l -i -c` 读这个变量。
- 卡片里的 Codex 用 `--no-daemon` 启动：不连 Codex 的共享后台服务（daemon），在自己进程里跑 app server。这样会话是本地的（`/worktree` 等可用），卡片关掉这一轮也就停了。不用 `--remote` 连 Vhostty 自己的 server，因为 Codex 把任何显式 `--remote` 都当远程工作区，会关掉 worktree 等本地功能。

### 历史会话的范围和搜索

Claude 的历史来自项目自己的会话记录目录、`git worktree list` 里每个 worktree 的目录，以及所有 `<项目编码>--claude-worktrees-*` 目录：Claude Code 自己的 worktree（`<项目>/.claude/worktrees/<名字>`）删掉后，里面的会话仍能从项目目录 `claude --resume`。Codex 的范围见上一节。

搜索匹配标题、会话 ID 和用户发过的提示词，范围就是这个项目的会话列表（打开的卡片和历史）。提示词不缓存，每次搜索直接读：Claude 读 `~/.claude/history.jsonl`（Ctrl+R 用的提示词历史，含粘贴的原文），Codex 查 `thread_history_<n>.sqlite` 里 `userMessage` 的文本。只靠提示词命中的会话下面多显示一行匹配片段。

### 历史刷新

`HistoryWatcher` 用 FSEvents 监听 Claude JSONL 和 Codex state SQLite/WAL 的外部变化，Codex 另用 vnode 写入通知覆盖长期打开的 WAL 连接。合并短时间内的事件后重新读取历史，也更新打开的搜索结果。忽略本进程的 SQLite 文件维护事件，避免循环刷新；同一时间最多执行一轮历史读取，期间收到事件则补一轮。启动、激活、唤醒和每五分钟的兜底扫描保证恢复；读取失败仍保留上次结果。

`python3 scripts/test-history-watcher.py` 在 `/private/tmp` 测试实际文件事件（含目录创建、替换、删除和 WAL）；`python3 scripts/test-codex-history.py` 用隔离 App 验证自动刷新、搜索和 SQLite 失败恢复。两者均不启动真实 agent 会话。

### 卡片上的信息从哪来

| 信息 | 来源 |
|---|---|
| 标题 | Claude 写到终端标题的内容（`✳ xxx` / `◑ xxx`）；也会读会话记录 `~/.claude/projects/*/<id>.jsonl` 里的 `custom-title` / `ai-title` |
| 状态 | Claude Code hooks：`UserPromptSubmit` / `PostToolUse` → 工作中，`Notification` → 等你确认，`Stop` → 完成。终端标题前面的状态符号（`✳` 空闲，其他转圈符号表示工作中）作为补充 |
| 系统通知 | Claude Code 自己发出的终端通知（OSC 9/777），由 Vhostty 转成 macOS 通知 |
| 分支 | 会话自身记录的分支：Claude transcript 的 `gitBranch`，Codex `threads` 的 `git_branch`。不读取共享工作目录的当前 HEAD，避免其他会话切分支覆盖旧卡片 |
| worktree | 对会话 cwd 执行 `git rev-parse`，并结合 Claude 的 `worktree-state` |
| PR | 用 `gh pr view <branch>` 查会话记录的功能分支对应的 PR（查不到则留空）；会话回到 main/master 等非功能分支后，用其记录里的 `pr-link` |

hooks 事件的传递路径：`vhostty-hook`（App 里自带的一个小程序）通过 Unix socket，把事件转发给 App。

### 定时任务

产品规则见 [docs/spec/schedule-product.md](docs/spec/schedule-product.md)。任务和运行记录存在状态目录的 `schedules.json`。

- **计划**：每个任务记着下一次还没处理的计划时间 `nextPlan`。每 20 秒、启动和唤醒时检查一次：到点的计划里只运行最近一次，更早的直接丢掉；先把新的 `nextPlan` 写盘再启动，所以重复检查、唤醒或重启都不会重复提交。时间按本机系统时区计算，系统时区变了就重算 `nextPlan`（`Calendar.nextDate`，夏令时跳过的时刻顺延，重复的时刻只取第一次）。
- **执行**：提示词作为 agent 的命令行参数传入（`claude --session-id/--resume <id> <提示词>`、`codex [resume <id>] <提示词>`），从不往终端里打字。首次运行在项目顶部新建一张后台卡片；之后 resume 任务绑定的会话 ID。这个会话开在某张卡片里时，先释放那张卡片的终端，等它的 agent 进程（Claude 看 `~/.claude/sessions`，外加带这张卡片 `VHOSTTY_TAB_ID` 的 `claude`、`vhostty-hook` 进程；Codex 看带 `tui.terminal_title` 参数的 TUI 进程）都退出后，再在同一张卡片里 resume。确认不了已停止就记异常，不启动第二个实例；卡片的终端已经没了也照样先查一遍进程。停止期间选中这张卡片不会重新拉起它。Claude 会话如果在 Vhostty 之外（别的终端、底部终端、后台任务）还有进程，不碰它，直接记异常，因为再 resume 会让会话分叉。
- **状态**：Claude 靠 hooks：`UserPromptSubmit` 表示已提交，`Stop` 表示已完成，没有 `Stop` 就空闲下来算中断。Codex 没有 hooks，查 `thread_history_<n>.sqlite`：本轮的 `userMessage` 出现表示已提交，同一轮有 `phase` 为 `final_answer` 的 `agentMessage` 表示已回复。App 重启时还在运行的记录记为异常。
- **对话里管理**：内置 skill 在 `Resources/plugin/vhostty/skills/schedule/SKILL.md`，Claude 由 `vhostty-claude` 加 `--plugin-dir` 加载，技能名 `vhostty:schedule`，它调用 `$VHOSTTY_SCHEDULE_CLI`（即 `vhostty-schedule`）。Codex 没有只对单个会话加 skill 的办法，所以改用 MCP：`vhostty-codex` 用 `-c mcp_servers.vhostty…` 给这张卡片挂上 `vhostty-schedule mcp`，同样的操作做成工具，使用说明写在工具描述和 server 的 instructions 里，不写 Codex 的配置文件。`vhostty-schedule` 它通过 hook socket 发 `schedule\n<JSON>` 请求并读回 JSON。接口能查询，能直接暂停、恢复、立即运行（跟界面上一样一键完成）；新建、编辑和删除只是打开平时用的任务侧栏或删除确认框，参数已填好，用户确认才保存，取消就什么都不留。接口没有批准操作，请求里多出的字段会被拒绝；侧栏有未保存的改动或确认框开着时，新的请求直接报错。`claude-settings.json` 里的 `sandbox.network.allowUnixSockets` 只放行这个 socket，让 skill 在 Claude Code 的沙箱里也能连上。
- **显示器休眠**：显示器全部休眠时没有可用的显示器，libghostty 原本会因为建不了 CVDisplayLink 而创建终端失败；补丁里改成这时不用 display link，靠内容变化驱动绘制，这样定时任务在显示器关着时也能启动。

## 为了不装 Xcode 做的处理

Ghostty 官方的 macOS 构建依赖 Xcode。为了只用 Command Line Tools 就能编译，`patches/ghostty-vhostty.patch` 对 Ghostty 做了这些改动：

1. **Metal 着色器改成运行时编译**（`newLibraryWithSource`）。这样就不需要 Xcode 自带的 `metal` 编译器。
2. **在 macOS 上额外输出静态库 `libghostty.a` 和资源文件**。官方构建只产出 xcframework。
3. **修复打包问题**：新版 `libtool` 会静默丢弃 zig 打包时没有 8 字节对齐的目标文件，改成先解包再重新打包。

补丁里还有一处与 Xcode 无关：显示器全部休眠时，终端不用 CVDisplayLink 也能创建（见上文“定时任务”）。

`scripts/build-ghostty.sh` 编译前把补丁打到 `vendor/ghostty` 的工作区里，之后一直留着。`.gitmodules` 设了 `ignore = dirty`，所以主仓库的 `git status` 不显示这些改动；要看补丁是否打上，用 `git -C vendor/ghostty status`。

另外还有两个绕路：

- `scripts/make-zig-sdk.sh`：macOS 26 以后的 SDK 里，库描述文件只写了 arm64e 架构，zig 0.15 识别不了。这个脚本用 APFS 克隆一份 SDK（几乎不占空间），补上 arm64。
- `scripts/bundle.sh`：用 macOS 26 SDK 编译 Swift。因为 macOS 27 SDK 把 SwiftUI 的 `@State` 改成了宏，而宏插件只随 Xcode 提供。

## 开发调试

```bash
VHOSTTY_SUPPORT_DIR=/tmp/vhostty-test \
VHOSTTY_DEBUG_SNAPSHOT=/tmp/vhostty-snap \
build/Vhostty.app/Contents/MacOS/Vhostty
```

- `VHOSTTY_SUPPORT_DIR`：使用一份独立的状态目录，不影响正式数据。
- `VHOSTTY_DEBUG_SNAPSHOT`：每 1.5 秒把窗口截图和状态写到这个目录（`window.png`、`state.txt`）。往 `input.txt` 写命令可以驱动 App，一行一条：

| 命令 | 作用 |
|---|---|
| `to <UUID>` / `toshell <UUID>` | 指定后面按键发给哪个会话的 Claude 终端 / 底部终端 |
| `text …`、`enter`、`up`、`down`、`esc` | 往指定的终端输入文字或按键 |
| `notify` | 给指定会话发一条测试通知，授权状态写到 `notify.txt` |
| `select <UUID>` | 切换到这个会话 |
| `new` / `new claude` / `new codex` | 新建默认类型 / Claude / Codex 会话 |
| `search [文字]` / `endsearch` | 打开当前项目的会话搜索并填入文字 / 关闭搜索 |
| `morehistory` / `toggleproject` | 当前项目追加 10 条历史 / 折叠或展开项目 |
| `refreshhistory` | 立即刷新历史列表 |
| `toggleshell` | 开关当前会话的底部终端 |
| `focus claude` / `focus shell` | 聚焦上面 / 下面的终端 |
| `menukey <ctrl\|cmd> <字符>` | 把快捷键直接交给主菜单处理 |
| `post <ctrl\|cmd\|none> <字符>` | 模拟一次真实按键，走 AppKit 正常的分发流程 |
| `schedules` / `schedule <任务 UUID>` | 打开定时任务列表 / 某个任务的侧栏 |
| `runschedule <任务 UUID>` / `tickschedules` | 立即运行一个任务 / 立即检查到点的计划 |
| `newschedule` / `closepanel` | 打开新建任务侧栏 / 关闭侧栏 |
| `panelsave` / `panelcancel` | 保存 / 撤销侧栏里的改动（等于点“保存”/“取消”） |
| `cmdj-through-terminal` | 检查 ⌘J 是被终端吃掉还是交给了菜单，结果写到 `keyequiv.txt` |

按键和文字只会发给用 `to` / `toshell` 明确指定的会话。截图时如果有确认框（sheet）打开，另存为 `sheet.png`；`state.txt` 末尾列出定时任务及其运行记录。

`make app` 后运行 `python3 scripts/test-codex-history.py`，可在临时状态目录和数据库里验证 Codex 历史在最后一个数据库写连接关闭、数据库暂时被锁、恢复和真正清空时的行为；测试不会启动终端会话，并按 PID 停止自己的 App 实例。

`python3 scripts/test-session-branches.py` 用临时 HOME、仓库、会话记录及模拟的 agent/gh，验证共享工作区切分支不会覆盖其他会话的分支和 PR，同时检查会话自身换分支、回到 master 时的 PR 更新。测试按 PID 停止自己的 App 实例。

## 发布

推一个 `v` 开头的标签，GitHub Actions（`.github/workflows/release.yml`）就会在 macOS arm64 机器上编译，把 `Vhostty.zip` 发到同名的 Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

版本号取自标签，写进 `Info.plist` 的 `CFBundleShortVersionString`。libghostty 按 Ghostty 版本和补丁缓存，补丁不变时不会重新编译。在 Actions 页面手动运行这个 workflow 只编译、上传构建产物，不发 Release。用户通过 `scripts/install.sh` 安装最新的 Release。

## 文档

README 有英文（`README.md`）和中文（`README.zh-CN.md`）两份，改功能、快捷键或构建步骤时两份要一起改。

## 多语言

界面文字在代码里写英文（`String(localized:)`，以及 SwiftUI 的 `Text` / `Button` 等字面量），简体中文翻译在 `Resources/zh-Hans.lproj/Localizable.strings`，英文的单复数在 `Resources/en.lproj/Localizable.stringsdict`。App 跟随系统语言；想单独切换，可以在「系统设置 → 通用 → 语言与地区 → 应用程序」里给 Vhostty 指定语言，或者：

```bash
defaults write dev.vhostty.Vhostty AppleLanguages '("en")'   # 恢复：defaults delete dev.vhostty.Vhostty AppleLanguages
```

新增文字时记得同时在 `zh-Hans.lproj` 里加一条翻译，key 就是英文原文（插值写成 `%@` / `%lld`）。

### 防合盖睡眠

`SleepProtection` 只在状态目录保存 `sleep-declined`（明确选「不允许」）。没有启用标记；每次启动先校验 `/private/etc/sudoers.d/vhostty_sleep`：必须是 root 所有、组和其他用户不可写的普通文件，内容与 Vhostty 的规则一致；再确认 sudo 加载了免密规则，否则弹出询问。不会借用 Amphetamine 的授权文件跳过安装。规则文件为 0444，允许应用只读校验，不含秘密。取消管理员授权或授权失败均不写拒绝标记。菜单允许重新选择。授权或运行失败只把菜单项改为「防合盖睡眠：未生效…」，点击重试，成功后恢复原名；不弹错误框、不发通知。管理员授权把应用内的静态文件 `Resources/vhostty-sleep.sudoers` 复制到固定路径，允许管理员组执行 `/usr/bin/pmset -a disablesleep 1/0` 的规则，经 visudo 校验后原子安装，不授权其他命令。

`vhostty-sleep` 是普通用户进程，按「租约」工作，只在有任务时存在。App 每秒判断一次：有卡片在运行、处于启动中（启动后 2 分钟内，进程未退出），或定时任务在准备阶段，就算有任务。从空闲变为有任务时启动守护程序，它设 `disablesleep 1` 后在 stdout 输出 `active`，然后阻塞读 stdin；全部空闲 15 秒后 App 关闭管道，守护程序读到 EOF 恢复后退出。App 崩溃或强制退出时管道同样关闭；管道写端设为 close-on-exec，终端里的 shell 不会继承它。App 卡死时不释放。空闲期间不执行 pmset，外部设的 1 不会被改。设 1 不受 Amphetamine 影响；恢复为 0 前查询运行中的 Amphetamine，只有 `session is active` 和 `closed display mode enabled` 都为 true 才跳过，查询被拒绝、超时或失败时也恢复为 0。租约开始时 Amphetamine 在运行的话，守护程序每 5 秒检查一次，被改回 0（如 Amphetamine 会话结束）就重新设 1，结果输出 `active` 或 `error`；否则租约期间不碰 pmset。守护程序非零退出或输出 `error` 时菜单显示「未生效…」，下一次有任务时自动再试，成功后恢复。Amphetamine 自动化授权由 App 在启动（或授权成功）时请求，守护程序只查询、不弹授权框。状态目录的 `sleep.lock` 让新的守护程序等前一个恢复完再设置。此机制只覆盖 Vhostty 管理的卡片和任务，不跟踪已脱离卡片的独立后台作业。

`python3 scripts/test-sleep-protection.py` 用真实守护程序、模拟 pmset 和隔离 AppKit 实例验证租约、恢复、Amphetamine 状态组合、首次询问、真实终端状态和启动中超时；加 `--watchdog-only` 只验证守护程序，不打开窗口；加 `--skip-starting` 跳过约 2 分半的启动中超时用例。测试实例默认完全跳过电源功能；同时指定 `VHOSTTY_SUPPORT_DIR`、`VHOSTTY_DEBUG_SNAPSHOT`、`VHOSTTY_SLEEP_TEST_DIR` 才运行模拟电源后端，绝不触发真实提权。debug driver 的 `alertbutton <从 0 开始的索引>` 点击当前模态框按钮；`alert.txt` 和 `alert.png` 输出按钮列表及截图。自动测试不验证物理合盖和真实管理员密码输入。

`python3 scripts/test-sleep-failure-menu.py` 无窗口验证真实控制器与 `NSMenuItem`：授权失败、取消重试、运行失败、菜单重试、下一次有任务时自动重试和停止后恢复。不打开询问框、不执行真实提权或 pmset；菜单错误状态改动优先运行此测试。
