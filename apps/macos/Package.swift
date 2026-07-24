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
// The Linux package graph is exactly what the daemon artifact ships (spacesd + spaces CLI and
// their libraries) plus the two daemon-side test targets. AppKit/SwiftUI client targets are not
// declared at all: `swift test` builds every declared target, so a declared-but-unbuildable
// client target would break the Linux test lane even though no test depends on it.
let terminalUITargets: [Target] = []
let macAppTargets: [Target] = []
let macExecutableTargets: [Target] = []
let macOnlyProducts: [Product] = []
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
let terminalUITargets: [Target] = [
    .target(
        name: "spacesterminalui",
        dependencies: ["spacesterminalcore", "spacesterminalghostty"]
    )
]
let macAppTargets: [Target] = [
    .target(
        name: "spacesui",
        dependencies: [
            "workspacecore",
            "systembridge",
            "spacesdeviceapi",
            "spacesclientcore",
            "spacesterminalcore",
            "spacesterminalui",
            .product(name: "Sparkle", package: "Sparkle"),
        ]
    )
]
let macExecutableTargets: [Target] = [
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
        name: "SpacesApp",
        dependencies: ["spacesui", "spacesterminalcore"],
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
let macOnlyProducts: [Product] = [
    .library(name: "spacesterminalui", targets: ["spacesterminalui"]),
    .library(name: "spacesui", targets: ["spacesui"]),
    .executable(name: "spacese2e", targets: ["spacese2e"]),
    .executable(name: "SpacesApp", targets: ["SpacesApp"])
]
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

let baseTerminalTargets: [Target] = [
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
            "spacesdevicecore",
            "ghosttyvtshim",
        ] + ghosttyKitTargetDependencies,
        linkerSettings: [.linkedLibrary("c++", .when(platforms: [.macOS])), .linkedLibrary("util", .when(platforms: [.linux]))]
    ),
]
let terminalTargets: [Target] = baseTerminalTargets + terminalUITargets + mobileGhosttyTargets

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
] + macAppTargets

let executableTargets: [Target] = [
    .executableTarget(
        name: "spacesd",
        dependencies: [
            "workspacecore",
            "spacesterminalcore",
            "spacesterminalghostty",
            "spacesdevicecore",
            "spacesruntimecore",
            "spacesdeviceapi",
            "spacesclientcore",
        ],
        path: "Sources/spacesd"
    ),
    .executableTarget(name: "spaces", dependencies: ["spacescli"], path: "Sources/spaces"),
] + macExecutableTargets

// On Linux only the daemon-side test targets exist: the others exercise AppKit/SwiftUI/Carbon
// client code that does not build there. This is what lets the Docker lane run the
// `#if os(Linux)` suites (headless terminal core, handoff, resize) with `swift test`.
#if os(Linux)
    let testTargets: [Target] = [
        .testTarget(name: "spacesterminalcoreTests", dependencies: ["spacesterminalcore", "ghosttyvtshim"]),
        .testTarget(name: "spacesterminalghosttyTests", dependencies: ["spacesterminalghostty"]),
    ]
#else
    let testTargets: [Target] = [
        .testTarget(name: "spacesterminalcoreTests", dependencies: ["spacesterminalcore", "ghosttyvtshim"]),
        .testTarget(name: "spacesterminalghosttyTests", dependencies: ["spacesterminalghostty"]),
        .testTarget(name: "spacesruntimecoreTests", dependencies: ["spacesruntimecore"]),
        .testTarget(name: "spacesdTests", dependencies: ["spacesd", "spacesterminalcore"]),
        .testTarget(name: "spacesterminaluiTests", dependencies: ["spacesterminalui"]),
        .testTarget(name: "workspacecoreTests", dependencies: ["workspacecore", "spacesdatabase", "systembridge", "spacesterminalcore"]),
        .testTarget(name: "spacesclientcoreTests", dependencies: ["spacesclientcore"]),
        .testTarget(name: "spacesdeviceapiTests", dependencies: ["spacesdeviceapi", "spacesdevicecore", "spacesterminalcore"]),
        .testTarget(name: "spacesuiTests", dependencies: ["spacesui", "spacesclientcore"]),
        .testTarget(
            name: "spacescliTests",
            dependencies: [
                "spacescli",
                "spacesclientcore",
                "spacesdeviceapi",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
#endif

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
        .library(name: "spacesdevicecore", targets: ["spacesdevicecore"]),
        .library(name: "spacesdeviceapi", targets: ["spacesdeviceapi"]),
        .library(name: "spacesclientcore", targets: ["spacesclientcore"]),
        .library(name: "spacesruntimecore", targets: ["spacesruntimecore"]),
        .library(name: "workspacecore", targets: ["workspacecore"]),
        .library(name: "spacescli", targets: ["spacescli"]),
        .executable(name: "spacesd", targets: ["spacesd"]),
        .executable(name: "spaces", targets: ["spaces"])
    ] + macOnlyProducts + mobileGhosttyProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: packageTargets
)
