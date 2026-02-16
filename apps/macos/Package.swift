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
        .executable(name: "muxy", targets: ["muxy"]),
        .executable(name: "MuxyApp", targets: ["MuxyApp"])
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
        .executableTarget(name: "muxy", dependencies: ["streamctl", "appctl"]),
        .executableTarget(
            name: "MuxyApp",
            dependencies: ["gui"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MuxyApp/Info.plist"
                ])
            ]
        ),
        .testTarget(name: "streamctlTests", dependencies: ["streamctl", "appctl"]),
        .testTarget(name: "guiTests", dependencies: ["gui"])
    ]
)
