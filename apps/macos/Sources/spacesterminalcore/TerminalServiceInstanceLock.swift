import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum TerminalServiceInstanceLockError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(pid: Int32?, path: String)

    public var description: String {
        switch self {
        case .alreadyRunning(let pid, let path):
            if let pid { return "spacesd is already running for this profile (pid \(pid), lock \(path))." }
            return "spacesd is already running for this profile (lock \(path))."
        }
    }
}

public final class TerminalServiceInstanceLock {
    private struct LockRecord: Codable {
        let pid: Int32
        let token: String
    }

    private let path: String
    private let token: String
    private let fileManager: FileManager
    private var isReleased = false

    private init(path: String, token: String, fileManager: FileManager) {
        self.path = path
        self.token = token
        self.fileManager = fileManager
    }

    deinit { release() }

    public static func acquire(path: String, processID: Int32 = getpid(), fileManager: FileManager = .default) throws -> TerminalServiceInstanceLock {
        let token = UUID().uuidString
        let record = LockRecord(pid: processID, token: token)
        let lockURL = URL(fileURLWithPath: path, isDirectory: false)
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        while true {
            let candidatePath = "\(path).\(processID).\(token).tmp"
            let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: false)
            let data = try JSONEncoder().encode(record)
            try data.write(to: candidateURL, options: .withoutOverwriting)
            defer { try? fileManager.removeItem(at: candidateURL) }

            if link(candidatePath, path) == 0 { return TerminalServiceInstanceLock(path: path, token: token, fileManager: fileManager) }

            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            guard code == .EEXIST else { throw POSIXError(code) }
            guard try removeStaleLockIfNeeded(path: path, fileManager: fileManager) else {
                throw TerminalServiceInstanceLockError.alreadyRunning(pid: try existingProcessID(path: path), path: path)
            }
        }
    }

    public func release() {
        guard !isReleased else { return }
        isReleased = true
        guard (try? Self.existingRecord(path: path))?.token == token else { return }
        try? fileManager.removeItem(atPath: path)
    }

    private static func removeStaleLockIfNeeded(path: String, fileManager: FileManager) throws -> Bool {
        guard let record = try existingRecord(path: path) else {
            try? fileManager.removeItem(atPath: path)
            return true
        }
        // After exec-in-place the resumed daemon re-enters at the same pid, but the old
        // in-memory TerminalServiceInstanceLock was never released (execv destroyed it
        // mid-flight), so its on-disk record is still this pid's own — replace it instead
        // of treating it as another live owner.
        guard record.pid == getpid() || !processIsAlive(record.pid) else { return false }
        guard (try existingRecord(path: path))?.token == record.token else { return false }
        try fileManager.removeItem(atPath: path)
        return true
    }

    private static func existingProcessID(path: String) throws -> Int32? { try existingRecord(path: path)?.pid }

    private static func existingRecord(path: String) throws -> LockRecord? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: url)
        return try? JSONDecoder().decode(LockRecord.self, from: data)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
