// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyVTIncludeDirectory = "\(packageDirectory)/.local/ghosttyvt/include"

let package = Package(
    name: "spaces",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "systembridge", targets: ["systembridge"]),
        .library(name: "spacesdatabase", targets: ["spacesdatabase"]),
        .library(name: "spacesterminalcore", targets: ["spacesterminalcore"]),
        .library(name: "spacesterminalghostty", targets: ["spacesterminalghostty"]),
        .library(name: "spacesterminalmobileghostty", targets: ["spacesterminalmobileghostty"]),
        .library(name: "spacesterminalui", targets: ["spacesterminalui"]),
        .library(name: "spacesmobilecore", targets: ["spacesmobilecore"]),
        .library(name: "spacesmobilebridge", targets: ["spacesmobilebridge"]),
        .library(name: "workspacecore", targets: ["workspacecore"]),
        .library(name: "spacesui", targets: ["spacesui"]),
        .library(name: "spacescli", targets: ["spacescli"]),
        .executable(name: "spacese2e", targets: ["spacese2e"]),
        .executable(name: "SpacesTerminalService", targets: ["SpacesTerminalService"]),
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
        .target(
            name: "ghosttyvtshim",
            cSettings: [
                .unsafeFlags(["-I", ghosttyVTIncludeDirectory])
            ]
        ),
        .target(
            name: "spacesdatabase",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "systembridge"),
        .target(name: "spacesterminalcore", dependencies: ["spacesdatabase", "ghosttyvtshim"]),
        .target(name: "spacesmobilecore", dependencies: ["spacesterminalcore"]),
        .target(
            name: "spacesmobilebridge",
            dependencies: ["spacesmobilecore", "workspacecore", "spacesterminalcore"]
        ),
        .target(
            name: "spacesterminalghostty",
            dependencies: ["spacesterminalcore", "ghosttyvtshim", "GhosttyKit"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "spacesterminalmobileghostty",
            dependencies: ["spacesterminalcore", "GhosttyKit"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "spacesterminalui",
            dependencies: ["spacesterminalcore", "spacesterminalghostty"]
        ),
        .target(
            name: "workspacecore",
            dependencies: ["spacesdatabase", "systembridge", "spacesterminalcore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "spacesui",
            dependencies: [
                "workspacecore",
                "systembridge",
                "spacesmobilebridge",
                "spacesterminalui",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .target(
            name: "spacescli",
            dependencies: [
                "spacesmobilebridge",
                "spacesmobilecore",
                "workspacecore",
                "spacesterminalcore",
                "spacesterminalghostty",
                "systembridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "spacese2e",
            dependencies: [
                "workspacecore",
                "systembridge",
                "spacesmobilebridge",
                "spacesmobilecore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/spacese2e"
        ),
        .executableTarget(
            name: "SpacesTerminalService",
            dependencies: ["spacesterminalcore", "spacesterminalghostty", "spacesmobilebridge"],
            path: "Sources/SpacesTerminalService"
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
        .testTarget(name: "spacesterminaluiTests", dependencies: ["spacesterminalui"]),
        .testTarget(name: "workspacecoreTests", dependencies: ["workspacecore", "spacesdatabase", "systembridge", "spacesterminalcore"]),
        .testTarget(name: "spacesuiTests", dependencies: ["spacesui"]),
        .testTarget(
            name: "spacescliTests",
            dependencies: [
                "spacescli",
                "spacesmobilebridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
