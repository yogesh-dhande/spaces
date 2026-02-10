// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "agentmux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "appctl", targets: ["appctl"]),
        .library(name: "streamctl", targets: ["streamctl"]),
        .library(name: "gui", targets: ["gui"]),
        .executable(name: "agentmux", targets: ["agentmux"]),
        .executable(name: "agentmux-gui", targets: ["agentmux-gui"])
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
        .executableTarget(name: "agentmux", dependencies: ["streamctl", "appctl"]),
        .executableTarget(name: "agentmux-gui", dependencies: ["gui"]),
        .testTarget(name: "streamctlTests", dependencies: ["streamctl"])
    ]
)
