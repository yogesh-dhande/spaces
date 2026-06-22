import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct SpacesDeviceTerminalPerformanceEvent: Codable, Equatable, Sendable {
    public let sessionID: String
    public let source: String
    public let name: String
    public let emittedAt: String
    public let emittedUptimeNanoseconds: UInt64
    public let elapsedMS: Int?
    public let count: Int?
    public let attributes: [String: String]

    public init(
        sessionID: String, source: String, name: String, emittedAt: String = GhosttyRemoteSessionStateTimestamp.string(from: Date()),
        emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, elapsedMS: Int? = nil, count: Int? = nil,
        attributes: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.source = source
        self.name = name
        self.emittedAt = emittedAt
        self.emittedUptimeNanoseconds = emittedUptimeNanoseconds
        self.elapsedMS = elapsedMS
        self.count = count
        self.attributes = attributes
    }
}

public enum SpacesDeviceTerminalPerformanceLogger {
    public static let environmentKey = "SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH"

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        resolvedLogPath(environment: environment) != nil
    }

    public static func emit(_ event: SpacesDeviceTerminalPerformanceEvent, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let logPath = resolvedLogPath(environment: environment) else { return }
        appendJSONLine(event, to: logPath)
    }

    private static func resolvedLogPath(environment: [String: String]) -> String? {
        let rawValue = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue
    }

    private static func appendJSONLine<T: Encodable>(_ value: T, to path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(value)
            data.append(0x0A)

            let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard fileDescriptor >= 0 else { return }
            defer { close(fileDescriptor) }

            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                    if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    bytesRemaining -= written
                    offset += written
                }
            }
        } catch {}
    }
}
