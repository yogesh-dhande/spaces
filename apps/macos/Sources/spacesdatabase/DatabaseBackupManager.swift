import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public struct DatabaseBackupManager: Sendable {
    private let backupDirectory: URL
    private let retentionLimit: Int
    private let dateProvider: @Sendable () -> Date

    public init(databaseURL: URL, backupDirectory: URL? = nil, retentionLimit: Int = 10, dateProvider: @escaping @Sendable () -> Date = Date.init) {
        self.backupDirectory = backupDirectory ?? databaseURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        self.retentionLimit = retentionLimit
        self.dateProvider = dateProvider
    }

    public func createMigrationBackup(sourceHandle: OpaquePointer, fromVersion: Int, toVersion: Int) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupURL = backupDirectory.appendingPathComponent(backupFileName(fromVersion: fromVersion, toVersion: toVersion))
        try backupDatabase(sourceHandle: sourceHandle, destinationURL: backupURL)
        try pruneBackups()
        return backupURL
    }

    public func existingBackups() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func backupFileName(fromVersion: Int, toVersion: Int) -> String {
        "\(Self.timestampFormatter.string(from: dateProvider()))-v\(fromVersion)-to-v\(toVersion).sqlite3"
    }

    private func backupDatabase(sourceHandle: OpaquePointer, destinationURL: URL) throws {
        var destinationHandle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destinationURL.path, &destinationHandle, flags, nil) == SQLITE_OK, let destinationHandle else {
            let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening backup database"
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw NSError(domain: "spaces.store", code: 41, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(destinationHandle) }

        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            let message = String(cString: sqlite3_errmsg(destinationHandle))
            throw NSError(domain: "spaces.store", code: 42, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_backup_finish(backup) }

        while true {
            let result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_DONE { break }
            if result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED {
                sqlite3_sleep(20)
                continue
            }
            let message = String(cString: sqlite3_errmsg(destinationHandle))
            throw NSError(domain: "spaces.store", code: 43, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func pruneBackups() throws {
        let backups = try existingBackups()
        guard backups.count > retentionLimit else { return }
        for url in backups.dropFirst(retentionLimit) { try FileManager.default.removeItem(at: url) }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()
}
