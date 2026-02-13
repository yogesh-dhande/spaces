import Foundation

public enum DatabaseLocator {
    public static func defaultPath() throws -> String {
        return try defaultPath(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func defaultPath(homeDirectoryURL: URL) throws -> String {
        let dir = homeDirectoryURL.appendingPathComponent(".spaceship", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spaceship.db").path
    }
}
