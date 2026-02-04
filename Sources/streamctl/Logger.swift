import Foundation

public struct StreamLogger: Sendable {
    private let stream: String

    public init(stream: String) {
        self.stream = stream
    }

    public func info(_ message: String) {
        print("[stream:\(stream)] \(message)")
    }

    public func warn(_ message: String) {
        fputs("[stream:\(stream)] WARN: \(message)\n", stderr)
    }

    public func error(_ message: String) {
        fputs("[stream:\(stream)] ERROR: \(message)\n", stderr)
    }
}
