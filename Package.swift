// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Vhostty",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GhosttyC",
            path: "Sources/GhosttyC"
        ),
        .executableTarget(
            name: "Vhostty",
            dependencies: ["GhosttyC"],
            path: "Sources/Vhostty",
            linkerSettings: [
                .unsafeFlags(["-L", "build/ghostty/lib"]),
                .linkedLibrary("ghostty"),
                .linkedLibrary("c++"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "vhostty-hook",
            path: "Sources/VhosttyHook"
        ),
        .executableTarget(
            name: "vhostty-schedule",
            path: "Sources/VhosttySchedule"
        ),
    ]
)
