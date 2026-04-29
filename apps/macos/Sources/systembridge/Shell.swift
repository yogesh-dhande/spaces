import Darwin
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

    private static func resolvedExecutablePath(for executable: String, environment: [String: String]) -> String? {
        if executable.contains("/") { return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appending(path: executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func waitStatus(_ status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 { return (status >> 8) & 0xff }
        if terminationSignal != 0x7f { return 128 + terminationSignal }
        return status
    }

    @discardableResult public static func run(_ command: [String], cwd: String? = nil) throws -> Int32 {
        guard let executable = command.first else {
            throw NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let environment = processEnvironment()
        if cwd == nil, let executablePath = resolvedExecutablePath(for: executable, environment: environment) {
            var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + Array(command.dropFirst())).map { strdup($0) }
            argv.append(nil)
            defer { for case let pointer? in argv { free(pointer) } }

            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { for case let pointer? in envp { free(pointer) } }

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, nil, nil, &argv, &envp)
            if spawnResult != 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(spawnResult))])
            }

            var status: Int32 = 0
            if waitpid(pid, &status, 0) == -1 {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }
            return waitStatus(status)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public static func runAndCapture(_ command: [String], cwd: String? = nil) throws -> String {
        guard let executable = command.first else {
            throw NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let environment = processEnvironment()
        if cwd == nil, let executablePath = resolvedExecutablePath(for: executable, environment: environment) {
            var stdoutPipe: [Int32] = [0, 0]
            var stderrPipe: [Int32] = [0, 0]
            guard pipe(&stdoutPipe) == 0 else {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }
            guard pipe(&stderrPipe) == 0 else {
                let errnoValue = errno
                close(stdoutPipe[0])
                close(stdoutPipe[1])
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }

            var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + Array(command.dropFirst())).map { strdup($0) }
            argv.append(nil)
            defer { for case let pointer? in argv { free(pointer) } }

            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { for case let pointer? in envp { free(pointer) } }

            var fileActions: posix_spawn_file_actions_t? = nil
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, &fileActions, nil, &argv, &envp)
            close(stdoutPipe[1])
            close(stderrPipe[1])
            if spawnResult != 0 {
                close(stdoutPipe[0])
                close(stderrPipe[0])
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(spawnResult))])
            }

            let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
            let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
            let stdoutData = stdoutHandle.readDataToEndOfFile()
            let stderrData = stderrHandle.readDataToEndOfFile()

            var status: Int32 = 0
            if waitpid(pid, &status, 0) == -1 {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }

            let terminationStatus = waitStatus(status)
            if terminationStatus != 0 {
                let text = String(data: stderrData, encoding: .utf8) ?? ""
                throw NSError(domain: "spaces.shell", code: Int(terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
            }
            return String(data: stdoutData, encoding: .utf8) ?? ""
        }

        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "spaces.shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
