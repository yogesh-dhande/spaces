import AppKit
import Foundation
import spacesterminalcore

@MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let paths: TerminalSessionPaths
    private let snapshotStream: GhosttyVTSnapshotStream

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        snapshotStream = GhosttyVTSnapshotStream(sessionID: launchConfiguration.sessionID, outputPath: paths.outputPath)
    }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {}

    public func parkSurfaceInHiddenHostWindow() {}

    public func setFocused(_ focused: Bool, for clientID: String) {}

    public func focusWindow(_ window: NSWindow?) {}

    public func activeOwnerClientID() -> String? {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public func hasRenderableSurface() -> Bool { false }

    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { false }

    public func snapshot() -> GhosttyTerminalSnapshot? {
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func snapshotText() -> String? {
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshotText(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func copySelectionToPasteboard() -> Bool { false }

    public func pasteClipboardContents() -> Bool { false }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool { false }

    public var debugSurfaceRefreshRequestCount: Int { 0 }

    public var effectiveTitle: String { ((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.title) ?? launchConfiguration.title }

    public var effectiveWorkingDirectory: String {
        ((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.workingDirectory) ?? launchConfiguration.workingDirectory
    }
}
