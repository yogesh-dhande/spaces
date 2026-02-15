import Foundation

public struct ExtractedBrowserWindowMapping: Codable, Sendable {
    public let targetURL: String
    public let windowID: Int
    public let isValid: Bool

    public init(targetURL: String, windowID: Int, isValid: Bool = true) {
        self.targetURL = targetURL
        self.windowID = windowID
        self.isValid = isValid
    }
}
