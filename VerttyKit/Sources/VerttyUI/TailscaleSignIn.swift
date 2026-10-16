import AuthenticationServices
import Combine
import VerttyTailnet
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Signs this device in to Tailscale in the system's web sign-in window
/// (ASWebAuthenticationSession): a window of its own on the Mac, a sheet in
/// the app on iOS, sharing Safari's logins. Tailscale doesn't send the page
/// back to the app when it's done, so the window is closed once the device
/// is signed in.
public final class TailscaleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = TailscaleSignIn()

    private var session: ASWebAuthenticationSession?
    private var watch: AnyCancellable?

    /// Opens the sign-in page (again, if it's open). The device must be
    /// in use (Tailnet.use()).
    public func start() {
        Tailnet.shared.login { [weak self] url in self?.open(url) }
    }

    private func open(_ url: URL) {
        close()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            // Closed by the user, or by close().
            DispatchQueue.main.async { self?.ended() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        watch = Tailnet.shared.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if state == .running { self?.close() }
        }
        session.start()
    }

    private func close() {
        session?.cancel()
        ended()
    }

    private func ended() {
        session = nil
        watch = nil
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
