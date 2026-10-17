import Foundation

/// Which release feed a self-updating daemon follows. `stable` is what the website offers everyone;
/// `prerelease` also offers each tagged release before it is promoted.
public enum DaemonUpdateChannel: String, Codable, Sendable, Equatable {
    case stable
    case prerelease
}
