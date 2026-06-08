import Foundation

public struct TmuxWindowInfo: Sendable {
    public let id: String
    public let index: Int
    public let name: String
    public let sessionName: String
    public let isActive: Bool
    public let panePID: Int?

    public init(id: String, index: Int, name: String, sessionName: String, isActive: Bool, panePID: Int? = nil) {
        self.id = id
        self.index = index
        self.name = name
        self.sessionName = sessionName
        self.isActive = isActive
        self.panePID = panePID
    }
}
