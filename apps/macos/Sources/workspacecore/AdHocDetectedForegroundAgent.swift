import Foundation

/// What foreground detection learned about a coding agent running in a terminal Spaces did not launch as
/// an agent session, read off that session's runtime state and written onto the agent row it promotes the
/// terminal to.
///
/// `displayCommand` is the bounded command line a person reads on the row; `launchCommand` is the
/// unbounded one a session restore relaunches the agent from. They are kept apart because bounding is
/// right for a label and wrong for a command another process has to run.
struct AdHocDetectedForegroundAgent {
    let kind: String
    let label: String
    let displayCommand: String?
    let launchCommand: String?
}
