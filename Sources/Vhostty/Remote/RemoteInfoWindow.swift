import AppKit
import SwiftUI
import VhosttyRemote

/// "Remote Connection Info…": where clients connect, whether the service
/// runs, and who is connected.
final class RemoteInfoWindow {
    private var window: NSWindow?
    private let server: RemoteServer

    init(server: RemoteServer) {
        self.server = server
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = String(localized: "Remote Connection Info")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RemoteInfoView(server: server))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RemoteInfoView: View {
    @ObservedObject var server: RemoteServer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Status") { statusText }
            if let port = port {
                row("Port") { Text(verbatim: "\(port)").textSelection(.enabled) }
                row("Address") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(server.addresses(port: port), id: \.self) { address in
                            Text(verbatim: address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            row("Remote client") {
                if let client = server.client {
                    Text("\(client.deviceName.isEmpty ? deviceKind(client.platform) : client.deviceName), connected since \(client.since.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            Text("Anyone who can reach this address can use your sessions. Keep it to networks you trust, such as a VPN.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    private var port: UInt16? {
        switch server.status {
        case .listening(let p), .starting(let p): return p
        default: return nil
        }
    }

    @ViewBuilder private var statusText: some View {
        switch server.status {
        case .off: Text("Off. Turn on “Allow Remote Connections” in the Vhostty menu.")
        case .starting: Text("Starting…")
        case .listening: Text("Allowing remote connections")
        case .failed(let reason): Text("Failed to start: \(reason)").foregroundStyle(.red)
        }
    }

    private func deviceKind(_ platform: Remote.ClientPlatform) -> String {
        platform == .iphone ? "iPhone" : "Mac"
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
