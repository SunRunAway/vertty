import CTailnet
import Foundation

/// The Tailscale device the app embeds (VerttyKit/Tailnet, on Tailscale's
/// tsnet): a user-space node on the user's tailnet, no VPN needed. A Mac
/// serves remote connections on it; a client finds and dials computers
/// through it. One per app, shared by everything that uses it.
///
/// Main thread only; the blocking calls run on queues of their own.
public final class Tailnet: ObservableObject {
    public static let shared = Tailnet()

    public enum State: Equatable {
        case stopped
        case starting
        /// Not signed in (or the login expired); see login(open:).
        case needsLogin
        case running
        /// Couldn't start (the reason).
        case failed(String)
    }

    /// Another device on the tailnet.
    public struct Device: Identifiable, Equatable, Sendable {
        public let id: String
        public let hostName: String
        /// Its unique name on the tailnet (the first label of its DNS name).
        public let dnsName: String
        public let os: String
        public let online: Bool
        public let ip: String
        /// Belongs to the same Tailscale user as this device.
        public let sameUser: Bool

        /// The name the user gave it, without Vertty's suffix.
        public var name: String {
            hostName.hasSuffix(Tailnet.suffix) ? String(hostName.dropLast(Tailnet.suffix.count)) : hostName
        }

        /// The user's Mac that runs Vertty (its remote service listens when
        /// it's online and "Via Tailscale" is checked).
        public var isVerttyComputer: Bool {
            sameUser && os == "macOS" && hostName.hasSuffix(Tailnet.suffix)
        }
    }

    public enum Failure: Error, Equatable {
        case notSignedIn
        case notStarted
        case notFound
        /// Tailscale couldn't reach it (its message).
        case unreachable(String)
    }

    /// Appended to the device names, so Vertty's devices can be told apart
    /// on the tailnet (and in the Tailscale admin console).
    public static let suffix = "-vertty"

    @Published public private(set) var state: State = .stopped
    /// Where to sign in, while state is needsLogin.
    @Published public private(set) var authURL: URL?
    /// The signed-in Tailscale account.
    @Published public private(set) var account = ""
    /// This device's name on the tailnet.
    @Published public private(set) var name = ""
    @Published public private(set) var devices: [Device] = []

    /// The user's Vertty computers, online ones first.
    public var computers: [Device] {
        devices.filter(\.isVerttyComputer).sorted {
            $0.online != $1.online ? $0.online : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Where the device keeps its state (its login); set before starting.
    public var directory: URL?
    /// The device's name on the tailnet, before the suffix.
    public var deviceName = "Vertty"

    /// The user signed in on this device and hasn't signed out (the login
    /// may have expired since).
    public var signedInHere: Bool {
        guard let marker else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private var marker: URL? { directory?.appendingPathComponent("signed-in") }

    /// Running for the remote client (see activateClient()).
    public private(set) var clientActive = false

    private let control = DispatchQueue(label: "dev.vertty.tailnet")
    private var users = 0
    private var timer: Timer?
    private var polling = false
    /// Bumped per login(open:), so only the latest opens its page.
    private var loginRequest = 0

    /// Where the device's state changes and status errors are noted (the
    /// remote client's log), if anywhere.
    public static var log: ((String) -> Void)?

    private init() {}

    // MARK: - Running

    /// Keeps the device running until a matching endUse().
    public func use() {
        users += 1
        start()
    }

    public func endUse() {
        users = max(users - 1, 0)
        if users == 0 { stop() }
    }

    /// Keeps the device running for the remote client: its list of
    /// computers and sign-in. Once per app, however many places call it.
    public func activateClient() {
        guard !clientActive else { return }
        clientActive = true
        use()
    }

    public func deactivateClient() {
        guard clientActive else { return }
        clientActive = false
        endUse()
    }

    private func start() {
        guard state == .stopped || isFailed, let directory else { return }
        Self.log?("tailnet: starting")
        state = .starting
        let hostName = Self.hostName(deviceName)
        control.async {
            let error = directory.path.withCString { dir in
                hostName.withCString { host in
                    Self.take(VTStart(UnsafeMutablePointer(mutating: dir), UnsafeMutablePointer(mutating: host)))
                }
            }
            DispatchQueue.main.async {
                guard self.state == .starting else { return }
                if let error {
                    self.state = .failed(error)
                    return
                }
                self.poll()
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.poll() }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func stop() {
        Self.log?("tailnet: stopping")
        timer?.invalidate()
        timer = nil
        loginRequest += 1
        control.async { VTStop() }
        state = .stopped
        authURL = nil
        account = ""
        name = ""
        devices = []
    }

    /// The device's name on the tailnet: the user's name for it with the
    /// suffix (Tailscale makes a DNS name of it).
    static func hostName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Vertty" : trimmed) + suffix
    }

    // MARK: - Signing in

    /// Calls `open` with Tailscale's sign-in page as soon as it's there
    /// (never if the device is signed in by then). Call while using the
    /// device (use()).
    public func login(open: @escaping (URL) -> Void) {
        if let authURL, state == .needsLogin {
            open(authURL)
            return
        }
        loginRequest += 1
        let request = loginRequest
        // After the device has started; waiting for the page off the
        // control queue, which stays free for stopping and the like.
        control.async {
            DispatchQueue.global(qos: .userInitiated).async {
                var page: UnsafeMutablePointer<CChar>?
                // Tailscale's servers take a few seconds, more on a slow
                // network.
                _ = Self.take(VTLogin(30_000, &page))
                let url = Self.take(page).flatMap(URL.init(string:))
                DispatchQueue.main.async {
                    guard request == self.loginRequest, let url else { return }
                    open(url)
                    self.poll()
                }
            }
        }
    }

    /// Signs this device out; it leaves the tailnet. Stops it unless the
    /// Mac still serves on it (then it waits for a new sign-in).
    public func logout() {
        loginRequest += 1
        if let marker { try? FileManager.default.removeItem(at: marker) }
        control.async {
            _ = Self.take(VTLogout())
            DispatchQueue.main.async { self.poll() }
        }
        deactivateClient()
    }

    // MARK: - Serving

    /// Accepts connections from the same user's devices on `port` and
    /// forwards them to the server on 127.0.0.1:`localPort`.
    public func serve(port: UInt16, to localPort: UInt16, failed: @escaping (String) -> Void) {
        control.async {
            if let error = Self.take(VTServe(Int32(port), Int32(localPort))) {
                DispatchQueue.main.async { failed(error) }
            }
        }
    }

    public func stopServing() {
        control.async { VTStopServing() }
    }

    // MARK: - Connecting

    /// The computer with this id, or else this name (it signed in again).
    public func computer(id: String, hostName: String) -> Device? {
        devices.first { $0.id == id } ?? computers.first { $0.hostName == hostName }
    }

    /// Waits for the device to be up and the computer to be listed and
    /// online (fails if the device needs signing in): Tailscale can only
    /// reach a device it lists. Started again, it reports running from the
    /// network map it cached, which may list no other devices, until the
    /// live one comes in a few seconds later.
    @MainActor
    public func waitForComputer(id: String, hostName: String, timeout: TimeInterval = 20) async throws -> Device {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .needsLogin: throw Failure.notSignedIn
            case .stopped: throw Failure.notStarted
            case .failed(let reason): throw Failure.unreachable(reason)
            case .running:
                if let device = computer(id: id, hostName: hostName), device.online { return device }
            case .starting: break
            }
            if Date() > deadline { throw Failure.notFound }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Connects to `device`:`port` and returns a port on 127.0.0.1 that
    /// takes one connection to it, for a short while.
    public func dial(_ device: Device, port: UInt16, timeout: TimeInterval = 10) async throws -> UInt16 {
        let ip = device.ip
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var local: Int32 = 0
                let error = ip.withCString { ip in
                    Self.take(VTDial(UnsafeMutablePointer(mutating: ip), Int32(port), Int32(timeout * 1000), &local))
                }
                if let error {
                    continuation.resume(throwing: Failure.unreachable(error))
                } else {
                    continuation.resume(returning: UInt16(local))
                }
            }
        }
    }

    // MARK: - Status

    private struct Status: Decodable {
        struct Peer: Decodable {
            let id, hostName, dnsName, os, ip: String
            let online, sameUser: Bool
        }

        let state: String
        let authURL: String?
        let user: String?
        let name: String?
        let peers: [Peer]
        let error: String?
    }

    private func poll() {
        guard timer != nil || state == .starting, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let json = Self.take(VTStatus()) ?? ""
            let status = try? JSONDecoder().decode(Status.self, from: Data(json.utf8))
            DispatchQueue.main.async {
                self.polling = false
                guard let status, self.state != .stopped else { return }
                self.apply(status)
            }
        }
    }

    private func apply(_ status: Status) {
        let state: State = switch status.state {
        case "Running": .running
        case "NeedsLogin", "NeedsMachineAuth": .needsLogin
        default: .starting
        }
        let authURL = state == .needsLogin ? status.authURL.flatMap { $0.isEmpty ? nil : URL(string: $0) } : nil
        let devices = status.peers.map {
            Device(id: $0.id, hostName: $0.hostName, dnsName: String($0.dnsName.prefix { $0 != "." }), os: $0.os, online: $0.online, ip: $0.ip, sameUser: $0.sameUser)
        }
        if let error = status.error { Self.log?("tailnet: status error \(error)") }
        if self.state != state || self.devices.count != devices.count {
            Self.log?("tailnet: \(status.state) (\(state)), \(devices.count) devices, computers=\(Self.describe(devices.filter(\.isVerttyComputer)))")
        }
        if self.state != state { self.state = state }
        if self.authURL != authURL { self.authURL = authURL }
        if account != (status.user ?? "") { account = status.user ?? "" }
        if name != (status.name ?? "") { name = status.name ?? "" }
        if self.devices != devices { self.devices = devices }
        if state == .running, let marker, !signedInHere {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }

    /// Devices for the log: DNS label, id and whether online.
    public static func describe(_ devices: [Device]) -> String {
        devices.map { "\($0.dnsName)/\($0.id)/\($0.online ? "online" : "offline")" }.joined(separator: ",")
    }

    /// A string the library returned, freed.
    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { VTFree(p) }
        return String(cString: p)
    }
}
