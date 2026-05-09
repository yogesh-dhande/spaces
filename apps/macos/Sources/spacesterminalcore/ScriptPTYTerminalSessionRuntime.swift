import Dispatch
import Foundation

public final class ScriptPTYTerminalSessionRuntime: TerminalSessionBackendRuntime {
    public let backendKind: TerminalSessionBackendKind = .scriptPTY
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths
    private let now: @Sendable () -> String

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        self.now = now
    }

    public func run() throws -> Never {
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = try startPTYWrappedProcess(inputPipe: inputPipe, outputPipe: outputPipe)
        let childPID = process.processIdentifier
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                state: .running, updatedAt: now()), paths: paths)

        let queue = DispatchQueue(label: "spaces.terminal.session.\(launchConfiguration.sessionID)")
        let scriptInputHandle = inputPipe.fileHandleForWriting
        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
        try outputHandle.seekToEnd()
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let outputSource = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
        outputSource.setEventHandler {
            let available = Int(outputSource.data)
            guard available > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: min(available, 8192))
            let count = read(outputFD, &buffer, buffer.count)
            if count > 0 {
                try? outputHandle.write(contentsOf: buffer.prefix(Int(count)))
                try? outputHandle.synchronize()
            }
        }
        outputSource.setCancelHandler {
            try? outputPipe.fileHandleForReading.close()
            try? outputHandle.close()
        }

        let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: queue) { request in
            switch request.command {
            case "send":
                guard let text = request.text else { return TerminalControlResponse(ok: false, message: "Missing text payload.") }
                guard let data = (text + (request.appendNewline ? "\n" : "")).data(using: .utf8) else {
                    return TerminalControlResponse(ok: false, message: "Unable to encode terminal input.")
                }
                try scriptInputHandle.write(contentsOf: data)
                return TerminalControlResponse(ok: true, message: "Sent input.")
            case "key":
                guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                    return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
                }
                try scriptInputHandle.write(contentsOf: bytes)
                return TerminalControlResponse(ok: true, message: "Sent key.")
            default: return TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
            }
        }
        try controlServer.start()

        let processSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        processSource.setEventHandler { [paths, now, launchConfiguration] in
            let state: TerminalSessionState = process.terminationReason == .exit ? .exited : .failed
            try? TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                    state: state, updatedAt: now(), exitedAt: now()), paths: paths)
            outputSource.cancel()
            controlServer.stop()
            try? scriptInputHandle.close()
            processSource.cancel()
            exit(process.terminationReason == .exit ? Int32(process.terminationStatus) : 1)
        }

        outputSource.resume()
        processSource.resume()
        dispatchMain()
    }

    private func startPTYWrappedProcess(inputPipe: Pipe, outputPipe: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        if let command = launchConfiguration.command {
            process.arguments = ["-q", "/dev/null", launchConfiguration.shell, "-lc", command]
        } else {
            process.arguments = ["-q", "/dev/null", launchConfiguration.shell, "-l"]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: launchConfiguration.workingDirectory, isDirectory: true)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        return process
    }
}
