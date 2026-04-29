import Foundation

public enum DatabaseLocator {
    public static let databasePathEnvironmentVariable = "SPACES_DB_PATH"

    public static func defaultPath() throws -> String {
        if let overridePath = ProcessInfo.processInfo.environment[databasePathEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !overridePath.isEmpty
        {
            let url = URL(fileURLWithPath: overridePath)
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return url.standardizedFileURL.path
        }
        return try defaultPath(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func defaultPath(homeDirectoryURL: URL) throws -> String {
        let dir = homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spaces.db").path
    }
}
