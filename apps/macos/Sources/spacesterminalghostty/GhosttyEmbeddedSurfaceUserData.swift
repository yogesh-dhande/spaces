#if canImport(GhosttyKit)
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    @TerminalEngineActor final class GhosttyEmbeddedSurfaceUserData {
        private let closeHandler: @TerminalEngineActor () -> Void
        private let surfaceProvider: @TerminalEngineActor () -> ghostty_surface_t?

        init(closeHandler: @escaping @TerminalEngineActor () -> Void, surfaceProvider: @escaping @TerminalEngineActor () -> ghostty_surface_t?) {
            self.closeHandler = closeHandler
            self.surfaceProvider = surfaceProvider
        }

        func handleClose() { closeHandler() }

        func surface() -> ghostty_surface_t? { surfaceProvider() }
    }
#endif
