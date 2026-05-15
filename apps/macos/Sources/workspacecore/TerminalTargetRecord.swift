import Foundation

public struct TerminalTargetRecord: Codable, Sendable {
    public let runtimeTargetID: String?
    public let windowID: Int?
    public let trackingID: String?

    public init(runtimeTargetID: String? = nil, windowID: Int? = nil, trackingID: String? = nil) {
        self.runtimeTargetID = runtimeTargetID
        self.windowID = windowID
        self.trackingID = trackingID
    }
}
