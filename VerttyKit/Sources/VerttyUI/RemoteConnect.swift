import SwiftUI
import VerttyRemote
import VerttyTailnet

public extension RemoteEndpoint {
    /// A computer on the user's tailnet, found again (and dialed through
    /// the embedded Tailscale device) for each connection attempt.
    static func tailnet(_ computer: Tailnet.Device) -> RemoteEndpoint {
        tailnet(id: computer.id, hostName: computer.hostName, name: computer.name)
    }

    /// The tailnet computer with this id, or else this host name (if it
    /// signed in again since).
    static func tailnet(id: String, hostName: String, name: String) -> RemoteEndpoint {
        let unreachable = String(localized: "Can't reach the computer over Tailscale. Check that it's on and that Via Tailscale is checked under Remote Connections in its Vertty menu.", bundle: .verttyUIResources)
        return RemoteEndpoint(name: name, detail: "Tailscale: \(hostName)", unreachable: unreachable) {
            let tailnet = Tailnet.shared
            RemoteLog.note("tailnet: finding \(hostName)/\(id), state=\(tailnet.state)")
            // Not listed isn't gone: right after starting, the list can
            // still be the cached one. Unreachable this time; the client
            // tries again if it's reconnecting.
            let device: Tailnet.Device
            do {
                device = try await tailnet.waitForComputer(id: id, hostName: hostName)
            } catch Tailnet.Failure.notSignedIn, Tailnet.Failure.notStarted {
                RemoteLog.note("tailnet: not signed in or not started, state=\(tailnet.state)")
                throw ConnectFailure(String(localized: "Sign in to Tailscale to connect to this computer.", bundle: .verttyUIResources))
            } catch {
                RemoteLog.note("tailnet: \(hostName)/\(id) not listed online (\(error)), state=\(tailnet.state), among \(tailnet.devices.count) devices, computers=\(Tailnet.describe(tailnet.computers))")
                throw ConnectFailure(unreachable)
            }
            do {
                let port = try await tailnet.dial(device, port: Remote.defaultPort)
                RemoteLog.note("tailnet: dialed \(device.dnsName)/\(device.id)")
                return URL(string: "ws://127.0.0.1:\(port)")!
            } catch {
                RemoteLog.note("tailnet: dialing \(device.dnsName)/\(device.id) failed (\(error))")
                throw ConnectFailure(unreachable)
            }
        }
    }
}

private struct ConnectFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Where a remote client picks the computer: one on the user's tailnet
/// (signing in to Tailscale first), or an address on a network the user
/// set up. The iPhone and iPad app's first screen; a window on the Mac.
public struct RemoteConnectView: View {
    @ObservedObject var tailnet: Tailnet
    @Binding var address: String
    let connectAddress: (URL) -> Void
    let connectComputer: (Tailnet.Device) -> Void
    @State private var invalid = false
    /// The user asked to sign in; the sign-in window is open.
    @State private var signingIn = false

    public init(tailnet: Tailnet = .shared, address: Binding<String>,
                connectAddress: @escaping (URL) -> Void, connectComputer: @escaping (Tailnet.Device) -> Void) {
        self.tailnet = tailnet
        _address = address
        self.connectAddress = connectAddress
        self.connectComputer = connectComputer
    }

    public var body: some View {
        Form {
            Section {
                tailscale
            } header: {
                Text("Tailscale", bundle: .verttyUIResources)
            } footer: {
                if tailnet.state != .running {
                    Text("Sign in with the same Tailscale account as Vertty on your computer. You don't need the Tailscale app.", bundle: .verttyUIResources)
                }
            }
            Section {
                TextField(text: $address, prompt: Text(verbatim: "mac.local:58563")) {
                    Text("Address", bundle: .verttyUIResources)
                }
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .autocorrectionDisabled()
                .onSubmit(connectToAddress)
                Button(action: connectToAddress) { Text("Connect", bundle: .verttyUIResources) }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Listen on 127.0.0.1 Only", bundle: .verttyUIResources)
            } footer: {
                Text("Your computer's address, with the port shown under Remote Connections in its Vertty menu. The connection's security is up to you (for example a VPN).", bundle: .verttyUIResources)
            }
        }
        .formStyle(.grouped)
        .onChange(of: tailnet.state) { _, state in
            if state == .running { signingIn = false }
        }
        .alert(Text("That isn't an address Vertty can connect to.", bundle: .verttyUIResources), isPresented: $invalid) {
            Button(role: .cancel) {} label: { Text("OK", bundle: .verttyUIResources) }
        } message: {
            Text("Enter a host and port, such as mac.local:58563.", bundle: .verttyUIResources)
        }
    }

    @ViewBuilder
    private var tailscale: some View {
        switch tailnet.state {
        case .running:
            let computers = tailnet.computers
            if computers.isEmpty {
                Text("No computers found. On your computer, choose Via Tailscale under Remote Connections in the Vertty menu, and sign in to the same Tailscale account.", bundle: .verttyUIResources)
                    .foregroundStyle(.secondary)
            }
            ForEach(computers) { computer in
                Button { connectComputer(computer) } label: {
                    HStack {
                        Label(computer.name, systemImage: "desktopcomputer")
                        Spacer()
                        Text(computer.online ? "Online" : "Offline", bundle: .verttyUIResources)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!computer.online)
            }
            HStack {
                Text("Signed in as \(tailnet.account)", bundle: .verttyUIResources)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(role: .destructive) { tailnet.logout() } label: { Text("Sign Out", bundle: .verttyUIResources) }
                    .buttonStyle(.borderless)
            }
        case .starting where !signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Tailscale…", bundle: .verttyUIResources).foregroundStyle(.secondary)
            }
        default:
            if case .failed(let reason) = tailnet.state {
                Text(reason).foregroundStyle(.secondary)
            }
            if signingIn {
                Text("Finish signing in to Tailscale in the window that opened.", bundle: .verttyUIResources)
                    .foregroundStyle(.secondary)
                Button(action: signIn) { Text("Open the Sign-In Page Again", bundle: .verttyUIResources) }
            } else {
                Button(action: signIn) { Text("Sign In with Tailscale", bundle: .verttyUIResources) }
            }
        }
    }

    private func signIn() {
        signingIn = true
        tailnet.activateClient()
        TailscaleSignIn.shared.start()
    }

    private func connectToAddress() {
        guard let url = remoteURL(from: address) else {
            invalid = true
            return
        }
        connectAddress(url)
    }
}
