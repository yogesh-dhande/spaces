// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "spaceship",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "appctl", targets: ["appctl"]),
        .library(name: "streamctl", targets: ["streamctl"]),
        .library(name: "gui", targets: ["gui"]),
        .executable(name: "spaceship", targets: ["spaceship"]),
        .executable(name: "SpaceshipApp", targets: ["SpaceshipApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(name: "appctl"),
        .target(
            name: "streamctl",
            dependencies: [
                "appctl",
                .product(name: "Yams", package: "Yams")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "gui", dependencies: ["streamctl"]),
        .executableTarget(name: "spaceship", dependencies: ["streamctl", "appctl"]),
        .executableTarget(
            name: "SpaceshipApp",
            dependencies: ["gui"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SpaceshipApp/Info.plist"
                ])
            ]
        ),
        .testTarget(name: "streamctlTests", dependencies: ["streamctl", "appctl"]),
        .testTarget(name: "guiTests", dependencies: ["gui"])
    ]
)
