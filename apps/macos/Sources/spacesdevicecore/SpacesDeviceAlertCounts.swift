import Foundation

/// What a daemon tells the push relay about one phone: how many visible alerts it holds and how many of
/// those are agents waiting on the user. The relay sums these across a phone's devices into the app icon
/// badge and the one collapsed notification's text.
public struct SpacesDeviceAlertCounts: Sendable, Equatable {
    /// Every visible alert candidate, whatever its kind: the number the phone's Alerts tab badge shows.
    public let total: Int
    /// The visible candidates that are `.agentWaiting`.
    public let blockedAgents: Int

    public init(total: Int, blockedAgents: Int) {
        self.total = total
        self.blockedAgents = blockedAgents
    }
}
