import Foundation

extension Bundle {
    // SwiftPM's native backend searches the app root, while swiftbuild searches
    // Contents/Resources. Packaged apps always use the latter; only command-line
    // tools and tests should fall back to SwiftPM's build-directory lookup.
    static let verttyRemoteResources: Bundle = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .module }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("VerttyKit_VerttyRemote.bundle"),
              let bundle = Bundle(url: url) else {
            fatalError("Missing VerttyKit_VerttyRemote.bundle in app resources")
        }
        return bundle
    }()
}
