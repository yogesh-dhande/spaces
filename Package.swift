// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "agentmux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "winmove", targets: ["winmove"]),
        .library(name: "appctl", targets: ["appctl"]),
        .library(name: "streamctl", targets: ["streamctl"]),
        .library(name: "gui", targets: ["gui"]),
        .executable(name: "agentmux", targets: ["agentmux"]),
        .executable(name: "agentmux-gui", targets: ["agentmux-gui"])
    ],
    targets: [
        .target(name: "winmove"),
        .target(name: "appctl", dependencies: ["winmove"]),
        .target(
            name: "streamctl",
            dependencies: ["winmove", "appctl"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "gui", dependencies: ["streamctl"]),
        .executableTarget(name: "agentmux", dependencies: ["streamctl"]),
        .executableTarget(name: "agentmux-gui", dependencies: ["gui"])
    ]
)
