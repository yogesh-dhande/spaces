import Foundation

public enum Shell {
    /// Returns the current process environment with Homebrew paths appended to PATH.
    /// Reads PATH from the C-level environment so that `setenv()` mutations from tests
    /// (e.g. injected mock command stubs) are reflected in the returned dictionary.
    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // getenv reads the C-level environment, which includes setenv() changes
        // made after process start (e.g. in test helpers that inject mock binaries).
        let currentPath: String
        if let raw = getenv("PATH") { currentPath = String(cString: raw) } else { currentPath = "" }
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        env["PATH"] = currentPath.isEmpty ? brewPaths : "\(currentPath):\(brewPaths)"
        return env
    }

    @discardableResult public static func run(_ command: [String], cwd: String? = nil) throws -> Int32 {
        guard let executable = command.first else {
            throw NSError(domain: "muxy.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = processEnvironment()
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public static func runAndCapture(_ command: [String], cwd: String? = nil) throws -> String {
        guard let executable = command.first else {
            throw NSError(domain: "muxy.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = processEnvironment()
        process.standardOutput = out
        process.standardError = err
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "muxy.shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
