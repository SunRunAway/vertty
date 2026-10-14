// swift-tools-version:5.10
import PackageDescription

/// What the iPhone app and the desktop remote client share: the generated
/// protocol messages and the client connection.
let package = Package(
    name: "VhosttyRemote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VhosttyRemote", targets: ["VhosttyRemote"]),
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
