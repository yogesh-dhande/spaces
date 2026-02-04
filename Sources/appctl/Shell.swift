import Foundation

enum Shell {
    @discardableResult
    static func run(_ command: [String], cwd: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func runAndCapture(_ command: [String], cwd: String? = nil) throws -> String {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = out
        process.standardError = err
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "agentmux.shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
