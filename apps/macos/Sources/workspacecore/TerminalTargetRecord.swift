import Foundation

public struct TerminalTargetRecord: Codable, Sendable {
    public let runtimeTargetID: String?
    public let trackingID: String?

    public init(runtimeTargetID: String? = nil, trackingID: String? = nil) {
        self.runtimeTargetID = runtimeTargetID
        self.trackingID = trackingID
    }
}
