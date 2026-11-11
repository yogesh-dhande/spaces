import Foundation
import spacesdevicecore

/// CPU samples of one series since the Resources pane opened, newest last. Capped at ten minutes of
/// samples so a pane left open for hours holds a bounded amount of memory per series.
struct ResourcesUsageHistory: Equatable {
    static let capacity = Int(600 / SpacesDeviceResourcesFrame.samplingInterval)

    private(set) var values: [Double] = []

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }
}
