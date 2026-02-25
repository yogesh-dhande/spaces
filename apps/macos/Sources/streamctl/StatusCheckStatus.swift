import Foundation

/// Semantic status of a status check result.
/// Colors are determined by the UI layer, not stored here.
public enum StatusCheckStatus: String, Sendable, Equatable {
    case passed
    case failed
}
