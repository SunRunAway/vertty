import Foundation

/// Vhostty's own Codex app server. Codex cards connect their TUI to it with
/// `--remote`, so Vhostty can add its built-in skills (skills/extraRoots/set
/// applies to the whole server) and give the agent's commands Vhostty's
/// environment (the schedule command and socket), without touching the user's
/// Codex config or shared daemon.
final class CodexServer {
    static let shared = CodexServer()

    private let queue = DispatchQueue(label: "vhostty.codex-server")
    private var process: Process?
    /// Held open for the server's lifetime; when Vhostty exits (even killed) it
    /// closes, and the server is stopped.
    private var lifeline: Pipe?

    /// Where cards' TUIs connect. Codex links a long path to a short one itself.
    var socketPath: String { AppPaths.support.appendingPathComponent("codex.sock").path }

    /// Starts the server (or reuses one a previous launch left running) and
    /// registers the skills. Runs in the background; cards started before it's
    /// ready run without it.
    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.sync {
            try? lifeline?.fileHandleForWriting.close()
            lifeline = nil
            process = nil
        }
    }

    private func startLocked() {
        if !registerSkills() {
            unlink(socketPath)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ShellEnvironment.shell)
            // The same login shell the cards use, so PATH and CODEX_HOME match.
            // It waits on stdin, which only ends when Vhostty does.
            let command = "codex app-server --listen \(ShellQuote.quote("unix://" + socketPath)) </dev/null & "
                + "server=$!; read -r _; kill $server; wait $server"
            p.arguments = ["-l", "-i", "-c", command]
            var env = ProcessInfo.processInfo.environment
            env["VHOSTTY_SOCK"] = AppPaths.hookSocket
            env["VHOSTTY_SCHEDULE_CLI"] = ClaudeLauncher.scheduleCLIPath
            p.environment = env
            let pipe = Pipe()
            // Only Vhostty holds the writing end: terminals it starts later
            // mustn't inherit it, or the server would outlive a killed Vhostty.
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                NSLog("Vhostty: couldn't start the Codex app server: %@", error.localizedDescription)
                return
            }
            process = p
            lifeline = pipe
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.25)
                if registerSkills() { return }
                if !p.isRunning { break }
            }
            NSLog("Vhostty: the Codex app server didn't come up")
        }
    }

    /// Connects, initializes and sets the skill roots. False if no server answers.
    private func registerSkills() -> Bool {
        guard let ws = UnixWebSocket(path: Self.resolved(socketPath)) else { return false }
        defer { ws.close() }
        guard ws.call(id: 1, method: "initialize", params: ["clientInfo": ["name": "vhostty", "version": "1"]]) != nil else {
            return false
        }
        ws.send(["jsonrpc": "2.0", "method": "initialized"])
        let reply = ws.call(id: 2, method: "skills/extraRoots/set", params: ["extraRoots": [ClaudeLauncher.skillsDir]])
        return reply?["result"] != nil
    }

    /// The socket's real path (Codex replaces a too-long one with a link).
    private static func resolved(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }
}

/// Just enough of a WebSocket client (RFC 6455) over a Unix socket for a few
/// JSON-RPC calls to the Codex app server.
private final class UnixWebSocket {
    private let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var addr = UnixSocket.address(path) else { Darwin.close(fd); return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            guard fill() else { Darwin.close(fd); return nil }
        }
        let range = buffer.range(of: end)!
        guard String(decoding: buffer[..<range.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
            Darwin.close(fd)
            return nil
        }
        buffer.removeSubrange(..<range.upperBound)
    }

    func close() { Darwin.close(fd) }

    func call(id: Int, method: String, params: [String: Any]) -> [String: Any]? {
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while let message = receive() {
            if message["id"] as? Int == id { return message }
        }
        return nil
    }

    func send(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data([0x81])
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(0x80 | n))
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(n >> 8), UInt8(n & 0xff)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((n >> ($0 * 8)) & 0xff) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        write(frame)
    }

    private func receive() -> [String: Any]? {
        var message = Data()
        while true {
            guard let head = take(2) else { return nil }
            var length = Int(head[1] & 0x7f)
            if length == 126 {
                guard let ext = take(2) else { return nil }
                length = Int(ext[0]) << 8 | Int(ext[1])
            } else if length == 127 {
                guard let ext = take(8) else { return nil }
                length = ext.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let payload = take(length) else { return nil }
            let opcode = head[0] & 0x0f
            if opcode == 8 { return nil }
            if opcode == 9 || opcode == 10 { continue }
            message.append(contentsOf: payload)
            if head[0] & 0x80 != 0 {
                return (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] ?? [:]
            }
        }
    }

    private func take(_ n: Int) -> [UInt8]? {
        while buffer.count < n {
            guard fill() else { return nil }
        }
        let out = [UInt8](buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
