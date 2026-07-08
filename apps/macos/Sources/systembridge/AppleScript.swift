import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public enum AppleScript {
    @discardableResult public static func run(_ script: String, timeoutSeconds: Int? = nil) throws -> String {
        #if os(Linux)
            throw NSError(domain: "spaces.applescript", code: 5, userInfo: [NSLocalizedDescriptionKey: "AppleScript is unavailable on Linux."])
        #else
            let isRunningTests = NSClassFromString("XCTest") != nil
            if isRunningTests, ProcessInfo.processInfo.environment["SPACES_ALLOW_TEST_APPLESCRIPT"] != "1" {
                throw NSError(
                    domain: "spaces.applescript", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unmocked AppleScript call during tests. Install an `osascript` mock before invoking AppleScript.run."
                    ])
            }
            let usesTimeout = (timeoutSeconds ?? 0) > 0
            let script = usesTimeout ? timeoutWrappedScript(script, timeoutSeconds: timeoutSeconds ?? 0) : script
            do {
                if isRunningTests {
                    if usesTimeout, let timeoutSeconds { return try runWithProcessTimeout(script, timeoutSeconds: timeoutSeconds) }
                    let output = try Shell.runAndCapture(["osascript", "-e", script])
                    return output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let appleScript = NSAppleScript(source: script) else {
                    throw NSError(
                        domain: "spaces.applescript", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript source."])
                }
                var executionError: NSDictionary?
                let result = appleScript.executeAndReturnError(&executionError)
                if let executionError {
                    throw NSError(domain: "spaces.applescript", code: 3, userInfo: [NSLocalizedDescriptionKey: executionError.description])
                }
                return (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                fputs("spaces: AppleScript failed.\n", stderr)
                fputs("spaces: script begin\n", stderr)
                fputs(script, stderr)
                fputs("\nspaces: script end\n", stderr)
                throw error
            }
        #endif
    }

    @discardableResult public static func run(lines: [String], timeoutSeconds: Int? = nil) throws -> String {
        let script = lines.joined(separator: "\n")
        return try run(script, timeoutSeconds: timeoutSeconds)
    }

    private static func timeoutWrappedScript(_ script: String, timeoutSeconds: Int) -> String {
        guard timeoutSeconds > 0 else { return script }
        let body = script.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n")
        return """
            with timeout of \(timeoutSeconds) seconds
            \(body)
            end timeout
            """
    }

    private static func runWithProcessTimeout(_ script: String, timeoutSeconds: Int) throws -> String {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["osascript", "-e", script]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw NSError(
                domain: "spaces.applescript", code: 4, userInfo: [NSLocalizedDescriptionKey: "AppleScript timed out after \(timeoutSeconds)s."])
        }

        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "spaces.applescript", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
