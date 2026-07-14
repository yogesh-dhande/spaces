import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

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
            let outputBuffer = PipeOutputBuffer()
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
            if timedOut { terminateProcessTree(rootProcessID: process.processIdentifier, completion: completion) }
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

    #if os(macOS) || os(Linux)
        /// Stops descendants before their parent so a wrapper cannot leave a child holding the output
        /// pipe open. The initial snapshot is retained through SIGKILL because children are reparented
        /// as their ancestors exit and can no longer be rediscovered from the original root.
        private static func terminateProcessTree(rootProcessID: pid_t, completion: DispatchSemaphore) {
            let processIDs = descendantProcessIDs(of: rootProcessID) + [rootProcessID]
            for processID in processIDs.reversed() { kill(processID, SIGTERM) }
            let rootTerminated = completion.wait(timeout: .now() + 1) == .success
            for processID in processIDs.reversed() where processExists(processID) { kill(processID, SIGKILL) }
            if !rootTerminated { _ = completion.wait(timeout: .now() + 1) }
        }

        private static func descendantProcessIDs(of rootProcessID: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var pending = [rootProcessID]
            var seen = Set<pid_t>()
            while let parent = pending.popLast() {
                for child in directChildProcessIDs(of: parent) where seen.insert(child).inserted {
                    result.append(child)
                    pending.append(child)
                }
            }
            return result
        }

        private static func directChildProcessIDs(of parent: pid_t) -> [pid_t] {
            #if os(macOS)
                var capacity = 32
                while capacity <= 4096 {
                    var processIDs = [pid_t](repeating: 0, count: capacity)
                    let bufferSize = Int32(processIDs.count * MemoryLayout<pid_t>.stride)
                    let childCount = proc_listchildpids(parent, &processIDs, bufferSize)
                    guard childCount > 0 else { return [] }
                    if childCount < capacity { return Array(processIDs.prefix(Int(childCount))).filter { $0 > 0 } }
                    capacity *= 2
                }
                return []
            #else
                let taskDirectory = URL(fileURLWithPath: "/proc/\(parent)/task", isDirectory: true)
                let taskURLs = (try? FileManager.default.contentsOfDirectory(at: taskDirectory, includingPropertiesForKeys: nil)) ?? []
                return taskURLs.flatMap { taskURL in
                    let childrenURL = taskURL.appendingPathComponent("children")
                    guard let contents = try? String(contentsOf: childrenURL, encoding: .utf8) else { return [] }
                    return contents.split(whereSeparator: \.isWhitespace).compactMap { pid_t(String($0)) }
                }
            #endif
        }

        private static func processExists(_ processID: pid_t) -> Bool {
            errno = 0
            return kill(processID, 0) == 0 || errno != ESRCH
        }

        private final class PipeOutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }

            func snapshot() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }
    #endif
}
