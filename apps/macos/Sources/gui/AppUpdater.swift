import AppKit
import Foundation

/// Downloads a release asset, extracts it, replaces the running binary, and relaunches.
@MainActor
public final class AppUpdater {
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

    /// Progress callback: (bytesReceived, totalBytes). totalBytes may be 0 if unknown.
    var onProgress: (@MainActor (Int64, Int64) -> Void)?

    /// Download and install the update from the given URL.
    func downloadAndInstall(from url: URL) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "muxy-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zipPath = tempDir.appending(path: "update.zip")
        try await download(from: url, to: zipPath)
        try extractZip(at: zipPath, to: tempDir)

        let currentExecutable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let extractedBinary = try findBinary(named: currentExecutable.lastPathComponent, in: tempDir)

        try replaceBinary(current: currentExecutable, replacement: extractedBinary)
        relaunch(executable: currentExecutable)
    }

    private func download(from url: URL, to destination: URL) async throws {
        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        try FileManager.default.moveItem(at: localURL, to: destination)
    }

    private func extractZip(at zipPath: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipPath.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.extractionFailed }
    }

    private func findBinary(named name: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isExecutableKey]) else {
            throw UpdateError.binaryNotFound
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == name {
                var isExecutable: AnyObject?
                try (fileURL as NSURL).getResourceValue(&isExecutable, forKey: .isExecutableKey)
                if isExecutable as? Bool == true {
                    return fileURL
                }
            }
        }
        throw UpdateError.binaryNotFound
    }

    private func replaceBinary(current: URL, replacement: URL) throws {
        let fm = FileManager.default
        let backupURL = current.deletingLastPathComponent().appending(path: "\(current.lastPathComponent).bak")
        try? fm.removeItem(at: backupURL)

        do {
            try fm.moveItem(at: current, to: backupURL)
        } catch {
            throw UpdateError.replacementFailed("Could not back up current binary: \(error.localizedDescription)")
        }

        do {
            try fm.moveItem(at: replacement, to: current)
        } catch {
            // Restore backup on failure.
            try? fm.moveItem(at: backupURL, to: current)
            throw UpdateError.replacementFailed("Could not install new binary: \(error.localizedDescription)")
        }

        // Clean up backup.
        try? fm.removeItem(at: backupURL)
    }

    private func relaunch(executable: URL) {
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        try? process.run()
        NSApp.terminate(nil)
    }
}
