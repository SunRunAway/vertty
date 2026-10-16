import Foundation

/// A Claude Code hook event forwarded by `vertty-hook`.
struct HookEvent {
    let tabID: UUID
    let name: String
    let sessionID: String?
    let cwd: String?
    let transcriptPath: String?
    let message: String?
    let notificationType: String?
    let source: String?
}

/// Listens on a Unix socket for hook events sent by the `vertty-hook` helper.
///
/// Wire format: "<tab uuid>\n<hook JSON from Claude Code's stdin>", then EOF.
/// `vertty-schedule` sends "schedule\n<request JSON>", then EOF, and reads the
/// JSON answer back.
final class HookServer {
    let socketPath: String
    private let onEvent: (HookEvent) -> Void
    var onScheduleRequest: (([String: Any]) -> [String: Any])?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "vertty.hooks.handle")

    init(socketPath: String, onEvent: @escaping (HookEvent) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() {
        unlink(socketPath)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        guard var addr = UnixSocket.address(socketPath) else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            NSLog("Vertty: hook socket bind failed: %d", errno)
            close(fd)
            fd = -1
            return
        }
        chmod(socketPath, 0o600)

        let listener = fd
        let thread = Thread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // Serial, in accept order: PostToolUse and Stop arrive back to back
                // and must not be reordered.
                self?.queue.async { self?.handle(client) }
            }
        }
        thread.name = "vertty.hooks"
        thread.start()
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 4 << 20 { break }
        }

        if let nl = data.firstIndex(of: UInt8(ascii: "\n")), data[..<nl].elementsEqual("schedule".utf8) {
            return answerSchedule(client, data[(nl + 1)...])
        }
        guard let nl = data.firstIndex(of: UInt8(ascii: "\n")),
              let tabID = UUID(uuidString: String(decoding: data[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              let obj = (try? JSONSerialization.jsonObject(with: data[(nl + 1)...])) as? [String: Any],
              let name = obj["hook_event_name"] as? String else { return }

        let event = HookEvent(
            tabID: tabID,
            name: name,
            sessionID: obj["session_id"] as? String,
            cwd: obj["cwd"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            message: obj["message"] as? String,
            notificationType: obj["notification_type"] as? String,
            source: obj["source"] as? String)
        DispatchQueue.main.async { self.onEvent(event) }
    }
}

extension HookServer {
    fileprivate func answerSchedule(_ client: Int32, _ body: Data) {
        var reply: [String: Any] = ["ok": false, "error": "Bad request."]
        if let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let handler = onScheduleRequest {
            reply = DispatchQueue.main.sync { handler(request) }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(client, base + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            guard bytes.count < buf.count else { return false }
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
            return true
        }
        return ok ? addr : nil
    }
}
