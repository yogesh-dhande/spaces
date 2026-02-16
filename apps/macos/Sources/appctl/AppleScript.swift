import Foundation

public enum AppleScript {
    @discardableResult public static func run(_ script: String) throws -> String {
        do {
            let output = try Shell.runAndCapture(["osascript", "-e", script])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            fputs("muxy: AppleScript failed.\n", stderr)
            fputs("muxy: script begin\n", stderr)
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
