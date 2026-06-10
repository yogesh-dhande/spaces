import Foundation
import spacesterminalcore
import workspacecore

struct SpacesAppExecutableResolution: Equatable {
    let executableURL: URL
    let attemptedCandidates: [String]
}

struct SpacesAppExecutableResolver {
    private let homeDirectoryURL: URL
    private let isExecutableFile: (String) -> Bool

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutableFile: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.isExecutableFile = isExecutableFile
    }

    func candidatePaths(serviceExecutablePath: String) -> [String] {
        let serviceExecutableURL = URL(fileURLWithPath: (serviceExecutablePath as NSString).expandingTildeInPath).standardizedFileURL
        let serviceDirectory = serviceExecutableURL.deletingLastPathComponent()
        var candidates = [serviceDirectory.appendingPathComponent("SpacesApp", isDirectory: false).path]

        let contentsDirectory = serviceDirectory.deletingLastPathComponent()
        let appBundleURL = contentsDirectory.deletingLastPathComponent()
        if serviceDirectory.lastPathComponent == "Resources", contentsDirectory.lastPathComponent == "Contents", appBundleURL.pathExtension == "app" {
            candidates.append(
                contentsDirectory.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent("SpacesApp", isDirectory: false).path)
        }

        switch serviceExecutableURL.path {
        case "/usr/local/bin/spacesd": candidates.append("/Applications/Spaces.app/Contents/MacOS/SpacesApp")
        case homeDirectoryURL.appendingPathComponent(".local/bin/spacesd", isDirectory: false).standardizedFileURL.path:
            candidates.append(
                homeDirectoryURL.appendingPathComponent("Applications/Spaces.app/Contents/MacOS/SpacesApp", isDirectory: false).standardizedFileURL
                    .path)
        default: break
        }

        return candidates.uniquedPreservingOrder()
    }

    func resolve(serviceExecutablePath: String) throws -> SpacesAppExecutableResolution {
        let candidates = candidatePaths(serviceExecutablePath: serviceExecutablePath)
        guard let executablePath = candidates.first(where: isExecutableFile) else {
            throw SpacesAppLaunchError.executableNotFound(candidates: candidates)
        }
        return SpacesAppExecutableResolution(executableURL: URL(fileURLWithPath: executablePath, isDirectory: false), attemptedCandidates: candidates)
    }
}

struct SpacesAppLaunchOutcome: Equatable {
    let message: String
    let launchedProcessID: Int32?
}

enum SpacesAppLaunchError: LocalizedError, Equatable {
    case serviceExecutableNotFound
    case executableNotFound(candidates: [String])
    case leaseNotAcquired(executablePath: String, timeoutSeconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .serviceExecutableNotFound: "Unable to resolve the running spacesd executable path."
        case .executableNotFound(let candidates): "Unable to find SpacesApp. Tried: \(candidates.joined(separator: ", "))"
        case .leaseNotAcquired(let executablePath, let timeoutSeconds):
            "SpacesApp launched from \(executablePath) but did not acquire the profile app-owner lease within \(Self.format(timeoutSeconds)) seconds."
        }
    }

    private static func format(_ value: TimeInterval) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

struct SpacesAppLauncher {
    private let resolver: SpacesAppExecutableResolver
    private let profileProvider: () throws -> SpacesProfile
    private let currentAppOwner: (SpacesProfile) throws -> SpacesProcessLeaseOwner?
    private let serviceExecutablePathProvider: () -> String?
    private let environmentProvider: () -> [String: String]
    private let startProcess: (URL, [String: String]) throws -> Int32
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date

    init(
        resolver: SpacesAppExecutableResolver = SpacesAppExecutableResolver(),
        profileProvider: @escaping () throws -> SpacesProfile = { try SpacesProfile.current() },
        currentAppOwner: @escaping (SpacesProfile) throws -> SpacesProcessLeaseOwner? = {
            try SpacesLeaseCoordinator.currentProfileAppOwner(profile: $0)
        },
        serviceExecutablePathProvider: @escaping () -> String? = {
            SpacesProfile.currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        }, environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        startProcess: @escaping (URL, [String: String]) throws -> Int32 = SpacesAppLauncher.startProcess,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, now: @escaping () -> Date = { Date() }
    ) {
        self.resolver = resolver
        self.profileProvider = profileProvider
        self.currentAppOwner = currentAppOwner
        self.serviceExecutablePathProvider = serviceExecutablePathProvider
        self.environmentProvider = environmentProvider
        self.startProcess = startProcess
        self.sleep = sleep
        self.now = now
    }

    func launchIfNeeded(timeoutSeconds: TimeInterval = 5, pollIntervalSeconds: TimeInterval = 0.05) throws -> SpacesAppLaunchOutcome {
        let profile = try profileProvider()
        if try currentAppOwner(profile) != nil { return SpacesAppLaunchOutcome(message: "Spaces is already running on Mac.", launchedProcessID: nil) }

        guard let serviceExecutablePath = normalizedString(serviceExecutablePathProvider()) else {
            throw SpacesAppLaunchError.serviceExecutableNotFound
        }
        let resolution = try resolver.resolve(serviceExecutablePath: serviceExecutablePath)
        let environment = launchEnvironment(profile: profile, serviceExecutablePath: serviceExecutablePath)
        let processID = try startProcess(resolution.executableURL, environment)

        let deadline = now().addingTimeInterval(timeoutSeconds)
        repeat {
            if try currentAppOwner(profile) != nil { return SpacesAppLaunchOutcome(message: "Launched Spaces on Mac.", launchedProcessID: processID) }
            sleep(pollIntervalSeconds)
        } while now() < deadline

        if try currentAppOwner(profile) != nil { return SpacesAppLaunchOutcome(message: "Launched Spaces on Mac.", launchedProcessID: processID) }
        throw SpacesAppLaunchError.leaseNotAcquired(executablePath: resolution.executableURL.path, timeoutSeconds: timeoutSeconds)
    }

    private func launchEnvironment(profile: SpacesProfile, serviceExecutablePath: String) -> [String: String] {
        var environment = environmentProvider()
        environment[SpacesProfile.databasePathEnvironmentVariable] = profile.databasePath
        environment[SpacesProfile.runtimeDirectoryEnvironmentVariable] = profile.runtimeDirectory
        environment["SPACESD_EXECUTABLE"] = serviceExecutablePath
        return environment
    }

    private static func startProcess(executableURL: URL, environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process.processIdentifier
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension Array where Element: Hashable {
    fileprivate func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
