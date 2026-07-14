import Dispatch
import Foundation

/// Uses Codex's own feature commands to manage the flag that activates `~/.codex/hooks.json`.
/// Codex remains the sole parser and writer of its TOML configuration.
enum AgentHookCodexFeatureToggle {
    private static let featureName = "hooks"
    private static let commandTimeoutSeconds: TimeInterval = 5

    struct CommandError: LocalizedError {
        let action: String
        let detail: String

        var errorDescription: String? {
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "Cannot \(action) Codex hooks with the Codex CLI\(suffix)"
        }
    }

    static func ensureEnabled(executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval = commandTimeoutSeconds) throws {
        let result: CommandResult
        do {
            result = try run(
                executablePath: executablePath, arguments: ["features", "enable", featureName], codexHome: codexHome, timeoutSeconds: timeoutSeconds)
        } catch { throw CommandError(action: "enable", detail: error.localizedDescription) }
        guard result.terminationStatus == 0 else {
            let detail = result.output.isEmpty ? "command exited with status \(result.terminationStatus)" : result.output
            throw CommandError(action: "enable", detail: detail)
        }
        guard isEnabled(executablePath: executablePath, codexHome: codexHome, timeoutSeconds: timeoutSeconds) else {
            throw CommandError(action: "enable", detail: "the command succeeded, but Codex hooks remain disabled")
        }
    }

    static func isEnabled(executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval = commandTimeoutSeconds) -> Bool {
        guard
            let result = try? run(
                executablePath: executablePath, arguments: ["features", "list"], codexHome: codexHome, timeoutSeconds: timeoutSeconds),
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

    private struct CommandTimeoutError: LocalizedError { var errorDescription: String? { "Codex feature command timed out" } }

    private static func run(executablePath: String, arguments: [String], codexHome: URL, timeoutSeconds: TimeInterval) throws -> CommandResult {
        #if os(macOS) || os(Linux)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let outputBuffer = AgentHookPipeOutputBuffer()
            let endOfOutput = DispatchSemaphore(value: 0)
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    endOfOutput.signal()
                    return
                }
                outputBuffer.append(data)
            }
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let completion = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completion.signal() }
            do { try process.run() } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                throw error
            }

            let timedOut = completion.wait(timeout: .now() + timeoutSeconds) == .timedOut
            if timedOut { AgentHookProcessTree.terminate(rootProcessID: process.processIdentifier, completion: completion) }
            if !process.isRunning { process.waitUntilExit() }
            _ = endOfOutput.wait(timeout: .now() + 1)
            outputPipe.fileHandleForReading.readabilityHandler = nil

            if timedOut { throw CommandTimeoutError() }
            let output = String(decoding: outputBuffer.snapshot(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(terminationStatus: process.terminationStatus, output: output)
        #else
            throw CommandError(action: "run", detail: "feature commands are unavailable on this platform")
        #endif
    }

}
