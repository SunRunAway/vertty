// A scriptable remote client for tests (scripts/test-remote.py): reads one
// command per line on stdin, prints one JSON event per line on stdout.
import Foundation
import VhosttyRemote

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

/// Terminal bytes as text: escape sequences dropped, CR/LF kept as \n.
func plain(_ data: Data) -> String {
    let s = String(decoding: data, as: UTF8.self)
    var out = ""
    var i = s.unicodeScalars.makeIterator()
    while let c = i.next() {
        if c == "\u{1b}" {
            guard let n = i.next() else { break }
            if n == "[" {
                while let x = i.next(), !(0x40...0x7e).contains(x.value) {}
            } else if n == "]" {
                var prev: Unicode.Scalar = " "
                while let x = i.next() {
                    if x == "\u{07}" || (prev == "\u{1b}" && x == "\\") { break }
                    prev = x
                }
            } else if n == "(" || n == ")" {
                _ = i.next()
            }
        } else if c == "\n" {
            out.append("\n")
        } else if c.value >= 0x20 {
            out.unicodeScalars.append(c)
        }
    }
    return out
}

let url = URL(string: CommandLine.arguments[1])!
let session = URLSession(configuration: .default)
var task: URLSessionWebSocketTask?
var nextID: UInt64 = 1

func send(_ fill: (inout Remote.ClientMessage) -> Void) {
    var msg = Remote.ClientMessage()
    fill(&msg)
    let data = try! msg.serializedData()
    task?.send(.data(data)) { error in
        if let error { emit(["event": "send-error", "message": error.localizedDescription]) }
    }
}

func size(_ c: String, _ r: String) -> Remote.TerminalSize {
    Remote.TerminalSize(columns: Int(c) ?? 80, rows: Int(r) ?? 24)
}

func receive(_ t: URLSessionWebSocketTask) {
    t.receive { result in
        switch result {
        case .failure(let error):
            emit(["event": "disconnected", "message": error.localizedDescription])
        case .success(.data(let data)):
            handle(try! Remote.ServerMessage(serializedBytes: data))
            receive(t)
        case .success:
            receive(t)
        }
    }
}

func handle(_ msg: Remote.ServerMessage) {
    switch msg.body {
    case .welcome(let w):
        emit(["event": "welcome", "server": w.serverName, "token": w.connectionToken])
    case .state(let s):
        emit(["event": "state",
              "projects": s.projects.map { ["id": $0.id, "name": $0.name, "kind": $0.defaultKind.rawValue] },
              "cards": s.cards.map { ["id": $0.id, "project": $0.projectID, "title": $0.title,
                                      "status": $0.status.rawValue, "running": $0.running, "session": $0.sessionID] },
              "history": s.history.map { ["project": $0.projectID, "sessions": $0.sessions.map(\.sessionID),
                                          "more": $0.moreAvailable] },
              "confirmClose": s.confirmClose])
    case .reply(let r):
        var e: [String: Any] = ["event": "reply", "id": r.requestID]
        if r.hasError { e["error"] = r.error.code.rawValue }
        switch r.result {
        case .session(let s): e["card"] = s.cardID
        case .history(let h): e["sessions"] = h.sessions.map(\.sessionID); e["more"] = h.moreAvailable
        case .closed: e["closed"] = true
        case nil: break
        }
        emit(e)
    case .snapshot(let s):
        emit(["event": "snapshot", "card": s.cardID, "cols": s.size.columns, "rows": s.size.rows,
              "bytes": s.data.count, "text": plain(s.data)])
    case .output(let o):
        emit(["event": "output", "card": o.cardID, "text": plain(o.data)])
    case .terminalClosed(let c):
        emit(["event": "terminal-closed", "card": c.cardID])
    case .notification(let n):
        emit(["event": "notification", "card": n.cardID, "title": n.title, "body": n.body])
    case .replaced:
        emit(["event": "replaced"])
    case .error(let e):
        emit(["event": "error", "code": e.code.rawValue, "message": e.message])
    case nil:
        break
    }
}

DispatchQueue.global().async {
    while let line = readLine() {
        let a = line.split(separator: " ").map(String.init)
        guard let cmd = a.first else { continue }
        DispatchQueue.main.async {
            switch cmd {
            case "hello":
                let t = session.webSocketTask(with: url)
                t.maximumMessageSize = Remote.maxFrameSize
                task = t
                t.resume()
                receive(t)
                send {
                    $0.hello.protocolVersion = .current
                    $0.hello.platform = .iphone
                    $0.hello.deviceName = "Probe"
                    if a.count > 1, a[1] != "-" { $0.hello.reconnectToken = a[1] }
                }
            case "badversion":
                let t = session.webSocketTask(with: url)
                task = t
                t.resume()
                receive(t)
                send { $0.hello.protocolVersion = .unspecified }
            case "quit":
                task?.cancel(with: .goingAway, reason: nil)
                exit(0)
            case "drop":
                task?.cancel(with: .goingAway, reason: nil)
            case "new":
                let id = nextID; nextID += 1
                send {
                    $0.requestID = id
                    $0.newSession.projectID = a[1]
                    $0.newSession.operationID = a.count > 2 ? a[2] : UUID().uuidString
                }
            case "resume":
                let id = nextID; nextID += 1
                send {
                    $0.requestID = id
                    $0.resumeSession.projectID = a[1]
                    $0.resumeSession.sessionID = a[2]
                    $0.resumeSession.kind = a.count > 3 && a[3] == "codex" ? .codex : .claude
                }
            case "close":
                let id = nextID; nextID += 1
                send {
                    $0.requestID = id
                    $0.closeSession.cardID = a[1]
                    $0.closeSession.confirmed = a.count > 2
                }
            case "history":
                let id = nextID; nextID += 1
                send {
                    $0.requestID = id
                    $0.listHistory.projectID = a[1]
                    $0.listHistory.limit = UInt32(a[2]) ?? 10
                }
            case "open":
                send { $0.openTerminal.cardID = a[1]; $0.openTerminal.size = size(a[2], a[3]) }
            case "leave":
                send { $0.leaveTerminal.cardID = a[1] }
            case "viewport":
                send { $0.viewport.cardID = a[1]; $0.viewport.size = size(a[2], a[3]) }
            case "align":
                send { $0.alignForInput.cardID = a[1]; $0.alignForInput.size = size(a[2], a[3]) }
            case "input":
                // Text after the card id, with \r for Enter.
                let text = a.dropFirst(2).joined(separator: " ").replacingOccurrences(of: "\\r", with: "\r")
                send { $0.input.cardID = a[1]; $0.input.data = Data(text.utf8) }
            default:
                emit(["event": "unknown-command", "command": cmd])
            }
        }
    }
    DispatchQueue.main.async { exit(0) }
}

dispatchMain()
