import SwiftUI
import UserNotifications
import VhosttyRemote

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
            switch phase {
            case .active: app.session?.cameToForeground()
            case .background: app.session?.wentToBackground()
            default: break
            }
        }
    }
}

/// The computer the app is connected to, if any.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let addressKey = "RemoteAddress"

    @Published private(set) var session: RemoteSession?
    @Published var address = UserDefaults.standard.string(forKey: addressKey) ?? ""

    /// Connects to `address`; false if it isn't one.
    func connect() -> Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = remoteURL(from: text) else { return false }
        UserDefaults.standard.set(text, forKey: Self.addressKey)
        session?.client.disconnect()
        let session = RemoteSession(url: url)
        self.session = session
        session.client.connect()
        session.askForNotifications()
        #if DEBUG
            DebugDriver.shared.attach(session)
        #endif
        return true
    }

    func disconnect() {
        session?.client.disconnect()
        session = nil
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
        guard let card = response.notification.request.content.userInfo["card"] as? String else { return }
        AppModel.shared.session?.open(card)
    }
}
