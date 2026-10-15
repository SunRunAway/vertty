import Combine
import SwiftUI
import UserNotifications
import VhosttyRemote
import VhosttyUI

@main
struct VhosttyRemoteApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, phase in
            guard let store = app.store else { return }
            switch phase {
            case .active:
                // Back in the foreground: reconnect after an ordinary drop, and
                // the open terminal takes the iPhone's size again.
                store.client.reconnectsAutomatically = true
                store.viewportChanged(force: true)
            case .background:
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
    /// The connection's token while connected; the app connects again with
    /// it when it starts. Gone once the user disconnects or another device
    /// takes over, so the app then starts on the address screen.
    static let tokenKey = "RemoteConnectionToken"

    @Published private(set) var store: RemoteStore?
    @Published var address = UserDefaults.standard.string(forKey: addressKey) ?? ""
    private var statusWatch: AnyCancellable?

    private init() {
        if let token = UserDefaults.standard.string(forKey: Self.tokenKey) {
            _ = connect(resuming: token)
        }
    }

    /// Connects to `address`; false if it isn't one.
    func connect() -> Bool {
        connect(resuming: nil)
    }

    private func connect(resuming token: String?) -> Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = remoteURL(from: text) else { return false }
        UserDefaults.standard.set(text, forKey: Self.addressKey)
        store?.close()
        let store = RemoteStore(url: url, platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone,
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
        if ProcessInfo.processInfo.environment["VHOSTTY_DEBUG"] != "1" { store.askForNotifications() }
        return true
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
            ConnectView(app: app)
        }
    }
}

/// Where the address is entered (the Mac asks in a dialog instead).
struct ConnectView: View {
    @ObservedObject var app: AppModel
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.5:58563", text: $app.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Computer")
                } footer: {
                    Text("The address shown in Remote Connection Info in Vhostty on your computer. The connection's security is up to you (for example a VPN).")
                }
                Section {
                    Button("Connect", action: connect)
                        .disabled(app.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Vhostty")
            .alert("That isn't an address Vhostty can connect to.", isPresented: $invalid) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a host and port, such as 192.168.1.5:58563 or mac.local:58563.")
            }
        }
    }

    private func connect() {
        if !app.connect() { invalid = true }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
            DebugDriver.shared.start()
        #endif
        return true
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
