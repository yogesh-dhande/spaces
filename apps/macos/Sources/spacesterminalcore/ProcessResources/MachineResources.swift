import Foundation

/// The machine's capacity, the denominators a client needs to read a process group's usage.
public enum MachineResources {
    public static var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
}
