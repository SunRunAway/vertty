#if DEBUG
    import Foundation
    import GhosttyTerminal
    import UIKit

    /// Drives the app for scripts/test-remote-ios.py when launched with
    /// VHOSTTY_DEBUG=1: reads commands from Documents/debug/input.txt and
    /// writes what the app shows to Documents/debug/state.txt.
    final class DebugDriver {
        static let shared = DebugDriver()

        private var directory: URL?
        private weak var session: RemoteSession?
        private var timer: Timer?

        func start() {
            guard ProcessInfo.processInfo.environment["VHOSTTY_DEBUG"] == "1",
                  let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let dir = docs.appendingPathComponent("debug")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        }

        func attach(_ session: RemoteSession) {
            self.session = session
        }

        private func tick() {
            guard let directory else { return }
            let input = directory.appendingPathComponent("input.txt")
            if let text = try? String(contentsOf: input, encoding: .utf8) {
                try? FileManager.default.removeItem(at: input)
                for line in text.split(separator: "\n") { run(String(line)) }
            }
            write(to: directory.appendingPathComponent("state.txt"))
        }

        private func run(_ line: String) {
            let (command, argument) = line.firstIndex(of: " ").map {
                (String(line[..<$0]), String(line[line.index(after: $0)...]))
            } ?? (line, "")
            let app = AppModel.shared
            switch command {
            case "connect":
                app.address = argument
                _ = app.connect()
            case "disconnect":
                app.disconnect()
            case "open":
                guard let session, let i = Int(argument), session.state.cards.indices.contains(i) else { return }
                session.open(session.state.cards[i].id)
            case "back":
                session?.path = []
            case "new":
                guard let session, let project = session.state.projects.first else { return }
                session.newSession(in: project, kind: nil)
            case "type":
                session?.terminal?.debugType(argument)
            case "insert":
                session?.terminal?.debugInsert(argument)
            case "enter":
                session?.terminal?.debugKey(.enter)
            case "ctrlc":
                session?.terminal?.debugKey(.c, modifiers: .ctrl)
            case "background":
                session?.wentToBackground()
            case "foreground":
                session?.cameToForeground()
            default:
                break
            }
        }

        private func write(to url: URL) {
            var lines: [String] = []
            if let session {
                let client = session.client
                lines.append("status=\(client.status) server=\(client.serverName) open=\(session.openCardID ?? "-")")
                for card in session.state.cards {
                    lines.append("card \(card.id) \(card.title) status=\(card.status)")
                }
                if let t = session.terminal {
                    lines.append(t.debugSummary)
                    lines.append(t.visibleText.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "r| " + $0 }.joined(separator: "\n"))
                }
            } else {
                lines.append("status=none")
            }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
