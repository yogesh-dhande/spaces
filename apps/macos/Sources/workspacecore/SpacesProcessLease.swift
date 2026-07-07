import Foundation
import spacesterminalcore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public struct SpacesProcessLeaseOwner: Sendable, Codable, Equatable {
    public let pid: Int32
    public let executablePath: String
    public let profileRoot: String?
    public let token: String
    public let acquiredAt: String

    public init(pid: Int32, executablePath: String, profileRoot: String?, token: String, acquiredAt: String) {
        self.pid = pid
        self.executablePath = executablePath
        self.profileRoot = profileRoot
        self.token = token
        self.acquiredAt = acquiredAt
    }
}

public enum SpacesProcessLeaseAcquisitionResult {
    case acquired(SpacesProcessLease)
    case busy(SpacesProcessLeaseOwner)
}

public final class SpacesProcessLease: @unchecked Sendable {
    public let owner: SpacesProcessLeaseOwner
    public let leaseDirectoryPath: String

    private let fileManager: FileManager
    private let releaseLock = NSLock()
    private var didRelease = false

    init(owner: SpacesProcessLeaseOwner, leaseDirectoryPath: String, metadataPath _: String, fileManager: FileManager) {
        self.owner = owner
        self.leaseDirectoryPath = leaseDirectoryPath
        self.fileManager = fileManager
    }

    public func release() {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard !didRelease else { return }
        defer { didRelease = true }
        guard let currentOwner = (try? SpacesLeaseCoordinator.readOwner(fromLeaseDirectoryPath: leaseDirectoryPath, fileManager: fileManager)) ?? nil,
            currentOwner.token == owner.token
        else { return }
        try? fileManager.removeItem(atPath: leaseDirectoryPath)
    }

    deinit { release() }
}

public struct SpacesAppLaunchContext {
    public enum DesktopControlState {
        case active(SpacesProcessLease)
        case passive(SpacesProcessLeaseOwner)
    }

    public let profile: SpacesProfile
    public let appOwnerLease: SpacesProcessLease
    public let desktopControlState: DesktopControlState

    public init(profile: SpacesProfile, appOwnerLease: SpacesProcessLease, desktopControlState: DesktopControlState) {
        self.profile = profile
        self.appOwnerLease = appOwnerLease
        self.desktopControlState = desktopControlState
    }
}

public enum SpacesAppLaunchPreparationError: Error { case duplicateProfileOwner(profile: SpacesProfile, owner: SpacesProcessLeaseOwner) }

public enum SpacesLeaseCoordinator {
    private static let missingMetadataGraceSeconds: TimeInterval = 1
    private static let missingMetadataPollIntervalSeconds: TimeInterval = 0.05

    public static func prepareAppLaunchContext(profile: SpacesProfile? = nil, fileManager: FileManager = .default, homeDirectoryURL: URL? = nil)
        throws -> SpacesAppLaunchContext
    {
        let resolvedProfile: SpacesProfile
        if let profile { resolvedProfile = profile } else { resolvedProfile = try SpacesProfile.current() }
        switch try acquireProfileAppOwnerLease(profile: resolvedProfile, fileManager: fileManager) {
        case .busy(let owner): throw SpacesAppLaunchPreparationError.duplicateProfileOwner(profile: resolvedProfile, owner: owner)
        case .acquired(let appOwnerLease):
            switch try acquireDesktopControlLease(profile: resolvedProfile, fileManager: fileManager, homeDirectoryURL: homeDirectoryURL) {
            case .acquired(let desktopLease):
                return SpacesAppLaunchContext(profile: resolvedProfile, appOwnerLease: appOwnerLease, desktopControlState: .active(desktopLease))
            case .busy(let owner):
                return SpacesAppLaunchContext(profile: resolvedProfile, appOwnerLease: appOwnerLease, desktopControlState: .passive(owner))
            }
        }
    }

    public static func acquireProfileAppOwnerLease(profile: SpacesProfile, fileManager: FileManager = .default) throws
        -> SpacesProcessLeaseAcquisitionResult
    { try acquireLease(at: appOwnerLeaseDirectory(profileRoot: profile.rootDirectory), profileRoot: profile.rootDirectory, fileManager: fileManager) }

    public static func acquireDesktopControlLease(profile: SpacesProfile, fileManager: FileManager = .default, homeDirectoryURL: URL? = nil) throws
        -> SpacesProcessLeaseAcquisitionResult
    {
        try acquireLease(
            at: desktopControlLeaseDirectory(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager), profileRoot: profile.rootDirectory,
            fileManager: fileManager)
    }

    public static func currentProfileAppOwner(profile: SpacesProfile? = nil, fileManager: FileManager = .default) throws -> SpacesProcessLeaseOwner? {
        let resolvedProfile: SpacesProfile
        if let profile { resolvedProfile = profile } else { resolvedProfile = try SpacesProfile.current() }
        return try readLiveOwner(fromLeaseDirectoryPath: appOwnerLeaseDirectory(profileRoot: resolvedProfile.rootDirectory), fileManager: fileManager)
    }

    public static func currentDesktopControlOwner(fileManager: FileManager = .default, homeDirectoryURL: URL? = nil) throws
        -> SpacesProcessLeaseOwner?
    {
        try readLiveOwner(
            fromLeaseDirectoryPath: desktopControlLeaseDirectory(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager),
            fileManager: fileManager)
    }

    @discardableResult public static func waitForDesktopControlAvailability(
        timeoutSeconds: TimeInterval, pollIntervalSeconds: TimeInterval = 1, logIntervalSeconds: TimeInterval = 5,
        fileManager: FileManager = .default, homeDirectoryURL: URL? = nil, logger: (String) -> Void
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastLoggedOwnerToken: String?
        var lastLoggedAt = Date.distantPast

        while true {
            if let owner = try currentDesktopControlOwner(fileManager: fileManager, homeDirectoryURL: homeDirectoryURL) {
                let now = Date()
                if owner.token != lastLoggedOwnerToken || now.timeIntervalSince(lastLoggedAt) >= logIntervalSeconds {
                    logger("Desktop control busy: pid=\(owner.pid) executable=\(owner.executablePath) profile=\(owner.profileRoot ?? "unknown")")
                    lastLoggedOwnerToken = owner.token
                    lastLoggedAt = now
                }
                if now >= deadline { return false }
                Thread.sleep(forTimeInterval: pollIntervalSeconds)
                continue
            }
            return true
        }
    }

    static func readOwner(fromLeaseDirectoryPath leaseDirectoryPath: String, fileManager: FileManager = .default) throws -> SpacesProcessLeaseOwner? {
        let metadataPath = metadataPath(forLeaseDirectoryPath: leaseDirectoryPath)
        guard fileManager.fileExists(atPath: metadataPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
        return try JSONDecoder().decode(SpacesProcessLeaseOwner.self, from: data)
    }

    private static func acquireLease(at leaseDirectoryPath: String, profileRoot: String?, fileManager: FileManager) throws
        -> SpacesProcessLeaseAcquisitionResult
    {
        let leaseDirectoryURL = URL(fileURLWithPath: leaseDirectoryPath, isDirectory: true)
        try fileManager.createDirectory(at: leaseDirectoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        while true {
            do {
                try fileManager.createDirectory(at: leaseDirectoryURL, withIntermediateDirectories: false)
                let owner = currentProcessOwner(profileRoot: profileRoot)
                let metadataPath = metadataPath(forLeaseDirectoryPath: leaseDirectoryPath)
                let data = try JSONEncoder().encode(owner)
                try data.write(to: URL(fileURLWithPath: metadataPath), options: .atomic)
                return .acquired(
                    SpacesProcessLease(owner: owner, leaseDirectoryPath: leaseDirectoryPath, metadataPath: metadataPath, fileManager: fileManager))
            } catch {
                if !isFileExistsError(error) { throw error }
                if let existingOwner = try readLiveOwner(fromLeaseDirectoryPath: leaseDirectoryPath, fileManager: fileManager) {
                    return .busy(existingOwner)
                }
                try? fileManager.removeItem(atPath: leaseDirectoryPath)
            }
        }
    }

    private static func currentProcessOwner(profileRoot: String?) -> SpacesProcessLeaseOwner {
        SpacesProcessLeaseOwner(
            pid: getpid(),
            executablePath: SpacesProfile.currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath) ?? CommandLine
                .arguments.first ?? "unknown", profileRoot: profileRoot, token: UUID().uuidString,
            acquiredAt: TerminalSessionTimestamp.string(from: Date()))
    }

    private static func readLiveOwner(fromLeaseDirectoryPath leaseDirectoryPath: String, fileManager: FileManager) throws -> SpacesProcessLeaseOwner?
    {
        let deadline = Date().addingTimeInterval(missingMetadataGraceSeconds)

        while true {
            guard let owner = try readOwner(fromLeaseDirectoryPath: leaseDirectoryPath, fileManager: fileManager) else {
                guard fileManager.fileExists(atPath: leaseDirectoryPath) else { return nil }
                if Date() >= deadline {
                    try? fileManager.removeItem(atPath: leaseDirectoryPath)
                    return nil
                }
                Thread.sleep(forTimeInterval: missingMetadataPollIntervalSeconds)
                continue
            }
            guard isLiveOwnerProcess(owner) else {
                try? fileManager.removeItem(atPath: leaseDirectoryPath)
                return nil
            }
            return owner
        }
    }

    /// Deliberately hard-coded to `~/.spaces` rather than the active profile root: desktop control
    /// (Carbon hotkeys, etc.) is machine-wide, so exactly one process — across every dev and
    /// installed profile — may hold this lease at a time.
    static func desktopControlLeaseDirectory(homeDirectoryURL: URL? = nil, fileManager: FileManager = .default) -> String {
        let resolvedHomeDirectoryURL = homeDirectoryURL ?? currentUserHomeDirectoryURL(fileManager: fileManager)
        return resolvedHomeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true).appendingPathComponent("leases", isDirectory: true)
            .appendingPathComponent("desktop-control", isDirectory: true).path
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func isLiveOwnerProcess(_ owner: SpacesProcessLeaseOwner) -> Bool {
        guard isProcessAlive(pid: owner.pid) else { return false }
        guard let executablePath = executablePath(for: owner.pid) else { return false }
        return executablePath == SpacesProfile.canonicalPath(owner.executablePath)
    }

    private static func executablePath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if os(Linux)
            let path = "/proc/\(pid)/exe"
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { return nil }
            let utf8Bytes = buffer[..<Int(length)].map { UInt8(bitPattern: $0) }
            return SpacesProfile.canonicalPath(String(decoding: utf8Bytes, as: UTF8.self))
        #else
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            let terminatorIndex = buffer.firstIndex(of: 0) ?? Int(length)
            let utf8Bytes = buffer[..<terminatorIndex].map { UInt8(bitPattern: $0) }
            return SpacesProfile.canonicalPath(String(decoding: utf8Bytes, as: UTF8.self))
        #endif
    }

    private static func isFileExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteFileExists.rawValue
    }

    private static func appOwnerLeaseDirectory(profileRoot: String) -> String {
        URL(fileURLWithPath: profileRoot, isDirectory: true).appendingPathComponent("leases", isDirectory: true).appendingPathComponent(
            "app-owner", isDirectory: true
        ).path
    }

    private static func currentUserHomeDirectoryURL(fileManager: FileManager) -> URL {
        if let accountHomePath = currentUserAccountHomePath() { return URL(fileURLWithPath: accountHomePath, isDirectory: true) }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func currentUserAccountHomePath() -> String? {
        let uid = getuid()
        let rawSize = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        let bufferSize = rawSize > 0 ? Int(rawSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &record, &buffer, buffer.count, &result)
        guard status == 0, let entry = result else { return nil }
        let path = String(cString: entry.pointee.pw_dir)
        return path.isEmpty ? nil : path
    }

    private static func metadataPath(forLeaseDirectoryPath leaseDirectoryPath: String) -> String {
        URL(fileURLWithPath: leaseDirectoryPath, isDirectory: true).appendingPathComponent("owner.json", isDirectory: false).path
    }
}
