// swift-tools-version: 6.2
import PackageDescription

// Vendored from libghostty-spm (MIT, see LICENSE and VHOSTTY.md): the
// GhosttyKit binary and its UIKit terminal view, with the changes the
// Vhostty iPhone client needs.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "GhosttyTerminal",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/DisplayLink.git", exact: "3.0.1"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "DisplayLink"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
                .process("Resources/Localization"),
            ],
            swiftSettings: swiftSettings
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1e9e14af5df1-2/GhosttyKit.xcframework.zip",
            checksum: "188b21d3c3f4f0a19fd71d7f3e6c6edc0e8e30fe04e09181d3db44810e21bf5f"
        ),
    ],
    swiftLanguageModes: [.v6]
)
