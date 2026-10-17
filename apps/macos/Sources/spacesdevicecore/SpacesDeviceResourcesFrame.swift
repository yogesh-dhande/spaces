import Foundation

/// CPU and memory of one group of processes over the last sampling interval.
///
/// `cpuPercent` is a share of one core (Activity Monitor's convention), so a group that keeps four
/// cores busy reads 400. `memoryBytes` is the physical footprint on macOS (the number Activity Monitor
/// shows) and resident memory on Linux, which has no footprint equivalent.
public struct SpacesDeviceResourceUsage: Codable, Sendable, Equatable {
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(cpuPercent: Double, memoryBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// One live terminal's process tree: its shell and every descendant still attached to it. A process
/// that detaches (a daemonized server, a Docker container run by the container runtime) is reparented
/// away from the shell and is not counted; the client says so under the table.
public struct SpacesDeviceTerminalResourceUsage: Codable, Sendable, Equatable {
    public let sessionID: String
    public let usage: SpacesDeviceResourceUsage
    /// Processes in the tree, the shell included.
    public let processCount: Int

    public init(sessionID: String, usage: SpacesDeviceResourceUsage, processCount: Int) {
        self.sessionID = sessionID
        self.usage = usage
        self.processCount = processCount
    }
}

/// One frame of the `subscribeDeviceResources` stream: the daemon's measurement of its own machine.
///
/// The daemon samples only while at least one client holds the subscription, every
/// `SpacesDeviceResourcesFrame.samplingInterval`. CPU is a rate, so each frame covers the interval
/// since the previous sample; the first frame arrives one interval after the subscription starts.
///
/// Spaces' own cost (`daemon`) and the work users run in terminals (`terminals`) are always separate
/// figures. A client never adds them into one total that would read as Spaces' usage.
public struct SpacesDeviceResourcesFrame: Codable, Sendable, Equatable {
    public static let samplingInterval: TimeInterval = 2

    public let sampledAt: Date
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64
    /// `spacesd` plus, on macOS, its Caddy router.
    public let daemon: SpacesDeviceResourceUsage
    /// Every live terminal session on the device, idle ones included.
    public let terminals: [SpacesDeviceTerminalResourceUsage]

    public init(
        sampledAt: Date, processorCount: Int, physicalMemoryBytes: UInt64, daemon: SpacesDeviceResourceUsage,
        terminals: [SpacesDeviceTerminalResourceUsage]
    ) {
        self.sampledAt = sampledAt
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.daemon = daemon
        self.terminals = terminals
    }
}

/// Newline-delimited JSON framing for the `subscribeDeviceResources` stream, matching the other
/// subscription streams' line framing.
public enum SpacesDeviceResourcesStreamCodec {
    public static func encodeLine(_ frame: SpacesDeviceResourcesFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceResourcesFrame {
        try JSONDecoder().decode(SpacesDeviceResourcesFrame.self, from: line)
    }
}
