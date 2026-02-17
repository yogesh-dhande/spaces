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
        .executable(name: "mx", targets: ["mx"]),
        .executable(name: "Muxy", targets: ["Muxy"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
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
        .executableTarget(name: "mx", dependencies: ["streamctl", "appctl"]),
        .executableTarget(
            name: "Muxy",
            dependencies: [
                "gui",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Info.plist"],
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
        .testTarget(name: "guiTests", dependencies: ["gui"])
    ]
)
