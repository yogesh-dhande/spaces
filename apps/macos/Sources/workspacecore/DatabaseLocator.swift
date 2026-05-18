import Foundation
import spacesterminalcore

public enum DatabaseLocator {
    public static let databasePathEnvironmentVariable = SpacesProfile.databasePathEnvironmentVariable

    public static func defaultPath() throws -> String { try SpacesProfile.current().databasePath }

    static func defaultPath(homeDirectoryURL: URL) throws -> String { try SpacesProfile.installedDatabasePath(homeDirectoryURL: homeDirectoryURL) }
}
