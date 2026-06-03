import Foundation
import GhosttyKit

@MainActor final class GhosttyEmbeddedSurfaceUserData {
    private let closeHandler: @MainActor () -> Void
    private let surfaceProvider: @MainActor () -> ghostty_surface_t?

    init(closeHandler: @escaping @MainActor () -> Void, surfaceProvider: @escaping @MainActor () -> ghostty_surface_t?) {
        self.closeHandler = closeHandler
        self.surfaceProvider = surfaceProvider
    }

    func handleClose() { closeHandler() }

    func surface() -> ghostty_surface_t? { surfaceProvider() }
}
