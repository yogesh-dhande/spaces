import AppKit
import Foundation

/// Downloads a release asset, extracts it, replaces the running binary, and relaunches.
@MainActor public final class AppUpdater {
    enum UpdateError: LocalizedError {
        case downloadFailed
        case extractionFailed
        case binaryNotFound
        case replacementFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Failed to download the update."
            case .extractionFailed: "Failed to extract the update archive."
            case .binaryNotFound: "Could not find the updated binary in the archive."
            case .replacementFailed(let reason): "Failed to replace binary: \(reason)"
            }
        }
    }

    /// Download and install the update from the given URL.
    func downloadAndInstall(from url: URL) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "muxy-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgPath = tempDir.appending(path: "update.dmg")
        try await download(from: url, to: dmgPath)
        let mountPoint = try mountDMG(at: dmgPath)
        defer { try? unmountDMG(at: mountPoint) }
        let appBundle = try findAppBundle(in: mountPoint)
        let applicationsDir = URL(fileURLWithPath: "/Applications")
        let targetApp = applicationsDir.appending(path: "Muxy.app")
        try installApp(from: appBundle, to: targetApp)
        relaunchApp(at: targetApp)
    }

    private func download(from url: URL, to destination: URL) async throws {
        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw UpdateError.downloadFailed }
        try FileManager.default.moveItem(at: localURL, to: destination)
    }

    private func mountDMG(at dmgPath: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgPath.path, "-nobrowse", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.extractionFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else { throw UpdateError.extractionFailed }
        for entity in entities { if let mountPoint = entity["mount-point"] as? String { return URL(fileURLWithPath: mountPoint) } }
        throw UpdateError.extractionFailed
    }
    private func unmountDMG(at mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path]
        try process.run()
        process.waitUntilExit()
    }
    private func findAppBundle(in directory: URL) throws -> URL {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { throw UpdateError.binaryNotFound }
        for item in contents { if item.pathExtension == "app" && item.lastPathComponent == "Muxy.app" { return item } }
        throw UpdateError.binaryNotFound
    }
    private func installApp(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        do { try fm.copyItem(at: source, to: destination) } catch {
            throw UpdateError.replacementFailed("Could not install app: \(error.localizedDescription)")
        }
    }
    private func relaunchApp(at appPath: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appPath.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
