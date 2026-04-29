// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "muxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "appctl", targets: ["appctl"]),
        .library(name: "streamctl", targets: ["streamctl"]),
        .library(name: "gui", targets: ["gui"]),
        .library(name: "mxcli", targets: ["mxcli"]),
        .executable(name: "muxye2e", targets: ["muxye2e"]),
        .executable(name: "muxy", targets: ["muxycli"]),
        .executable(name: "MuxyApp", targets: ["MuxyApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "appctl"),
        .target(
            name: "streamctl",
            dependencies: ["appctl"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "gui", dependencies: ["streamctl", "appctl"]),
        .target(
            name: "mxcli",
            dependencies: [
                "streamctl",
                "appctl",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "muxye2e",
            dependencies: [
                "streamctl",
                "appctl",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/muxye2e"
        ),
        .executableTarget(name: "muxycli", dependencies: ["mxcli"], path: "Sources/muxycli"),
        .executableTarget(
            name: "MuxyApp",
            dependencies: ["gui"],
            path: "Sources/MuxyApp",
            exclude: ["Info.plist"],
            resources: [.copy("AppIcon.icns")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MuxyApp/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(name: "streamctlTests", dependencies: ["streamctl", "appctl"]),
        .testTarget(name: "guiTests", dependencies: ["gui"]),
        .testTarget(
            name: "mxcliTests",
            dependencies: [
                "mxcli",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
