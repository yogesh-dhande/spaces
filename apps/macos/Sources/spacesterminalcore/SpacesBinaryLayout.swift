import Foundation

public enum SpacesOwnedBinary: CaseIterable, Sendable {
    case spaces
    case spacesd
    case spacesCaddy

    public var appResourceName: String {
        switch self {
        case .spaces: "spaces"
        case .spacesd: "spacesd"
        case .spacesCaddy: "caddy"
        }
    }

    public var systemLinkName: String {
        switch self {
        case .spaces: "spaces"
        case .spacesd: "spacesd"
        case .spacesCaddy: "spaces-caddy"
        }
    }

    public var userHelperName: String? {
        switch self {
        case .spaces: "spaces"
        case .spacesd: "spacesd"
        case .spacesCaddy: nil
        }
    }
}

public enum SpacesBinaryLayout {
    public static let launchAgentLabel = "dev.usespaces.spacesd"

    public static func installedAppBundleURL(applicationsDirectoryURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) -> URL {
        applicationsDirectoryURL.appendingPathComponent("Spaces.app", isDirectory: true)
    }

    public static func appResourceURL(for binary: SpacesOwnedBinary, appBundleURL: URL = installedAppBundleURL()) -> URL {
        appBundleURL.appendingPathComponent("Contents/Resources/\(binary.appResourceName)", isDirectory: false)
    }

    public static func systemLinkURL(
        for binary: SpacesOwnedBinary,
        systemBinDirectoryURL: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    ) -> URL {
        systemBinDirectoryURL.appendingPathComponent(binary.systemLinkName, isDirectory: false)
    }

    public static func userHelperLinkURL(for binary: SpacesOwnedBinary, homeDirectoryURL: URL = defaultHomeDirectoryURL()) -> URL? {
        guard let name = binary.userHelperName else { return nil }
        return homeDirectoryURL.appendingPathComponent(".spaces/bin/\(name)", isDirectory: false)
    }

    public static func launchAgentURL(homeDirectoryURL: URL = defaultHomeDirectoryURL()) -> URL {
        homeDirectoryURL.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist", isDirectory: false)
    }

    public static func defaultHomeDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}

#if os(macOS)
    public struct SpacesMacInstallationRepairResult: Equatable, Sendable {
        public let repairedPaths: [String]
        public let failedPaths: [String: String]

        public var repairedAnything: Bool { !repairedPaths.isEmpty }
        public var failedAnything: Bool { !failedPaths.isEmpty }
    }

    public enum SpacesMacInstallationRepair {
        @discardableResult public static func repairCurrentAppInstallation(
            appBundleURL: URL = Bundle.main.bundleURL,
            systemBinDirectoryURL: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectoryURL: URL = SpacesBinaryLayout.defaultHomeDirectoryURL(),
            fileManager: FileManager = .default,
            requireInstalledBundle: Bool = true
        ) -> SpacesMacInstallationRepairResult {
            guard appBundleURL.pathExtension == "app" else { return SpacesMacInstallationRepairResult(repairedPaths: [], failedPaths: [:]) }
            if requireInstalledBundle {
                let installedPath = SpacesBinaryLayout.installedAppBundleURL().standardizedFileURL.path
                guard appBundleURL.standardizedFileURL.path == installedPath else {
                    return SpacesMacInstallationRepairResult(repairedPaths: [], failedPaths: [:])
                }
            }

            var repairedPaths: [String] = []
            var failedPaths: [String: String] = [:]

            let daemonResourceURL = SpacesBinaryLayout.appResourceURL(for: .spacesd, appBundleURL: appBundleURL)
            let canRepairLaunchAgent = fileManager.isExecutableFile(atPath: daemonResourceURL.path)

            for binary in SpacesOwnedBinary.allCases {
                let sourceURL = SpacesBinaryLayout.appResourceURL(for: binary, appBundleURL: appBundleURL)
                guard fileManager.isExecutableFile(atPath: sourceURL.path) else { continue }

                repairLink(
                    at: SpacesBinaryLayout.systemLinkURL(for: binary, systemBinDirectoryURL: systemBinDirectoryURL),
                    target: sourceURL, fileManager: fileManager, repairedPaths: &repairedPaths, failedPaths: &failedPaths)

                if let helperURL = SpacesBinaryLayout.userHelperLinkURL(for: binary, homeDirectoryURL: homeDirectoryURL) {
                    repairLink(at: helperURL, target: sourceURL, fileManager: fileManager, repairedPaths: &repairedPaths, failedPaths: &failedPaths)
                }
            }

            if canRepairLaunchAgent {
                repairLaunchAgent(
                    homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, repairedPaths: &repairedPaths, failedPaths: &failedPaths)
            }

            return SpacesMacInstallationRepairResult(repairedPaths: repairedPaths.sorted(), failedPaths: failedPaths)
        }

        static func desiredLaunchAgentPlist(homeDirectoryURL: URL) -> [String: Any] {
            let runtimeDirectory = homeDirectoryURL.appendingPathComponent(".spaces/runtime", isDirectory: true)
            let daemonPath = SpacesBinaryLayout.userHelperLinkURL(for: .spacesd, homeDirectoryURL: homeDirectoryURL)?.path
                ?? homeDirectoryURL.appendingPathComponent(".spaces/bin/spacesd", isDirectory: false).path
            return [
                "Label": SpacesBinaryLayout.launchAgentLabel,
                "ProgramArguments": [daemonPath],
                "RunAtLoad": true,
                "KeepAlive": true,
                "WorkingDirectory": homeDirectoryURL.path,
                "StandardOutPath": runtimeDirectory.appendingPathComponent("spacesd.launchd.out.log", isDirectory: false).path,
                "StandardErrorPath": runtimeDirectory.appendingPathComponent("spacesd.launchd.err.log", isDirectory: false).path,
            ]
        }

        static func launchAgentProgramArguments(from data: Data) -> [String]? {
            guard
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let arguments = plist["ProgramArguments"] as? [String]
            else { return nil }
            return arguments
        }

        private static func repairLink(
            at linkURL: URL,
            target targetURL: URL,
            fileManager: FileManager,
            repairedPaths: inout [String],
            failedPaths: inout [String: String]
        ) {
            do {
                guard try replaceSymbolicLinkIfNeeded(at: linkURL, target: targetURL, fileManager: fileManager) else { return }
                repairedPaths.append(linkURL.path)
            } catch {
                failedPaths[linkURL.path] = error.localizedDescription
            }
        }

        private static func repairLaunchAgent(
            homeDirectoryURL: URL,
            fileManager: FileManager,
            repairedPaths: inout [String],
            failedPaths: inout [String: String]
        ) {
            let plistURL = SpacesBinaryLayout.launchAgentURL(homeDirectoryURL: homeDirectoryURL)
            let desiredPlist = desiredLaunchAgentPlist(homeDirectoryURL: homeDirectoryURL)
            let desiredArguments = desiredPlist["ProgramArguments"] as? [String]
            let existingData = try? Data(contentsOf: plistURL)
            if let existingData, launchAgentProgramArguments(from: existingData) == desiredArguments { return }

            do {
                try fileManager.createDirectory(
                    at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755])
                try fileManager.createDirectory(
                    at: homeDirectoryURL.appendingPathComponent(".spaces/runtime", isDirectory: true), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755])
                let data = try PropertyListSerialization.data(fromPropertyList: desiredPlist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
                repairedPaths.append(plistURL.path)
            } catch {
                failedPaths[plistURL.path] = error.localizedDescription
            }
        }

        private static func replaceSymbolicLinkIfNeeded(at linkURL: URL, target targetURL: URL, fileManager: FileManager) throws -> Bool {
            if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) {
                let resolvedDestination = resolvedSymbolicLinkDestination(existingDestination, relativeTo: linkURL)
                if resolvedDestination.standardizedFileURL.path == targetURL.standardizedFileURL.path { return false }
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: linkURL.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: linkURL.path])
            }
            if exists || (try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
                try fileManager.removeItem(at: linkURL)
            }

            try fileManager.createDirectory(
                at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
            return true
        }

        private static func resolvedSymbolicLinkDestination(_ destination: String, relativeTo linkURL: URL) -> URL {
            if destination.hasPrefix("/") { return URL(fileURLWithPath: destination, isDirectory: false) }
            return linkURL.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: false)
        }
    }
#endif
