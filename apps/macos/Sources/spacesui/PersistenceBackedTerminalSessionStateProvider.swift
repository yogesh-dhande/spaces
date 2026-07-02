import Foundation
import spacesterminalcore
import spacesterminalghostty

@MainActor final class PersistenceBackedTerminalSessionStateProvider: TerminalSessionStateProviding {
    private let paths: TerminalSessionPaths

    init(paths: TerminalSessionPaths) { self.paths = paths }

    var currentLaunchConfiguration: TerminalSessionLaunchConfiguration? { try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) }

    var currentRuntimeState: TerminalSessionRuntimeState? { try? TerminalSessionPersistence.readRuntimeState(paths: paths) }

    var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot? { try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) }

    var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload? { try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) }

    func refreshState() {}

    func startStateStream(
        onUpdate _: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect _: @escaping @MainActor ((any Error)?) -> Void
    ) {}
}
