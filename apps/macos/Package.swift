// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyVTIncludeDirectory = "\(packageDirectory)/.local/ghosttyvt/include"

#if os(Linux)
let systemLibraryTargets: [Target] = [
    .systemLibrary(name: "CSQLite3", pkgConfig: "sqlite3"),
    .systemLibrary(name: "OpenSSL", pkgConfig: "openssl"),
]
let ghosttyKitSupportTargets: [Target] = []
let ghosttyKitTargetDependencies: [Target.Dependency] = []
let mobileGhosttyTargets: [Target] = []
let mobileGhosttyProducts: [Product] = []
let spacesDatabaseExtraDependencies: [Target.Dependency] = [.target(name: "CSQLite3")]
let spacesTerminalCoreExtraDependencies: [Target.Dependency] = [.target(name: "OpenSSL")]
let spacesTerminalCoreExtraLinkerSettings: [LinkerSetting] = [.linkedLibrary("ssl"), .linkedLibrary("crypto")]
let workspaceCoreExtraDependencies: [Target.Dependency] = [.target(name: "CSQLite3")]
let spacesDeviceAPIExtraDependencies: [Target.Dependency] = [.target(name: "OpenSSL")]
#else
let systemLibraryTargets: [Target] = []
let ghosttyKitSupportTargets: [Target] = [
    .binaryTarget(
        name: "GhosttyKit",
        path: ".local/ghosttykit/GhosttyKit.xcframework"
    )
]
let ghosttyKitTargetDependencies: [Target.Dependency] = [
    .target(name: "GhosttyKit", condition: .when(platforms: [.macOS]))
]
let mobileGhosttyTargets: [Target] = [
    .target(
        name: "spacesterminalmobileghostty",
        dependencies: ["spacesterminalcore", "GhosttyKit"],
        linkerSettings: [.linkedLibrary("c++", .when(platforms: [.iOS, .macOS]))]
    )
]
let mobileGhosttyProducts: [Product] = [
    .library(name: "spacesterminalmobileghostty", targets: ["spacesterminalmobileghostty"])
]
let spacesDatabaseExtraDependencies: [Target.Dependency] = []
let spacesTerminalCoreExtraDependencies: [Target.Dependency] = []
let spacesTerminalCoreExtraLinkerSettings: [LinkerSetting] = []
let workspaceCoreExtraDependencies: [Target.Dependency] = []
let spacesDeviceAPIExtraDependencies: [Target.Dependency] = []
#endif

let supportTargets: [Target] = ghosttyKitSupportTargets + [
    .target(
        name: "ghosttyvtshim",
        cSettings: [
            .unsafeFlags(["-I", ghosttyVTIncludeDirectory])
        ]
    ),
    .target(
        name: "spacesdatabase",
        dependencies: spacesDatabaseExtraDependencies,
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(name: "systembridge"),
    .target(name: "spacesruntimecore"),
]

let terminalTargets: [Target] = [
    .target(
        name: "spacesterminalcore",
        dependencies: [
            "spacesdatabase",
            "ghosttyvtshim",
        ] + spacesTerminalCoreExtraDependencies,
        linkerSettings: spacesTerminalCoreExtraLinkerSettings
    ),
    .target(name: "spacesdevicecore", dependencies: ["spacesterminalcore"]),
    .target(
        name: "spacesdeviceapi",
        dependencies: ["spacesdevicecore", "workspacecore", "spacesterminalcore"] + spacesDeviceAPIExtraDependencies
    ),
    .target(
        name: "spacesclientcore",
        dependencies: [
            "spacesdatabase",
            "spacesterminalcore",
            "spacesdevicecore",
            "spacesdeviceapi",
            "systembridge",
        ]
    ),
    .target(
        name: "spacesterminalghostty",
        dependencies: [
            "spacesterminalcore",
            "ghosttyvtshim",
        ] + ghosttyKitTargetDependencies,
        linkerSettings: [.linkedLibrary("c++", .when(platforms: [.macOS])), .linkedLibrary("util", .when(platforms: [.linux]))]
    ),
    .target(
        name: "spacesterminalui",
        dependencies: ["spacesterminalcore", "spacesterminalghostty"]
    ),
] + mobileGhosttyTargets

let appTargets: [Target] = [
    .target(
        name: "workspacecore",
        dependencies: [
            "spacesdatabase",
            "systembridge",
            "spacesterminalcore",
            "spacesdevicecore",
        ] + workspaceCoreExtraDependencies + [
            .product(name: "Yams", package: "Yams"),
        ],
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
        name: "spacesui",
        dependencies: [
            "workspacecore",
            "systembridge",
            "spacesdeviceapi",
            "spacesclientcore",
            "spacesterminalui",
            .product(name: "Sparkle", package: "Sparkle"),
        ]
    ),
    .target(
        name: "spacescli",
        dependencies: [
            "workspacecore",
            "spacesterminalcore",
            "spacesterminalghostty",
            "systembridge",
            "spacesclientcore",
            "spacesdeviceapi",
            "spacesdevicecore",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]
    ),
]

let executableTargets: [Target] = [
    .executableTarget(
        name: "spacese2e",
        dependencies: [
            "workspacecore",
            "systembridge",
            "spacesclientcore",
            "spacesdeviceapi",
            "spacesdevicecore",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ],
        path: "Sources/spacese2e"
    ),
    .executableTarget(
        name: "spacesd",
        dependencies: [
            "workspacecore",
            "spacesterminalcore",
            "spacesterminalghostty",
            "spacesdevicecore",
            "spacesruntimecore",
            "spacesdeviceapi",
        ],
        path: "Sources/spacesd"
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
]

let testTargets: [Target] = [
    .testTarget(name: "spacesterminalcoreTests", dependencies: ["spacesterminalcore"]),
    .testTarget(name: "spacesterminalghosttyTests", dependencies: ["spacesterminalghostty"]),
    .testTarget(name: "spacesruntimecoreTests", dependencies: ["spacesruntimecore"]),
    .testTarget(name: "spacesdTests", dependencies: ["spacesd", "spacesterminalcore"]),
    .testTarget(name: "spacesterminaluiTests", dependencies: ["spacesterminalui"]),
    .testTarget(name: "workspacecoreTests", dependencies: ["workspacecore", "spacesdatabase", "systembridge", "spacesterminalcore"]),
    .testTarget(name: "spacesclientcoreTests", dependencies: ["spacesclientcore"]),
    .testTarget(name: "spacesdeviceapiTests", dependencies: ["spacesdeviceapi"]),
    .testTarget(name: "spacesuiTests", dependencies: ["spacesui"]),
    .testTarget(
        name: "spacescliTests",
        dependencies: [
            "spacescli",
            "spacesdeviceapi",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]
    )
]

let packageTargets: [Target] = systemLibraryTargets + supportTargets + terminalTargets + appTargets + executableTargets + testTargets

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
        .library(name: "spacesterminalui", targets: ["spacesterminalui"]),
        .library(name: "spacesdevicecore", targets: ["spacesdevicecore"]),
        .library(name: "spacesdeviceapi", targets: ["spacesdeviceapi"]),
        .library(name: "spacesclientcore", targets: ["spacesclientcore"]),
        .library(name: "spacesruntimecore", targets: ["spacesruntimecore"]),
        .library(name: "workspacecore", targets: ["workspacecore"]),
        .library(name: "spacesui", targets: ["spacesui"]),
        .library(name: "spacescli", targets: ["spacescli"]),
        .executable(name: "spacese2e", targets: ["spacese2e"]),
        .executable(name: "spacesd", targets: ["spacesd"]),
        .executable(name: "spaces", targets: ["spaces"]),
        .executable(name: "SpacesApp", targets: ["SpacesApp"])
    ] + mobileGhosttyProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: packageTargets
)
