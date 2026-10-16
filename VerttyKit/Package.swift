// swift-tools-version:5.10
import PackageDescription

/// The code every Vertty app shares (Mac, iPhone, iPad): the remote
/// protocol and its client (VerttyRemote), and the sidebar and session UI
/// with the models behind it (VerttyUI).
let package = Package(
    name: "VerttyKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VerttyRemote", targets: ["VerttyRemote"]),
        .library(name: "VerttyUI", targets: ["VerttyUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.28.2"),
    ],
    targets: [
        .target(
            name: "VerttyRemote",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/VerttyRemote",
            resources: [.process("Resources")]
        ),
        .target(
            name: "VerttyUI",
            dependencies: ["VerttyRemote"],
            path: "Sources/VerttyUI",
            resources: [.process("Resources")]
        ),
        // Test client for scripts/test-remote.py; not shipped.
        .executableTarget(
            name: "remote-probe",
            dependencies: ["VerttyRemote"],
            path: "Sources/RemoteProbe"
        ),
        .testTarget(
            name: "VerttyRemoteTests",
            dependencies: ["VerttyRemote"],
            path: "Tests/VerttyRemoteTests"
        ),
    ]
)
