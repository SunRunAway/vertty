import Foundation

// Agent schedule management over the running app's hook socket.
// CLI and MCP mutations take effect immediately and return a task link.

let usage = """
usage: vertty-schedule <command> [options]

  list                      tasks
  show <task-id>            one task with its recent runs
  create [fields]           create and enable a task
  edit <task-id> [fields]   apply these changes to the task
  pause|resume|run <task-id>
                            done at once ("run" = run now)
  delete <task-id>          delete the task (keep its history)
  mcp                       serve these as MCP tools on stdin/stdout

fields:
  --name TEXT
  --prompt TEXT | --prompt-file PATH ("-" reads stdin)
  --repeat once|daily|weekdays|weekly
  --days mon,tue,…          for weekly
  --date YYYY-MM-DD         for once
  --time HH:MM              24-hour, this Mac's time
  --project PATH|NAME       default: the project of this session
  --agent claude|codex      default: this session's agent

create, edit and delete take effect immediately and return a vertty://schedule/<id> URL.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

struct SendError: Error { let message: String }

/// One request to the running Vertty; its JSON reply.
func send(_ op: String, taskID: String? = nil, fields: [String: Any] = [:]) -> Result<Data, SendError> {
    let env = ProcessInfo.processInfo.environment
    var request: [String: Any] = ["op": op, "cwd": FileManager.default.currentDirectoryPath]
    if let tab = env["VERTTY_TAB_ID"] { request["tabID"] = tab }
    if let taskID { request["taskID"] = taskID }
    if !fields.isEmpty { request["fields"] = fields }

    // The socket of the Vertty that started this session, else the default one.
    let sockPath = env["VERTTY_SOCK"] ?? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let p = support.appendingPathComponent("Vertty/hook.sock").path
        return p.utf8.count < 100 ? p : "/tmp/vertty-\(getuid()).sock"
    }()

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(SendError(message: "Can't open a socket.")) }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(sockPath.utf8)
    let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
        guard pathBytes.count < buf.count else { return false }
        buf.copyBytes(from: pathBytes)
        buf[pathBytes.count] = 0
        return true
    }
    guard fits else { return .failure(SendError(message: "Socket path too long.")) }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return .failure(SendError(message: "Vertty isn't running (no socket at \(sockPath)).")) }
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var payload = Data("schedule\n".utf8)
    payload.append(try! JSONSerialization.data(withJSONObject: request))
    payload.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
    shutdown(fd, SHUT_WR)

    var reply = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        reply.append(buf, count: n)
    }
    guard !reply.isEmpty else { return .failure(SendError(message: "No answer from Vertty.")) }
    return .success(reply)
}

func replyOK(_ reply: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["ok"] as? Bool ?? false
}

// MARK: - MCP

let mcpInstructions = """
Vertty (the terminal app this session runs in) can run a prompt on a schedule: once, daily, on weekdays, or on \
chosen days of the week, at a time on this Mac's clock. A task's first run starts a new session in its project; \
later runs resume that same session. Runs happen only while Vertty is running and the Mac is awake. Use these \
tools for any such request ("every Saturday at 9 check dependencies", "move the dependency check to Sunday", \
"pause that task", "what's scheduled?") instead of cron, cron tools, launchd, /loop or cloud tasks.
Create, edit, delete, pause, resume and run take effect immediately without a Vertty confirmation dialog. \
Create, edit and delete return the saved task and its url. You may include that URL as a Markdown link in your reply \
so the user can open the task's sidebar in Vertty. Deleted tasks remain accessible through their links. \
Only report success when the tool returns ok=true; report errors honestly.
If the time, day or target task is unclear, ask; don't guess. If several tasks could match, ask which. Write the \
prompt so it stands alone: the task runs later in a fresh session that hasn't seen this conversation, so include \
the context it needs (files, goals, what to report). This conversation isn't the task's session.
"""

let taskFields: [String: Any] = [
    "name": ["type": "string", "description": "A short name for the task."],
    "prompt": ["type": "string", "description": "What to run. It must stand alone: the task runs in a fresh session that hasn't seen this conversation."],
    "repeat": ["type": "string", "enum": ["once", "daily", "weekdays", "weekly"]],
    "time": ["type": "string", "description": "HH:MM, 24-hour, this Mac's time."],
    "days": ["type": "string", "description": "For weekly: any of mon,tue,wed,thu,fri,sat,sun, comma-separated."],
    "date": ["type": "string", "description": "For once: YYYY-MM-DD, in the future."],
    "project": ["type": "string", "description": "Project path or name. Default: this session's project."],
    "agent": ["type": "string", "enum": ["claude", "codex"], "description": "Default: this session's agent. Fixed once the task has run."],
]
let taskIDField: [String: Any] = ["task_id": ["type": "string", "description": "The task's id, from list_scheduled_tasks."]]

func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
}

let tools: [[String: Any]] = [
    tool("list_scheduled_tasks", "List Vertty's scheduled tasks with their ids. Use it first when a request refers to an existing task.", [:], []),
    tool("show_scheduled_task", "Show one scheduled task and its recent runs.", taskIDField, ["task_id"]),
    tool("create_scheduled_task",
         "Create and enable a scheduled task immediately. Returns the saved task and its URL; you may share the link with the user.",
         taskFields, ["name", "prompt", "repeat", "time"]),
    tool("edit_scheduled_task",
         "Apply changes to a scheduled task immediately. Give only what changes. Returns the saved task and its URL; you may share the link with the user.",
         taskFields.merging(taskIDField) { a, _ in a }, ["task_id"]),
    tool("pause_scheduled_task", "Pause a scheduled task (at once). A run going on isn't stopped.", taskIDField, ["task_id"]),
    tool("resume_scheduled_task", "Resume a paused scheduled task (at once), from now on.", taskIDField, ["task_id"]),
    tool("run_scheduled_task", "Run a scheduled task once now (at once); its schedule stays as it is.", taskIDField, ["task_id"]),
    tool("delete_scheduled_task", "Delete a scheduled task immediately, keeping its history and current run. Returns the deleted task and its URL; you may share the link with the user.", taskIDField, ["task_id"]),
]

func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
    let ops = ["list_scheduled_tasks": "list", "show_scheduled_task": "show", "create_scheduled_task": "create",
               "edit_scheduled_task": "edit", "pause_scheduled_task": "pause", "resume_scheduled_task": "resume",
               "run_scheduled_task": "run", "delete_scheduled_task": "delete"]
    guard let op = ops[name] else {
        return ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
    }
    var fields = arguments
    let taskID = fields.removeValue(forKey: "task_id") as? String
    switch send(op, taskID: taskID, fields: fields) {
    case .success(let reply):
        return ["content": [["type": "text", "text": String(decoding: reply, as: UTF8.self)]], "isError": !replyOK(reply)]
    case .failure(let e):
        return ["content": [["type": "text", "text": e.message]], "isError": true]
    }
}

/// MCP over stdio: one JSON-RPC message per line.
func serveMCP() -> Never {
    func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
    while let line = readLine(strippingNewline: true) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let id = message["id"] else { continue }  // notifications need no answer
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch message["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "vertty", "version": "1"],
                      "instructions": mcpInstructions]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            result = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            continue
        }
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }
    exit(0)
}

// MARK: - Command line

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(args.isEmpty ? 2 : 0)
}
args.removeFirst()

var taskID: String?
switch command {
case "mcp":
    serveMCP()
case "list", "create":
    break
case "show", "edit", "pause", "resume", "delete", "run":
    guard let id = args.first, !id.hasPrefix("--") else { fail("\(command) needs a task id.") }
    taskID = id
    args.removeFirst()
default:
    fail("Unknown command \(command).\n\n" + usage)
}

let fieldNames = ["--name": "name", "--prompt": "prompt", "--repeat": "repeat", "--days": "days", "--date": "date",
                  "--time": "time", "--project": "project", "--agent": "agent"]
var fields: [String: Any] = [:]
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { fail("\(flag) needs a value.") }
    let value = args.removeFirst()
    if flag == "--prompt-file" {
        let data = value == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : (FileManager.default.contents(atPath: value) ?? { fail("Can't read \(value).") }())
        fields["prompt"] = String(decoding: data, as: UTF8.self)
    } else if let name = fieldNames[flag] {
        fields[name] = value
    } else {
        fail("Unknown option \(flag).\n\n" + usage)
    }
}
if !fields.isEmpty, command != "create", command != "edit" { fail("\(command) takes no options.") }

switch send(command, taskID: taskID, fields: fields) {
case .success(let reply):
    print(String(decoding: reply, as: UTF8.self))
    exit(replyOK(reply) ? 0 : 1)
case .failure(let e):
    fail(e.message)
}
