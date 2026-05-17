import Foundation

public enum AppleScript {
    @discardableResult public static func run(_ script: String) throws -> String {
        let isRunningTests = NSClassFromString("XCTest") != nil
        if isRunningTests, ProcessInfo.processInfo.environment["SPACES_ALLOW_TEST_APPLESCRIPT"] != "1" {
            throw NSError(
                domain: "spaces.applescript", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unmocked AppleScript call during tests. Install an `osascript` mock before invoking AppleScript.run."
                ])
        }
        do {
            if isRunningTests {
                let output = try Shell.runAndCapture(["osascript", "-e", script])
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let appleScript = NSAppleScript(source: script) else {
                throw NSError(domain: "spaces.applescript", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript source."])
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
    }

    @discardableResult public static func run(lines: [String]) throws -> String {
        let script = lines.joined(separator: "\n")
        return try run(script)
    }
}
