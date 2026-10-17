// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Vertty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "VerttyKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "GhosttyC",
            path: "Sources/GhosttyC"
        ),
        .executableTarget(
            name: "Vertty",
            dependencies: [
                "GhosttyC",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "VerttyRemote", package: "VerttyKit"),
                .product(name: "VerttyTailnet", package: "VerttyKit"),
                .product(name: "VerttyUI", package: "VerttyKit"),
            ],
            path: "Sources/Vertty",
            linkerSettings: [
                .unsafeFlags(["-L", "build/ghostty/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
        .executableTarget(name: "vertty-sleep", path: "Sources/VerttySleep"),
        .executableTarget(
            name: "vertty-hook",
            path: "Sources/VerttyHook"
        ),
        .executableTarget(
            name: "vertty-schedule",
            path: "Sources/VerttySchedule"
        ),
    ]
)
