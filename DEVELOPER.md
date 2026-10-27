# Vertty 开发者文档

给想了解实现或参与开发的人看。使用说明见 [README](README.zh-CN.md)。

## 项目名称

项目、Mac 和 iOS 应用统一使用 Vertty：应用标识为 `dev.vertty.Vertty` / `dev.vertty.remote`，数据目录为 `Application Support/Vertty`，环境变量为 `VERTTY_*`，辅助命令为 `vertty-*`，任务链接为 `vertty://`。

## 从源码构建

### macOS

只需要 Command Line Tools、zig 和 Go，**不需要 Xcode**。

```bash
brew install zig go       # zig 需要 0.15.2（Ghostty 1.3.1 的要求）；Go 用来编译内置的 Tailscale
git clone --recursive https://github.com/SunRunAway/vertty.git
cd vertty
make                      # 第一次会先编译 libghostty，大约 5 分钟
make install              # 拷贝到 /Applications/Vertty.app
```

### iOS

iPhone 和 iPad app 需要 Xcode。先运行 `scripts/build-ghostty-ios.sh` 编译终端库、`scripts/build-tailnet.sh` 编译 Tailscale 库（装了 Xcode 时 `make` 也会顺带编好），再打开 `iOS/Vertty.xcodeproj`，在 Signing 里选择你的 team，运行到设备上。

## 工作原理

### Claude 是怎么启动的

每个会话用的命令大致是：

```
$SHELL -l -i -c 'vertty-claude --session-id <uuid>; exec $SHELL -l'
```

- `vertty-claude` 实际执行的是 `claude --settings <Vertty 的 hooks 配置> ...`。这份 hooks 配置会和你自己的 `~/.claude/settings.json` **合并**，你自己的配置不会被改动。
- 会话 ID 由 Vertty 生成，所以它确切知道每张卡片对应哪个 Claude 会话，之后也能 `--resume` 恢复。
- Claude 退出后在同一个 tab 里手动跑 `claude -r <id>` 也会被跟踪：Claude Code 为每个运行中的进程写 `~/.claude/sessions/<pid>.json`，Vertty 从进程环境变量里的 `VERTTY_TAB_ID` 认出它属于哪张卡片，把卡片切到那个会话。这样起的 claude 不带 hooks，状态只能靠终端标题。

### Codex 会话

Codex 每张卡片跑的是 `vertty-codex -c tui.terminal_title=…`（新建）或 `vertty-codex resume -c tui.terminal_title=… <id>`（恢复），它只是调用 `codex`，退出后通过 `vertty-hook` 告诉 App。和 Claude 的不同：

- Codex 不能预先指定会话 ID，进程上也看不出它在跑哪个会话。所以 Vertty 用 `-c` 把卡片里 Codex 的终端标题设成 `["activity","thread-title","thread-id"]`，卡片从自己的终端标题里读 ID：`thread-id` 被截成前 29 个字符加 `...`，一直都在；会话还没起名时，`thread-title` 显示完整 ID。
- Codex 在发出第一条消息时才保存会话，没保存的会话不能 `codex resume`。所以读到的 ID（或前缀）先记在 `codexThreadID`，等 Codex 的会话索引 `~/.codex/state_<n>.sqlite` 的 `threads` 表里有且只有一个会话以它开头，才把那个会话的完整 ID 作为卡片的会话 ID。在 Codex 里用 `/new`、`/resume` 换了会话，标题里的 ID 变了，卡片也跟着换。
- 不注入 Codex hooks（Codex 的 hooks 要用户手动信任）。状态来自终端标题：有转圈就是工作中。启动和恢复时 Codex 也会转一会儿，这一段不算一轮工作。
- 历史会话、标题、分支也来自 `threads` 表（只列用户自己发起的会话，不含子代理、自动化和已归档的）。除了 cwd 是项目目录或现存 worktree 的会话，同一仓库（`git_origin_url` 和项目的 origin 一致）里 worktree 已删除的会话也算：cwd 在 Codex 自己的 worktree 目录 `$CODEX_HOME/worktrees/<id>/<项目目录名>` 下，或者 cwd 已经不存在。项目的子目录算别的项目，不计入。
- Codex 的数据目录是 `CODEX_HOME`（默认 `~/.codex`）。卡片里的 Codex 由交互式登录 shell 启动，所以 Vertty 启动时也用 `$SHELL -l -i -c` 读这个变量。
- 卡片里的 Codex 用 `--no-daemon` 启动：不连 Codex 的共享后台服务（daemon），在自己进程里跑 app server。这样会话是本地的（`/worktree` 等可用），卡片关掉这一轮也就停了。不用 `--remote` 连 Vertty 自己的 server，因为 Codex 把任何显式 `--remote` 都当远程工作区，会关掉 worktree 等本地功能。

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
| 状态 | 终端标题前面的状态符号：`✳` 空闲，其他转圈符号表示工作中。一轮回复结束、但还有后台 shell 命令在跑时（`~/.claude/sessions/<pid>.json` 的 `status` 为 `shell`），卡片也算运行中（退出确认、防睡眠、屏幕常亮都计入），图标转圈；但有未读时仍显示蓝点。hooks 补充：`Notification` → 等你确认，`SessionEnd` → 已退出 |
| 系统通知 | Claude Code 自己发出的终端通知（OSC 9/777），由 Vertty 转成 macOS 通知 |
| 分支 | 会话自身记录的分支：Claude transcript 的 `gitBranch`，Codex `threads` 的 `git_branch`。不读取共享工作目录的当前 HEAD，避免其他会话切分支覆盖旧卡片 |
| worktree | 对会话 cwd 执行 `git rev-parse`，并结合 Claude 的 `worktree-state` |
| PR | 用 `gh pr view <branch>` 查会话记录的功能分支对应的 PR（查不到则留空）；会话回到 main/master 等非功能分支后，用其记录里的 `pr-link` |

hooks 事件的传递路径：`vertty-hook`（App 里自带的一个小程序）通过 Unix socket，把事件转发给 App。

### 定时任务

产品规则见 [docs/spec/schedule-product.md](docs/spec/schedule-product.md)。任务和运行记录存在状态目录的 `schedules.json`。

`python3 scripts/test-schedule-state.py` 验证冬夏令时和旧任务兼容；`scripts/test-schedule-api.py` 验证 CLI/MCP；`scripts/test-schedule-timezones.py` 在隔离窗口点击、搜索时区并验证保存、取消和日期时间保持不变。后两者先运行 `make app`，均不启动真实 agent 会话。

- **计划**：每个任务记着下一次还没处理的计划时间 `nextPlan`。每 20 秒、启动和唤醒时检查一次：到点的计划里只运行最近一次，更早的直接丢掉；先把新的 `nextPlan` 写盘再启动，所以重复检查、唤醒或重启都不会重复提交。任务可指定 IANA 地区时区（如 `America/New_York`），默认跟随本机系统时区；系统时区变了只重算跟随本机的任务 `nextPlan`（`Calendar.nextDate`，夏令时跳过的时刻顺延，重复的时刻只取第一次）。
- **执行**：提示词作为 agent 的命令行参数传入（`claude --session-id/--resume <id> <提示词>`、`codex [resume <id>] <提示词>`），从不往终端里打字。首次运行在项目顶部新建一张后台卡片；之后 resume 任务绑定的会话 ID。这个会话开在某张卡片里时，先释放那张卡片的终端，等它的 agent 进程（Claude 看 `~/.claude/sessions`，外加带这张卡片 `VERTTY_TAB_ID` 的 `claude`、`vertty-hook` 进程；Codex 看带 `tui.terminal_title` 参数的 TUI 进程）都退出后，再在同一张卡片里 resume。确认不了已停止就记异常，不启动第二个实例；卡片的终端已经没了也照样先查一遍进程。停止期间选中这张卡片不会重新拉起它。Claude 会话如果在 Vertty 之外（别的终端、底部终端、后台任务）还有进程，不碰它，直接记异常，因为再 resume 会让会话分叉。
- **状态**：Claude 靠 hooks：`UserPromptSubmit` 表示已提交，`Stop` 表示已完成，没有 `Stop` 就空闲下来算中断。Codex 没有 hooks，查 `thread_history_<n>.sqlite`：本轮的 `userMessage` 出现表示已提交，同一轮有 `phase` 为 `final_answer` 的 `agentMessage` 表示已回复。App 重启时还在运行的记录记为异常。
- **对话里管理**：`vertty-schedule mcp`（`$VERTTY_SCHEDULE_CLI`）是一个 stdio MCP server，把各项操作做成工具，使用说明写在工具描述和 server 的 instructions 里。`vertty-claude` 用 `--mcp-config`、`vertty-codex` 用 `-c mcp_servers.vertty…` 把它挂到这张卡片的会话上，不写 agent 的配置文件。Claude 不用 skill：长对话压缩后 Claude Code 不会重发 skill 列表，agent 就不知道有这个 skill 了，而 MCP 的 instructions 和工具名会重发。`vertty-schedule` 通过 hook socket 发 `schedule\n<JSON>` 请求并读回 JSON。接口查询、创建、编辑、删除、暂停、恢复、结束和立即运行均直接执行；手动结束记在任务的 `endedAt`，此后不再安排计划，修改执行计划时清除；创建、编辑、删除成功后返回已保存的 `task` 和 `url`（`vertty://schedule/<UUID>`），agent 可以回复链接，用户点击后打开对应任务侧栏，删除后的任务也能查看。终端内的 `vertty://` 文本和 OSC 8 链接由 Ghostty 识别，按 ⌘ 点击会在当前实例打开任务侧栏，停留在当前会话，不切到定时任务页。Claude Code 全屏模式等捕获鼠标的 TUI 下，Ghostty 原本只在按住 Shift 时才处理链接；补丁里让 `vertty://` 链接在这时也由终端处理，按不按 ⌘ 都行，跟 Claude Code 点 http(s) 链接一样，这次点击不再发给 TUI。其他链接和文件路径的点击仍交给 TUI（Claude Code 自己打开 http(s) 链接和文件路径，但不认 `vertty://`）。请求不会自动打开界面，也不要求人工确认；保存失败返回错误。请求里多出的字段会被拒绝。MCP server 不在 Claude Code 的 Bash 沙箱里运行，不需要给 socket 开例外。
- **显示器休眠**：显示器全部休眠时没有可用的显示器，libghostty 原本会因为建不了 CVDisplayLink 而创建终端失败；补丁里改成这时不用 display link，靠内容变化驱动绘制，这样定时任务在显示器关着时也能启动。

### 远程控制

产品规则见 [docs/spec/remote-client-product.md](docs/spec/remote-client-product.md)。

`VERTTY_REMOTE_PORT` 设置「远程连接」选「自行组网」时的监听端口，默认 `58563`。在登录 shell 的配置文件（如 `~/.zshrc`）中设置后重启 Vertty；端口无效或无法使用时，「远程连接」子菜单里会显示「启动失败」及原因。

- **协议**：一条 WebSocket，消息是 `VerttyKit/Proto/vertty_remote.proto` 定义的 Protobuf（每帧一条，客户端发 `ClientMessage`，服务端发 `ServerMessage`）。改了 proto 后运行 `scripts/gen-proto.sh` 重新生成 Swift 代码（protoc 和 protoc-gen-swift 编译到 `build/tools`）。协议代码和客户端 `RemoteClient`（连接、重连、请求、终端流）在 `VerttyKit` 包的 `VerttyRemote` 里。
- **服务端**：`Sources/Vertty/Remote/RemoteServer.swift` 用 Network.framework 监听，同时只留一个客户端，新连接接管旧连接；握手带 `Origin` 头的一律拒绝（浏览器必带、网页去不掉，自家客户端不带），免得网页经 `127.0.0.1` 连进来；`RemoteBridge.swift` 把 `AppStore` 的项目、卡片和历史做成 State（有变化才发），执行新建、恢复、关闭等请求，并把卡片终端转给客户端。
- **Tailscale**：内置的 Tailscale 设备是 Go 写的 `VerttyKit/Tailnet`（基于 Tailscale 官方的 `tsnet`，用户态网络，不需要系统 VPN），`scripts/build-tailnet.sh` 把它编成静态库 `VerttyKit/CTailnet.xcframework`（不进仓库；源码没变时跳过；Mac 那份总会编，装了 Xcode 时再编 iPhone 和模拟器两份），Swift 这边是 `VerttyKit` 的 `VerttyTailnet`（`Tailnet.shared`）。电脑选「通过 Tailscale」时，远程服务只监听 `127.0.0.1` 的随机端口，Go 在 Tailscale 上监听 58563，确认对方设备属于同一用户后转过去。客户端每次连接先经 Tailscale 拨通电脑，再连 Go 在 `127.0.0.1` 上开的一次性端口，协议和自行组网完全一样（`RemoteEndpoint` 负责每次连接前找到地址）。登录页用系统的 `ASWebAuthenticationSession` 打开（`VerttyUI` 的 `TailscaleSignIn`）；Tailscale 登录完不会跳回 App，所以看到设备变成已登录就主动关掉窗口。设备名是「电脑名-vertty」，客户端据此和系统类型找出 Vertty 电脑；登录状态在状态目录的 `tailscale/` 下。Tailscale 自带的 peer API 在 Mac 上默认还会在所有网卡上开一个端口，`tailnet.go` 用 `go:linkname` 挂了 ipnlocal 的钩子让它只在 Tailscale 里提供；升级 tailscale.com 后如果这个内部变量改了名，会直接编译失败。不上传 Tailscale 的日志。客户端拨号前要等电脑出现在设备列表里并且在线（`Tailnet.waitForComputer`）：Tailscale 只能连它列出的设备，而它启动时会先用磁盘上缓存的网络图报已运行，缓存里可能一台其他设备都没有，几秒后服务器的列表才到；这时直接拨号会立刻得到一条收不到数据的连接。等不到只算这次连不上，不判定电脑已不在。客户端每次经 Tailscale 找电脑、拨号的结果，以及设备状态和设备数的变化，iPhone app 会写进 `RemoteLog`（见下面“尺寸”里取回 `remote-size.log` 的方法）。`TS_AUTHKEY="$(cat <key>)" python3 scripts/test-remote-tailscale.py`（Mac 客户端）和 `scripts/test-remote-ios-tailscale.py`（iOS 模拟器）用测试专用的 auth key（可复用、临时设备、不带 tag）跑真实的 Tailscale 连接。
- **终端镜像**：补丁给 Ghostty 加了 tap（`src/termio/remote.zig`）：打开时发一份快照（把屏幕、滚动历史和终端模式重新写成 VT 序列；在 IO 线程上处理完之前排队的尺寸变化再拍，所以客户端带着自己的尺寸打开时只收到一份），之后转发程序的原始输出，网格尺寸变了就重发快照。客户端的终端用补丁里的 host-managed 后端（`src/termio/HostManaged.zig`，改自 libghostty-spm）：没有 pty，输出由 `ghostty_surface_write_buffer` 喂进去，键盘、粘贴产生的字节通过回调交给客户端发回去，终端对查询的应答一律丢掉，由电脑上的真终端回答。
- **尺寸**：会话的网格跟随最后一个进入、调整视口、点击或滚动、输入的一端。服务端用 `ghostty_surface_set_grid_override` 只改行列、不改窗口；客户端每次键盘输入或粘贴之前先发 `AlignForInput`，在窗口或屏幕上点击、触摸、滚动时尺寸不同就发 `TerminalViewport`；本机输入、在显示该会话的主窗口里点击或滚动（`AppDelegate.watchInteraction`）也会先恢复本机尺寸。iOS app 只在从后台回来时重发尺寸：锁屏时系统会在进后台前短暂切回 active 一下，这一下不算回到前台。两端都把尺寸变化的原因写进系统日志（subsystem `dev.vertty`，category `remote-size`，`RemoteLog`），iPhone app 另外写到容器里的 `Documents/remote-size.log`，可用 `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier dev.vertty.remote --source Documents/remote-size.log` 取回。Ghostty 的 IO 线程会把连续的 resize 合并 25ms，补丁在每次写入前先应用还没处理的 resize（`Thread.zig` 的 `flushResize`），保证输入按新尺寸到达程序。
- **iOS 粘贴按钮**：App 启动时创建并持有同一个 `UIPasteControl`，快捷键栏挂到窗口时接入它并更新粘贴目标；每个栏用独立占位视图维持布局，未显示的栏不会抢走按钮。这样复用已经渲染的控件，可避开系统渲染服务退出后新控件变空白的问题。`Documents/paste-control.jsonl` 只记录启动、按钮挂载/移除、前后台和粘贴结果；附按钮身份、尺寸、归属、目标及直接子视图是否有图像，不读取剪贴板或输入正文。没有定时采样或递归视图/图层扫描。日志跨重启追加，每份 2 MiB，保留当前和 `.1`、`.2`、`.3` 三份旧文件（最多 8 MiB）；卸载会删除容器。取回命令：`xcrun devicectl device copy from --device <设备ID> --domain-type appDataContainer --domain-identifier dev.vertty.remote --source Documents/paste-control.jsonl --destination /tmp/paste-control.jsonl`。`INPUT_ONLY=1 PASTE_DIAGNOSTICS=1 python3 scripts/test-remote-ios.py` 验证导航复用、目标更新、空闲不写日志及日志持久化；脚本里的 `key paste` 直接测试粘贴处理函数，不代表原生按钮点击。
- **界面共享**：Mac 本机、Mac 远程窗口、iPhone、iPad 用同一份界面代码，在 `VerttyKit` 包的 `VerttyUI` 里：侧栏 `SidebarView`、卡片 `SessionCard`、窗口布局 `Workspace`（侧栏、拖动改宽度、标题条）和模型类型。侧栏读写的是 `SidebarStore` 协议：本机是 `AppStore`，远程是 `RemoteStore`（选中卡片就打开它的终端，取消选中就离开）。远程端没有的功能（管理项目、拖动排序、定时任务、本机文件操作、关闭其他）由 `SidebarFeatures` 关掉，界面上直接不显示。远程界面是 `RemoteWorkspace`：Mac 和 iPad 侧栏加终端并排，iPhone（compact 宽度，或宽度不到 700pt，比如展开后竖着拿的 iPhone Duo）侧栏占满一屏、点卡片推入终端。各端单独写的只有终端（两边是同一份打了补丁的 Ghostty，Mac 用 AppKit 的终端视图，iOS 用 libghostty-spm 的 UIKit 终端视图）、键盘和触屏适配：右键菜单在触屏上是长按，悬停才出现的按钮在触屏上放进长按菜单（项目行的搜索和每个启用 agent 的新会话按钮除外：触屏上常驻）；共享视图里的字号、间距和行高都经过 `Touch`（`Controls.swift`），macOS 上就是原值，iOS 上按比例放大、可点的行至少 44pt。界面文字的中文在 `VerttyKit/Sources/VerttyUI/Resources`，Mac app 只放自己独有的文字。改界面先改共享代码，不要给某一端另写一份。
- **iPhone / iPad**：`iOS/Vertty.xcodeproj`，要用 Xcode 编译。终端库和 Mac 是同一份 Ghostty（`vendor/ghostty` 加补丁）：先运行 `scripts/build-ghostty-ios.sh`（要 Xcode 和 zig，几分钟），它编出真机和 Apple 芯片模拟器两份，合成 `iOS/GhosttyTerminal/GhosttyKit.xcframework`（不进仓库）；改了补丁要重新运行。终端视图取自 libghostty-spm 的 UIKit 部分，源码放在 `iOS/GhosttyTerminal`，Vertty 的改动记在其中的 `VERTTY.md`。会话尺寸比屏幕大时，把终端视图按会话的网格布局再整体缩小显示。iPhone Duo 半开、竖着拿（折痕横在屏幕中间）时，`UIHingeInteraction` 报半开，终端只占折痕以上，按键栏仍贴着键盘，并自动弹出键盘。

## 为了不装 Xcode 做的处理

Ghostty 官方的 macOS 构建依赖 Xcode。为了只用 Command Line Tools 就能编译，`patches/ghostty-vertty.patch` 对 Ghostty 做了这些改动：

1. **Metal 着色器改成运行时编译**（`newLibraryWithSource`）。这样就不需要 Xcode 自带的 `metal` 编译器。
2. **在 macOS 上额外输出静态库 `libghostty.a` 和资源文件**。官方构建只产出 xcframework。
3. **修复打包问题**：新版 `libtool` 会静默丢弃 zig 打包时没有 8 字节对齐的目标文件，改成先解包再重新打包。

补丁里还有与 Xcode 无关的改动：显示器全部休眠时，终端不用 CVDisplayLink 也能创建（见上文“定时任务”）；远程控制用到的终端镜像、host-managed 后端和网格覆盖（见上文“远程控制”）；iOS 构建需要的改动：iOS 上不装 `libghostty-vt` 动态库，来自 libghostty-spm 的 iOS 渲染修正（IOSurface 图层、同步呈现、CoreText 不起释放线程、IOSurface 行宽按 64 字节对齐），libxev 升到 7e7d2f2（旧版在 iOS 上 kqueue 的 mach port 会让 IO 线程崩溃），以及 iOS 终端视图用的选区位置查询 `ghostty_surface_selection_viewport`。

`scripts/build-ghostty.sh` 编译前把补丁打到 `vendor/ghostty` 的工作区里，之后一直留着。`.gitmodules` 设了 `ignore = dirty`，所以主仓库的 `git status` 不显示这些改动；要看补丁是否打上，用 `git -C vendor/ghostty status`。

另外还有两个绕路：

- `scripts/make-zig-sdk.sh`：macOS 26 以后的 SDK 里，库描述文件只写了 arm64e 架构，zig 0.15 识别不了。这个脚本用 APFS 克隆一份 SDK（几乎不占空间），补上 arm64。
- `scripts/bundle.sh`：用 macOS 26 SDK 编译 Swift。因为 macOS 27 SDK 把 SwiftUI 的 `@State` 改成了宏，而宏插件只随 Xcode 提供。

## 开发调试

```bash
VERTTY_SUPPORT_DIR=/tmp/vertty-test \
VERTTY_DEBUG_SNAPSHOT=/tmp/vertty-snap \
build/Vertty.app/Contents/MacOS/Vertty
```

这样直接运行会把 App 带到前台。测试（包括自动测试）一律用 `scripts/testapp.py` 的 `launch()` 启动：它让 App 在后台启动，不抢前台、不挡住正在用的窗口，窗口截图照常能拿到；按它返回的 pid 停止。

- `VERTTY_SUPPORT_DIR`：使用一份独立的状态目录，不影响正式数据。
- `VERTTY_DEBUG_SNAPSHOT`：每 1.5 秒把窗口截图和状态写到这个目录（`window.png`、`state.txt`）。往 `input.txt` 写命令可以驱动 App，一行一条：

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
| `click <x> <y>` / `cmdclick <x> <y>` | 点击 / 按 ⌘ 点击测试窗口内的位置，坐标单位为点，原点在内容区域左上角 |
| `windowclick <窗口编号> <x> <y>` / `windowtext <窗口编号> <文字>` | 操作测试实例的浮层；编号和尺寸在 `state.txt`，截图为 `window-<编号>.png`；文字仅写入已聚焦的原生文本框 |
| `postclick <x> <y>` / `postscroll <x> <y>` | 把一次点击 / 滚动放进 App 的事件队列，像真实输入一样经 AppKit 分发；坐标同 `click` |
| `focus claude` / `focus shell` | 聚焦上面 / 下面的终端 |
| `menukey <ctrl\|cmd> <字符>` | 把快捷键直接交给主菜单处理 |
| `post <ctrl\|cmd\|none> <字符>` | 模拟一次真实按键，走 AppKit 正常的分发流程 |
| `openurl <URL>` | 通过 App 的 URL 入口打开任务链接 |
| `schedules` / `schedule <任务 UUID>` | 打开定时任务列表 / 某个任务的侧栏 |
| `runschedule <任务 UUID>` / `tickschedules` | 立即运行一个任务 / 立即检查到点的计划 |
| `newschedule` / `closepanel` | 打开新建任务侧栏 / 关闭侧栏 |
| `panelsave` / `panelcancel` | 保存 / 撤销侧栏里的改动（等于点“保存”/“取消”） |
| `cmdj-through-terminal` | 检查 ⌘J 是被终端吃掉还是交给了菜单，结果写到 `keyequiv.txt` |
| `remote <地址>` | 打开远程窗口连接这个地址 |
| `remoteopen <n>` / `remotenew` | 远程窗口打开第 n 张卡片 / 新建会话 |
| `remotepostclick <x> <y>` / `remotepostscroll <x> <y>` | 同 `postclick` / `postscroll`，作用于远程窗口 |
| `remotetext …` / `remoteenter` | 往远程窗口的终端输入文字 / 回车 |
| `remotemode tailscale` / `remotemode direct` | 点 Vertty 菜单“远程连接”子菜单里的“通过 Tailscale” / “自行组网”，打开或关闭这一项 |
| `remotetailnet <名称>` | 打开远程窗口，连接 Tailscale 上这个名称（DNS 名的第一段）的电脑；列表里还没有它时不做任何事 |
| `tailnetlogout` | 退出 Tailscale 登录 |

按键和文字只会发给用 `to` / `toshell` 明确指定的会话。截图时如果有确认框（sheet）打开，另存为 `sheet.png`；`state.txt` 末尾列出定时任务及其运行记录。

`make app` 后运行 `python3 scripts/test-codex-history.py`，可在临时状态目录和数据库里验证 Codex 历史在最后一个数据库写连接关闭、数据库暂时被锁、恢复和真正清空时的行为；测试不会启动终端会话，并按 PID 停止自己的 App 实例。

远程控制有三个测试，都在临时状态目录里启动自己的实例和模拟 agent（记录收到输入时的终端尺寸），按 PID 停止：`scripts/test-remote.py` 用 `remote-probe`（`cd VerttyKit && swift build --product remote-probe`，按行读命令的测试客户端）验证协议和服务端；`scripts/test-remote-mac.py` 用两个实例验证 Mac 上的远程窗口；`scripts/test-remote-ios.py` 在 iOS 模拟器里验证 iOS app（`SIM_DEVICE` 选模拟器，默认 iPhone 17，填 iPad 就测并排布局），编译命令写在脚本开头，app 以 `VERTTY_DEBUG=1` 启动时从容器的 `Documents/debug/input.txt` 读命令、把状态写到 `state.txt`。

`python3 scripts/test-session-branches.py` 用临时 HOME、仓库、会话记录及模拟的 agent/gh，验证共享工作区切分支不会覆盖其他会话的分支和 PR，同时检查会话自身换分支、回到 master 时的 PR 更新。测试按 PID 停止自己的 App 实例。

## 发布

推一个 `v` 开头的标签，GitHub Actions（`.github/workflows/release.yml`）就会在 macOS arm64 机器上编译，把 `Vertty.zip` 发到同名的 Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

版本号使用稳定的 `major.minor.patch` 标签，同时写进 `CFBundleShortVersionString` 和 `CFBundleVersion`；本地构建使用最近的发布标签，也可用 `VERTTY_VERSION` 指定。libghostty 按 Ghostty 版本和补丁缓存，补丁不变时不会重新编译。在 Actions 页面手动运行这个 workflow 只编译、上传构建产物，不发 Release。用户通过 Homebrew 或 `scripts/install.sh` 首次安装。

### macOS 应用内更新

Sparkle 默认自动检查、后台下载并验证更新，在用户正常退出时安装，不会为了更新主动退出应用。标准更新窗口里的自动下载安装复选框默认勾选，用户可以取消；已保存的用户选择优先于默认值。菜单也可手动检查或关闭自动检查。手动选择安装并重启时，仍走现有的退出确认，正在工作的 agent 会触发提示，取消退出就推迟安装。升级后的会话恢复沿用普通重启行为。

更新清单为 `https://github.com/SunRunAway/vertty/releases/latest/download/appcast.xml`，ZIP 下载地址固定到具体 Release。CI 用 Sparkle 的 `generate_appcast` 签署 ZIP 和清单，再与 ZIP 一起发布。`SUPublicEDKey` 是应用内的验证公钥；对应私钥保存在 macOS Keychain 的 `dev.vertty.Vertty` account，并作为仓库 Actions secret `SPARKLE_PRIVATE_KEY` 提供给发布步骤。不要把私钥提交到 Git。必须保留这把密钥，当前未使用 Developer ID 签名，丢失私钥后不能直接给已安装用户换公钥。

首次发布更新器之前，v0.7.1 的 Release 附带已签名的空清单，让本地构建可以正常检查更新。Homebrew tap 的同步脚本只在清单包含当前 ZIP 的更新条目时写入 `auto_updates true`，不会提前把不含更新器的旧版标成自更新应用。

打包保留 Sparkle 框架和辅助程序原有的签名，只对 Vertty 的可执行文件和外层应用做 ad-hoc 签名。Brew 的 `postflight_steps` 仍用于首次安装和 Brew 升级；Sparkle 安装器自己处理新应用的 quarantine，不调用 Brew。旧版需要先通过 Brew 或手动安装一次包含更新器的版本。

普通 debug driver 测试不启动更新器。`scripts/test-updates.py` 使用临时应用标识、状态目录、密钥和本机 feed，并通过 `VERTTY_TEST_UPDATES=1` 显式开启，验证签名拒绝、替换与重启，不连接正式更新源。

## 文档

README 有英文（`README.md`）和中文（`README.zh-CN.md`）两份，改功能、快捷键或构建步骤时两份要一起改。

README 的截图（`docs/screenshot.png`）用 `python3 scripts/readme-screenshot.py` 重新生成（先 `make app`，在沙箱外运行）。脚本在 `/private/tmp/vertty-readme-demo` 新建两个演示项目（starboard、小账本，带 worktree），用临时状态目录和 debug driver 启动 `build/Vertty.app`，起两个真实的 Claude 会话：一个回答简短问题后在后台完成（蓝点），另一个是刚打开、还没发过消息的新会话，等它的输入框出来后截图；其余卡片是 state.json 里未启动的卡片（分支、worktree、PR 都写好了）。窗口大小靠命令行参数传入，结束后把已安装版本保存的窗口位置还原；运行前后都会删掉演示项目在 `~/.claude/projects` 下的会话记录，免得出现在历史里。演示目录首次运行时脚本会替 Claude 确认信任该文件夹。

## 多语言

界面文字在代码里写英文（`String(localized:)`，以及 SwiftUI 的 `Text` / `Button` 等字面量），简体中文翻译在 `Resources/zh-Hans.lproj/Localizable.strings`，英文的单复数在 `Resources/en.lproj/Localizable.stringsdict`。App 跟随系统语言；想单独切换，可以在「系统设置 → 通用 → 语言与地区 → 应用程序」里给 Vertty 指定语言，或者：

```bash
defaults write dev.vertty.Vertty AppleLanguages '("en")'   # 恢复：defaults delete dev.vertty.Vertty AppleLanguages
```

新增文字时记得同时在 `zh-Hans.lproj` 里加一条翻译，key 就是英文原文（插值写成 `%@` / `%lld`）。

### 防合盖睡眠

`SleepProtection` 在状态目录保存两个标记：`sleep-asked` 表示用户已经做过决定（选了「不允许」，或成功授权过一次），之后启动不再询问；`sleep-off` 表示从菜单关掉了。每次启动检查 `/private/etc/sudoers.d/vertty_sleep` 存在且内容与 Vertty 的规则一致：已授权就开启（除非 `sleep-off`）；未授权且没有 `sleep-asked` 才弹出询问。不会借用 Amphetamine 的授权文件跳过安装。规则文件为 0444，允许应用只读校验，不含秘密。取消管理员授权或授权失败不写任何标记。菜单项是开关：开启时显示打勾的「任务运行时防合盖睡眠」，点击关闭并写入 `sleep-off`；已授权但关闭时不打勾，点击直接开启；未授权时显示「任务运行时防合盖睡眠：未授权…」，点击弹出询问。出错不另设状态，不弹错误框、不发通知。管理员授权把应用内的静态文件 `Resources/vertty-sleep.sudoers` 复制到固定路径，允许管理员组执行 `/usr/bin/pmset -a disablesleep 1/0` 的规则，经 visudo 校验后原子安装，不授权其他命令。

`vertty-sleep` 是普通用户进程，按「租约」工作，只在任务保护或持续保护需要它时存在。App 每秒判断一次：有卡片在工作中且进程未退出，就算有任务。任务保护开启且有任务，或持续保护开启时，启动同一个守护程序，它设 `disablesleep 1` 后在 stdout 输出 `active`，然后阻塞读 stdin；两种保护都不再需要时 App 立即关闭管道，守护程序读到 EOF 恢复后退出。App 崩溃或强制退出时管道同样关闭；管道写端设为 close-on-exec，终端里的 shell 不会继承它。App 卡死时不释放。没有保护租约时不执行 pmset，外部设的 1 不会被改。设 1 不受 Amphetamine 影响；恢复为 0 前查询运行中的 Amphetamine，只有 `session is active` 和 `closed display mode enabled` 都为 true 才跳过，查询被拒绝、超时或失败时也恢复为 0。租约期间守护程序每 5 秒检查一次，被改回 0（如 Amphetamine 启动、退出或结束会话时）就重新设 1，结果输出 `active` 或 `error`。守护程序非零退出或输出 `error` 时，App 重新校验授权，规则失效就显示为未授权。Amphetamine 自动化授权由 App 在启动（或授权成功）时请求，守护程序只查询、不弹授权框。任务运行状态只覆盖 Vertty 管理的卡片和任务，不跟踪已脱离卡片的独立后台作业。

「持续防合盖睡眠」子菜单提供关闭、15 分钟、30 分钟、1 小时、2 小时、3 小时、6 小时、12 小时、24 小时和无限期。选择后立即生效，不依赖任务；定时项从选择（需要授权时从授权成功）开始计时，菜单标题按小时:分钟显示剩余时间（不足一分钟向上取整），无限期显示 ♾️，关闭时去掉后缀。沿用已有的每秒任务/到期检查，只在分钟数或模式变化时更新标题，不增加刷新定时器；子菜单显示截止时间，再次选择会重新计时。持续保护与任务保护独立，共用一份授权和一条租约：任意一方仍需要保护就不释放，定时到期不影响运行中的任务保护。两种模式都沿用同一守护程序的 Amphetamine 检查。持续保护只在本次应用运行期间有效，退出或崩溃时释放，重启不恢复；快速关闭再开启时等待旧守护程序恢复并退出后才启动新的，避免旧恢复覆盖新保护。

`python3 scripts/test-sleep-protection.py` 用真实守护程序、模拟 pmset 和隔离 AppKit 实例验证租约、恢复、Amphetamine 状态组合、首次询问和真实终端状态；加 `--watchdog-only` 只验证守护程序，不打开窗口。测试实例默认完全跳过电源功能；同时指定 `VERTTY_SUPPORT_DIR`、`VERTTY_DEBUG_SNAPSHOT`、`VERTTY_SLEEP_TEST_DIR` 才运行模拟电源后端，绝不触发真实提权。debug driver 的 `alertbutton <从 0 开始的索引>` 点击当前模态框按钮；`alert.txt` 和 `alert.png` 输出按钮列表及截图。自动测试不验证物理合盖和真实管理员密码输入。

`python3 scripts/test-sleep-failure-menu.py` 无窗口验证真实控制器与 `NSMenuItem`：授权失败、取消、授权成功后的打勾状态，以及运行出错时授权仍在则保持、授权失效则显示为未授权。不打开询问框、不执行真实提权或 pmset。

`python3 scripts/test-continuous-sleep.py` 无窗口验证真实子菜单操作、全部时长、定时到期、两种保护交接、快速重开、独立授权、退出恢复和 Amphetamine 兼容；只操作隔离目录中的模拟电源状态。

### 任务运行时不允许屏幕关闭

`DisplayAwake` 独立于防合盖睡眠。状态目录有 `display-awake` 标记时开启（菜单项打勾）；开启后 App 每秒判断一次，有卡片在工作中就持有一个 `PreventUserIdleDisplaySleep` 电源断言（同 `caffeinate -d`），全部空闲时立即释放，退出时也释放。不需要授权，不碰 pmset。`python3 scripts/test-display-awake.py` 无窗口验证开关、任务开始持有断言、空闲和关闭时释放。
