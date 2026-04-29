import Foundation

public enum AppleScript {
    @discardableResult public static func run(_ script: String) throws -> String {
        if NSClassFromString("XCTest") != nil, ProcessInfo.processInfo.environment["MUXY_ALLOW_TEST_APPLESCRIPT"] != "1" {
            throw NSError(
                domain: "spaces.applescript", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unmocked AppleScript call during tests. Install an `osascript` mock before invoking AppleScript.run."
                ])
        }
        do {
            let output = try Shell.runAndCapture(["osascript", "-e", script])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            fputs("spaces: AppleScript failed.\n", stderr)
            fputs("spaces: script begin\n", stderr)
            fputs(script, stderr)
            fputs("\nmuxy: script end\n", stderr)
            throw error
        }
    }

    @discardableResult public static func run(lines: [String]) throws -> String {
        let script = lines.joined(separator: "\n")
        return try run(script)
    }
}
