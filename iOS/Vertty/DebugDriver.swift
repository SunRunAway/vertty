#if DEBUG
    import Foundation
    import GhosttyTerminal
    import UIKit
    import VerttyRemote
    import VerttyTailnet
    import VerttyUI

    /// Drives the app for scripts/test-remote-ios.py when launched with
    /// VERTTY_DEBUG=1: reads commands from Documents/debug/input.txt and
    /// writes what the app shows to Documents/debug/state.txt.
    final class DebugDriver {
        static let shared = DebugDriver()

        private var directory: URL?
        private var timer: Timer?
        private var store: RemoteStore? { AppModel.shared.store }
        private var terminal: TerminalViewController? {
            TerminalViewController.current.flatMap { $0.view.window != nil ? $0 : nil }
        }

        func start() {
            guard ProcessInfo.processInfo.environment["VERTTY_DEBUG"] == "1",
                  let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let dir = docs.appendingPathComponent("debug")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
            // The terminal layer's sizes and lifecycle, to terminal.log.
            let log = dir.appendingPathComponent("terminal.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: log)
            TerminalDebugLog.sink = { line in handle?.write(Data((line + "\n").utf8)) }
            TerminalDebugLog.enable([.lifecycle, .metrics])
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
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
                if let url = remoteURL(from: argument) { app.connect(url) }
            case "tailnet":
                // Picks the computer with this name on the tailnet (its DNS
                // label) on the connect screen; nothing until it's listed.
                Tailnet.shared.activateClient()
                if let computer = Tailnet.shared.computers.first(where: { $0.dnsName == argument && $0.online }) {
                    app.connect(computer)
                }
            case "tailnetlogin":
                // Same as "Sign In with Tailscale": opens the sign-in page.
                Tailnet.shared.activateClient()
                TailscaleSignIn.shared.start()
            case "tailnetlogout":
                Tailnet.shared.logout()
            case "disconnect":
                app.disconnect()
            case "open":
                if let i = Int(argument) { store?.selectCard(at: i) }
            case "back":
                store?.selectedCardID = nil
            case "new":
                guard let store, let project = store.currentProject else { return }
                store.newSession(in: project, kind: nil)
            case "focus":
                terminal?.debugFocus()
            case "hidekeyboard":
                terminal?.debugHideKeyboard()
            case "slide":
                if let n = Int(argument) { terminal?.debugSlide(n) }
            case "type":
                terminal?.debugType(argument)
            case "insert":
                terminal?.debugInsert(argument)
            case "enter":
                terminal?.debugKey(.enter)
            case "ctrlc":
                terminal?.debugKey(.c, modifiers: .ctrl)
            case "background":
                store?.client.reconnectsAutomatically = false
            case "foreground":
                store?.client.reconnectsAutomatically = true
                store?.viewportChanged(force: true)
            default:
                break
            }
        }

        private func write(to url: URL) {
            var lines: [String] = []
            if let store {
                let client = store.client
                lines.append("status=\(client.status) server=\(client.serverName) open=\(store.selectedCardID?.uuidString ?? "-")")
                for card in store.allCards {
                    lines.append("card \(card.id) \(card.title) status=\(card.status) attention=\(card.attention) pr=\(card.prURL ?? "-")")
                }
                if store.selectedCardID != nil, let t = terminal {
                    lines.append(t.debugSummary)
                    lines.append(t.visibleText.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "r| " + $0 }.joined(separator: "\n"))
                }
            } else {
                lines.append("status=none")
            }
            let tailnet = Tailnet.shared
            lines.append("tailnet state=\(tailnet.state) signedIn=\(!tailnet.account.isEmpty) name=\(tailnet.name) computers=\(tailnet.computers.map { "\($0.dnsName):\($0.online ? "online" : "offline")" }.joined(separator: ","))")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
