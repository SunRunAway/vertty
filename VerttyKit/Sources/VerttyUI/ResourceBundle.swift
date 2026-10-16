import Foundation

extension Bundle {
    // SwiftPM's native backend searches the app root, while swiftbuild searches
    // Contents/Resources. Packaged apps always use the latter; only command-line
    // tools and tests should fall back to SwiftPM's build-directory lookup.
    static let verttyUIResources: Bundle = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .module }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("VerttyKit_VerttyUI.bundle"),
              let bundle = Bundle(url: url) else {
            fatalError("Missing VerttyKit_VerttyUI.bundle in app resources")
        }
        return bundle
    }()
}
