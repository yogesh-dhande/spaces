import Foundation

/// Uses Codex's own feature commands to manage the flag that activates `~/.codex/hooks.json`.
/// Codex remains the sole parser and writer of its TOML configuration.
enum AgentHookCodexFeatureToggle {
    private static let featureName = "hooks"

    struct CommandError: LocalizedError {
        let action: String
        let detail: String

        var errorDescription: String? {
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "Cannot \(action) Codex hooks with the Codex CLI\(suffix)"
        }
    }

    static func ensureEnabled(executablePath: String, codexHome: URL) throws {
        let result: CommandResult
        do { result = try run(executablePath: executablePath, arguments: ["features", "enable", featureName], codexHome: codexHome) } catch {
            throw CommandError(action: "enable", detail: error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            let detail = result.output.isEmpty ? "command exited with status \(result.terminationStatus)" : result.output
            throw CommandError(action: "enable", detail: detail)
        }
    }

    static func isEnabled(executablePath: String, codexHome: URL) -> Bool {
        guard let result = try? run(executablePath: executablePath, arguments: ["features", "list"], codexHome: codexHome),
            result.terminationStatus == 0
        else { return false }
        return featuresListHasHooksEnabled(result.output)
    }

    /// `codex features list` has no structured-output option. Match the feature name and final
    /// boolean field while allowing the human-readable stage column to contain spaces.
    static func featuresListHasHooksEnabled(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == Substring(featureName) && fields.last == "true"
        }
    }

    private struct CommandResult {
        let terminationStatus: Int32
        let output: String
    }

    private static func run(executablePath: String, arguments: [String], codexHome: URL) throws -> CommandResult {
        #if os(macOS) || os(Linux)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice

            // One combined pipe avoids deadlocking when either stream exceeds the kernel pipe buffer.
            // Drain it before waiting for termination, as required for captured child-process output.
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(terminationStatus: process.terminationStatus, output: output)
        #else
            throw CommandError(action: "run", detail: "feature commands are unavailable on this platform")
        #endif
    }
}
