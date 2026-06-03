import Foundation

enum TerminalPlatformDirectories {
    static func defaultSpacesDirectory(fileManager: FileManager = .default) throws -> URL {
        #if os(macOS)
            let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".spaces", isDirectory: true)
        #else
            let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = appSupport.appendingPathComponent("Spaces", isDirectory: true)
        #endif
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func defaultRuntimeDirectory(fileManager: FileManager = .default) throws -> URL {
        try defaultSpacesDirectory(fileManager: fileManager).appendingPathComponent("runtime", isDirectory: true)
    }
}
