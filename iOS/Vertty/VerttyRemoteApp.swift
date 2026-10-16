import Combine
import SwiftUI
import UserNotifications
import VerttyRemote
import VerttyTailnet
import VerttyUI

@main
struct VerttyRemoteApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase
    /// Went to the background since last active. Locking the iPhone passes
    /// through active for a moment on its way there; that isn't coming back.
    @State private var backgrounded = false

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, phase in
            RemoteLog.note("app: \(phase)")
            guard let store = app.store else { return }
            switch phase {
            case .active:
                // Back in the foreground: reconnect after an ordinary drop, and
                // the open terminal takes the iPhone's size again.
                store.client.reconnectsAutomatically = true
                if backgrounded {
                    backgrounded = false
                    store.viewportChanged(force: true)
                }
            case .background:
                backgrounded = true
                store.client.reconnectsAutomatically = false
            default:
                break
            }
        }
    }
}

/// The computer the app is connected to, if any.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let addressKey = "RemoteAddress"
    /// The computer last connected to through Tailscale, as id, host name
    /// and name on separate lines; absent when it was an address.
    static let tailnetKey = "RemoteTailnetComputer"
    /// The connection's token while connected; the app connects again with
    /// it when it starts. Gone once the user disconnects or another device
    /// takes over, so the app then starts on the connect screen.
    static let tokenKey = "RemoteConnectionToken"

    @Published private(set) var store: RemoteStore?
    @Published var address = UserDefaults.standard.string(forKey: addressKey) ?? ""
    private var statusWatch: AnyCancellable?

    private init() {
        let tailnet = Tailnet.shared
        Tailnet.log = RemoteLog.note
        tailnet.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale")
        tailnet.deviceName = UIDevice.current.name
        if tailnet.signedInHere { tailnet.activateClient() }
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.tailnetKey)?.components(separatedBy: "\n"), saved.count == 3 {
            connect(.tailnet(id: saved[0], hostName: saved[1], name: saved[2]), resuming: token)
        } else if let url = remoteURL(from: address) {
            connect(.url(url), resuming: token)
        }
    }

    /// Connects to the address the user typed.
    func connect(_ url: URL) {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.addressKey)
        UserDefaults.standard.removeObject(forKey: Self.tailnetKey)
        connect(.url(url), resuming: nil)
    }

    func connect(_ computer: Tailnet.Device) {
        UserDefaults.standard.set([computer.id, computer.hostName, computer.name].joined(separator: "\n"), forKey: Self.tailnetKey)
        connect(.tailnet(computer), resuming: nil)
    }

    private func connect(_ endpoint: RemoteEndpoint, resuming token: String?) {
        store?.close()
        let store = RemoteStore(endpoint: endpoint, platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone,
                                deviceName: UIDevice.current.name)
        store.terminalBackground = TerminalViewController.background
        store.isViewing = { [weak store] id in
            store?.selectedCardID == id && UIApplication.shared.applicationState == .active
        }
        self.store = store
        statusWatch = store.client.$status.sink { [weak client = store.client] status in
            switch status {
            case .connected:
                // Read after the change: the token comes with it.
                DispatchQueue.main.async {
                    if let token = client?.connectionToken { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
                }
            case .replaced:
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            default:
                break
            }
        }
        if let token { store.client.connect(resuming: token) } else { store.client.connect() }
        // Not under the debug driver: the system's alert would sit over the
        // app and take the focus a scripted test gives the terminal.
        if ProcessInfo.processInfo.environment["VERTTY_DEBUG"] != "1" { store.askForNotifications() }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        statusWatch = nil
        store?.close()
        store = nil
    }
}

struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        if let store = app.store {
            RemoteWorkspace(store: store, onDisconnect: { app.disconnect() }) { id in
                TerminalScreen(cardID: id, store: store)
                    .id(id)
                    .ignoresSafeArea(.keyboard)
            }
        } else {
            NavigationStack {
                RemoteConnectView(address: $app.address,
                                  connectAddress: { app.connect($0) },
                                  connectComputer: { app.connect($0) })
                    .navigationTitle("Vertty")
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        keepRemoteLog()
        #if DEBUG
            DebugDriver.shared.start()
        #endif
        return true
    }

    /// RemoteLog's lines in Documents/remote-size.log, started over past 1 MB.
    private func keepRemoteLog() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-size.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1 << 20 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        let queue = DispatchQueue(label: "vertty.remote-log")
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        RemoteLog.sink = { line in
            let stamped = "\(format.string(from: Date())) \(line)\n"
            queue.async { handle.write(Data(stamped.utf8)) }
        }
        RemoteLog.note("app: started")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let card = response.notification.request.content.userInfo["remoteCard"] as? String,
              let store = AppModel.shared.store, let id = UUID(uuidString: card) else { return }
        store.selectedCardID = id
    }
}
