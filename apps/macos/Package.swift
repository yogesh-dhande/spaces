// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "spaces",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "systembridge", targets: ["systembridge"]),
        .library(name: "spacesterminalcore", targets: ["spacesterminalcore"]),
        .library(name: "spacesterminalghostty", targets: ["spacesterminalghostty"]),
        .library(name: "spacesterminalruntime", targets: ["spacesterminalruntime"]),
        .library(name: "spacesterminalui", targets: ["spacesterminalui"]),
        .library(name: "workspacecore", targets: ["workspacecore"]),
        .library(name: "spacesui", targets: ["spacesui"]),
        .library(name: "spacescli", targets: ["spacescli"]),
        .executable(name: "spacese2e", targets: ["spacese2e"]),
        .executable(name: "spaces", targets: ["spaces"]),
        .executable(name: "SpacesApp", targets: ["SpacesApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: ".local/ghosttykit/GhosttyKit.xcframework"
        ),
        .target(name: "systembridge"),
        .target(name: "spacesterminalcore"),
        .target(
            name: "spacesterminalghostty",
            dependencies: ["spacesterminalcore", "GhosttyKit"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "spacesterminalruntime",
            dependencies: ["spacesterminalcore", "spacesterminalghostty"]
        ),
        .target(
            name: "spacesterminalui",
            dependencies: ["spacesterminalcore", "spacesterminalghostty"]
        ),
        .target(
            name: "workspacecore",
            dependencies: ["systembridge", "spacesterminalcore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "spacesui",
            dependencies: [
                "workspacecore",
                "systembridge",
                "spacesterminalui",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .target(
            name: "spacescli",
            dependencies: [
                "workspacecore",
                "spacesterminalcore",
                "spacesterminalruntime",
                "systembridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "spacese2e",
            dependencies: [
                "workspacecore",
                "systembridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/spacese2e"
        ),
        .executableTarget(name: "spaces", dependencies: ["spacescli"], path: "Sources/spaces"),
        .executableTarget(
            name: "SpacesApp",
            dependencies: ["spacesui"],
            path: "Sources/SpacesApp",
            exclude: ["Info.plist"],
            resources: [.copy("AppIcon.icns")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SpacesApp/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(name: "spacesterminalcoreTests", dependencies: ["spacesterminalcore"]),
        .testTarget(name: "spacesterminalghosttyTests", dependencies: ["spacesterminalghostty"]),
        .testTarget(name: "spacesterminalruntimeTests", dependencies: ["spacesterminalruntime"]),
        .testTarget(name: "spacesterminaluiTests", dependencies: ["spacesterminalui"]),
        .testTarget(name: "workspacecoreTests", dependencies: ["workspacecore", "systembridge"]),
        .testTarget(name: "spacesuiTests", dependencies: ["spacesui"]),
        .testTarget(
            name: "spacescliTests",
            dependencies: [
                "spacescli",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
