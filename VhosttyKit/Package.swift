// swift-tools-version:5.10
import PackageDescription

/// The code every Vhostty app shares (Mac, iPhone, iPad): the remote
/// protocol and its client (VhosttyRemote), and the sidebar and session UI
/// with the models behind it (VhosttyUI).
let package = Package(
    name: "VhosttyKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VhosttyRemote", targets: ["VhosttyRemote"]),
        .library(name: "VhosttyUI", targets: ["VhosttyUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.28.2"),
    ],
    targets: [
        .target(
            name: "VhosttyRemote",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/VhosttyRemote",
            resources: [.process("Resources")]
        ),
        .target(
            name: "VhosttyUI",
            dependencies: ["VhosttyRemote"],
            path: "Sources/VhosttyUI",
            resources: [.process("Resources")]
        ),
        // Test client for scripts/test-remote.py; not shipped.
        .executableTarget(
            name: "remote-probe",
            dependencies: ["VhosttyRemote"],
            path: "Sources/RemoteProbe"
        ),
        .testTarget(
            name: "VhosttyRemoteTests",
            dependencies: ["VhosttyRemote"],
            path: "Tests/VhosttyRemoteTests"
        ),
    ]
)
