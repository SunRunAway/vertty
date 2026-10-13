import Foundation

// vhostty-schedule: reads Vhostty's scheduled tasks and submits drafts for the
// user to confirm in Vhostty. It can't approve anything. Used by the built-in
// schedule skill; talks to the running app over its hook socket.

let usage = """
usage: vhostty-schedule <command> [options]

  list                      tasks and drafts waiting for confirmation
  show <task-id>            one task with its recent runs
  create [fields]           draft a new task
  edit <task-id> [fields]   draft changes to a task
  pause|resume|delete|run <task-id>
                            draft that action ("run" = run now)
  status <draft-id>         pending, approved, rejected or withdrawn
  withdraw <draft-id>       take back a pending draft

fields:
  --name TEXT
  --prompt TEXT | --prompt-file PATH ("-" reads stdin)
  --repeat once|daily|weekdays|weekly
  --days mon,tue,…          for weekly
  --date YYYY-MM-DD         for once
  --time HH:MM              24-hour, in --timezone
  --timezone ZONE           IANA name; default: this Mac's zone
  --project PATH|NAME       default: the project of this session
  --agent claude|codex      default: this session's agent

Drafts do nothing until the user confirms them in Vhostty.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(args.isEmpty ? 2 : 0)
}
args.removeFirst()

var request: [String: Any] = ["op": command, "cwd": FileManager.default.currentDirectoryPath]
if let tab = ProcessInfo.processInfo.environment["VHOSTTY_TAB_ID"] { request["tabID"] = tab }

switch command {
case "list":
    break
case "show", "edit", "pause", "resume", "delete", "run":
    guard let id = args.first, !id.hasPrefix("--") else { fail("\(command) needs a task id.") }
    request["taskID"] = id
    args.removeFirst()
case "status", "withdraw":
    guard let id = args.first, !id.hasPrefix("--") else { fail("\(command) needs a draft id.") }
    request["draftID"] = id
    args.removeFirst()
case "create":
    break
default:
    fail("Unknown command \(command).\n\n" + usage)
}

let fieldNames = ["--name": "name", "--prompt": "prompt", "--repeat": "repeat", "--days": "days", "--date": "date",
                  "--time": "time", "--timezone": "timezone", "--project": "project", "--agent": "agent"]
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
if !fields.isEmpty {
    guard command == "create" || command == "edit" else { fail("\(command) takes no options.") }
    request["fields"] = fields
}

// The socket of the Vhostty that started this session, else the default one.
let env = ProcessInfo.processInfo.environment
let sockPath = env["VHOSTTY_SOCK"] ?? {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let p = support.appendingPathComponent("Vhostty/hook.sock").path
    return p.utf8.count < 100 ? p : "/tmp/vhostty-\(getuid()).sock"
}()

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("Can't open a socket.") }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(sockPath.utf8)
let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
    guard pathBytes.count < buf.count else { return false }
    buf.copyBytes(from: pathBytes)
    buf[pathBytes.count] = 0
    return true
}
guard fits else { fail("Socket path too long.") }
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { fail("Vhostty isn't running (no socket at \(sockPath)).") }
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
close(fd)
guard !reply.isEmpty else { fail("No answer from Vhostty.") }
print(String(decoding: reply, as: UTF8.self))
let ok = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["ok"] as? Bool ?? false
exit(ok ? 0 : 1)
