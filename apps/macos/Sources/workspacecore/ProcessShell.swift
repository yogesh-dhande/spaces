import Foundation

public enum ProcessShell: String, CaseIterable, Codable, Sendable {
    case zsh
    case bash
    case sh

    public var displayName: String { rawValue }
}
