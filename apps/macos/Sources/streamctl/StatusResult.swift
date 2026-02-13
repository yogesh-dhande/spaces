import Foundation

public struct StatusResult: Sendable {
    public let processID: String
    public let checkName: String
    public let status: String
    public let message: String?
    public let lastRunAt: String?

    public init(processID: String, checkName: String, status: String, message: String?, lastRunAt: String?) {
        self.processID = processID
        self.checkName = checkName
        self.status = status
        self.message = message
        self.lastRunAt = lastRunAt
    }
}
