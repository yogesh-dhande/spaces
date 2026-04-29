import Foundation

public struct HotkeySpecError: LocalizedError {
    private let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}
