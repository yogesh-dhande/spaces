// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mx",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "appctl", targets: ["appctl"]),
        .library(name: "streamctl", targets: ["streamctl"]),
        .library(name: "gui", targets: ["gui"]),
        .library(name: "mxcli", targets: ["mxcli"]),
        .executable(name: "mxe2e", targets: ["mxe2e"]),
        .executable(name: "mx", targets: ["mx"]),
        .executable(name: "Muxy", targets: ["Muxy"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
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
            name: "mxe2e",
            dependencies: [
                "streamctl",
                "appctl",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(name: "mx", dependencies: ["mxcli"]),
        .executableTarget(
            name: "Muxy",
            dependencies: [
                "gui",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Info.plist"],
            resources: [.copy("AppIcon.icns")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Muxy/Info.plist",
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
