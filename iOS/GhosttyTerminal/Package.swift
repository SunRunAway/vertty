// swift-tools-version: 6.2
import PackageDescription

// Vendored from libghostty-spm (MIT, see LICENSE and VHOSTTY.md): its UIKit
// terminal view, with the changes the Vhostty iOS client needs, on a
// GhosttyKit built from the same Ghostty as the Mac app.
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
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
                .process("Resources/Localization"),
            ],
            swiftSettings: swiftSettings
        ),
        // Built from vendor/ghostty and Vhostty's patch, like the Mac app's
        // libghostty: scripts/build-ghostty-ios.sh.
        .binaryTarget(name: "libghostty", path: "GhosttyKit.xcframework"),
    ],
    swiftLanguageModes: [.v6]
)
