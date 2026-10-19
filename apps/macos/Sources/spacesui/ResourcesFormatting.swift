import Foundation

/// How the Resources pane writes CPU, memory, and machine capacity.
enum ResourcesFormatting {
    private static let mebibyte = 1_048_576.0
    private static let gibibyte = 1_073_741_824.0

    /// A share of one core, rounded to a whole percent. It can pass 100 for a multi-threaded process.
    static func cpu(_ percent: Double) -> String { "\(Int(max(0, percent).rounded()))%" }

    /// Megabytes below a gibibyte, otherwise gigabytes with one decimal.
    static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= gibibyte { return String(format: "%.1f GB", value / gibibyte) }
        return "\(Int((value / mebibyte).rounded())) MB"
    }

    /// "10 cores · 32 GB": the machine a device's figures are measured against.
    static func capacity(processorCount: Int, physicalMemoryBytes: UInt64) -> String {
        let cores = processorCount == 1 ? "1 core" : "\(processorCount) cores"
        return "\(cores) · \(Int((Double(physicalMemoryBytes) / gibibyte).rounded())) GB"
    }
}
