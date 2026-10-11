import Foundation

/// A program-supplied link the untrusted-link policy refused, shown in an alert that opens nothing.
struct TerminalBlockedLink: Equatable {
    /// Why the link was refused.
    let reason: String
    /// The sanitized target, shown and copyable so the user can still inspect it.
    let displayString: String
}
