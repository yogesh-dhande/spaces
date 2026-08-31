import Foundation
import spacesterminalcore
import workspacecore

/// Maps a thrown error to its machine-readable `SpacesDeviceErrorCode`, shared by every wire transport
/// that surfaces one: the profile (terminal-service) transport's `SpacesDaemonErrorClassification` and the
/// Device API's `SpacesDeviceAPIServer.errorCode(for:)`. Both wire surfaces must classify the same failure
/// identically, so a client sees one code for one cause regardless of transport. Transport-specific
/// rewraps and error types (the Device API's `NSError` domain convention, pairing failures, hook-installer
/// failures; the profile transport's `SpacesRuntimeError`) are handled by each caller as a pre-check before
/// delegating here.
public enum SpacesDeviceWireErrorClassification {
    public static func errorCode(_ error: any Error) -> SpacesDeviceErrorCode {
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .missingProject, .missingWorkspace, .missingTrackedWindow: return .notFound
            case .invalidArgument, .invalidWorkspace, .projectAlreadyExists, .workspaceAlreadyExists: return .invalidArgument
            case .gitCommandFailed, .gitCommandTimedOut, .dependencyMissing, .configError, .databaseMigrationFailed: return .internalError
            // Only ever thrown by the handoff-only admission guard (`Orchestrator`'s
            // `daemonHandoffInProgress` predicate) — never by a shutdown — so it always carries the
            // handoff code, not the generic teardown one.
            case .daemonHandoffInProgress: return .handingOff
            }
        }
        // Automation boundary rejections (bad cron, empty field, unknown enum, missing automation/run) are
        // well-formed-request client errors, so they surface as invalidArgument with their descriptive
        // message rather than a generic internal error.
        if error is AutomationValidationError { return .invalidArgument }
        if error is AutomationCronScheduleError { return .invalidArgument }
        if error is DecodingError { return .invalidArgument }
        return .internalError
    }
}
