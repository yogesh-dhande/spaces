import Foundation

/// Latencies in milliseconds with the percentiles the budgets are written in.
struct LatencySamples: Codable {
    private(set) var values: [Double] = []

    mutating func add(_ milliseconds: Double) { values.append(milliseconds) }
    mutating func add(contentsOf other: LatencySamples) { values.append(contentsOf: other.values) }

    var count: Int { values.count }
    var p50: Double { percentile(0.50) }
    var p95: Double { percentile(0.95) }
    var max: Double { values.max() ?? 0 }

    /// Nearest-rank percentile.
    private func percentile(_ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }
}
