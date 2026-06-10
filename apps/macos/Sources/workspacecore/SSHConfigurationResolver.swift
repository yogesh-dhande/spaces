import Foundation

public struct SSHResolvedConfiguration: Sendable, Equatable {
    public let hostname: String?
    public let user: String?
    public let port: Int?

    public init(hostname: String? = nil, user: String? = nil, port: Int? = nil) {
        self.hostname = Self.normalized(hostname)
        self.user = Self.normalized(user)
        self.port = port
    }

    public func resolvedHostname(fallback: String) -> String { Self.normalized(hostname) ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func parseOpenSSHConfiguration(_ output: String) -> SSHResolvedConfiguration {
        var hostname: String?
        var user: String?
        var port: Int?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "hostname": hostname = normalized(value)
            case "user": user = normalized(value)
            case "port": port = Int(value)
            default: continue
            }
        }

        return SSHResolvedConfiguration(hostname: hostname, user: user, port: port)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed.lowercased() != "none" else {
            return nil
        }
        return trimmed
    }
}

public struct SSHConfigurationResolver {
    public typealias CommandRunner = @Sendable ([String], TimeInterval) throws -> String

    private let runCommand: CommandRunner

    public init() { self.runCommand = Self.defaultRunCommand }

    public init(runCommand: @escaping CommandRunner) { self.runCommand = runCommand }

    public func resolve(host: String, timeout: TimeInterval = 5) throws -> SSHResolvedConfiguration {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return SSHResolvedConfiguration() }
        return try Self.parseOpenSSHConfiguration(runCommand(["ssh", "-G", trimmedHost], timeout))
    }

    public static func parseOpenSSHConfiguration(_ output: String) -> SSHResolvedConfiguration {
        SSHResolvedConfiguration.parseOpenSSHConfiguration(output)
    }

    private static func defaultRunCommand(_ command: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw ComputeHostBootstrapError.sshCommandTimedOut(timeout)
        }

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = [errorText, outputText].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
                separator: "\n")
            throw ComputeHostBootstrapError.sshCommandFailed(message)
        }
        return outputText
    }
}
