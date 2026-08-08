#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    /// Identifies one registration of a surface action handler.
    ///
    /// Handlers have to be keyed by the surface pointer, because that is all an action event carries.
    /// Surface addresses are reused: a pane that frees its mirror and a pane that builds one can land on
    /// the same address, and an unregistration by address alone would then remove whichever handler is
    /// currently there — silently killing the live pane's link clicks and search results. A token names
    /// the registration rather than the address, so unregistering can only remove its own.
    public struct GhosttyMirrorActionHandlerToken: Sendable, Equatable {
        fileprivate let surfaceKey: UInt
        fileprivate let generation: UInt64
    }

    /// The app-process embedded ghostty app runtime that backs the local mirror rendering
    /// (`GhosttyMirrorTerminalView`). It stays on the main actor — the mirror is an `NSView` that ticks
    /// and presents on the render path — while the daemon's `GhosttyEmbeddedAppService` runs on the
    /// terminal engine actor. Splitting the two keeps each process driving its single `ghostty_app_t`
    /// from one executor: the app from main here, the daemon from the engine actor there (see
    /// `GhosttyProcessAppRuntime`'s one-app-per-process contract).
    ///
    /// This exposes only the surface the mirror view uses (`startIfNeeded`, `app`, `tick`,
    /// register/unregister action handlers). The daemon-only appearance controls live on
    /// `GhosttyEmbeddedAppService`.
    @MainActor public final class GhosttyMirrorAppService {
        public static let shared = GhosttyMirrorAppService()

        private struct RegisteredActionHandler {
            let generation: UInt64
            let handler: @MainActor (GhosttyActionEvent) -> Void
        }

        public private(set) var app: ghostty_app_t?
        private var config: ghostty_config_t?
        private var surfaceActionHandlers: [UInt: RegisteredActionHandler] = [:]
        private var lastActionHandlerGeneration: UInt64 = 0

        private init() {}

        public func startIfNeeded() throws {
            guard app == nil else { return }
            try GhosttyProcessAppRuntime.initializeOnce(owner: .mirror)
            let config = try GhosttyProcessAppRuntime.makeThemeConfiguration()

            var runtimeConfig = ghostty_runtime_config_s()
            runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
            runtimeConfig.supports_selection_clipboard = true
            runtimeConfig.wakeup_cb = { _ in Task { @MainActor in GhosttyMirrorAppService.shared.tick() } }
            runtimeConfig.action_cb = { _, target, action in
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
                guard let event = GhosttyActionEventParser.parse(action) else { return true }
                let surfaceKey = UInt(bitPattern: target.target.surface)
                Task { @MainActor in GhosttyMirrorAppService.shared.handleAction(event, surfaceKey: surfaceKey) }
                return true
            }
            runtimeConfig.read_clipboard_cb = { userdata, _, state in GhosttyClipboardBridge.readClipboard(userdata: userdata, state: state) }
            runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
                GhosttyClipboardBridge.confirmReadClipboard(userdata: userdata, content: content, state: state)
            }
            runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in GhosttyClipboardBridge.writeClipboard(content: content, len: UInt(len)) }
            // Mirror surfaces set no `GhosttyEmbeddedSurfaceUserData` (they are not host-managed sessions),
            // so no close_surface_cb is wired — it would never receive a valid userdata here.

            guard let app = ghostty_app_new(&runtimeConfig, config) else {
                ghostty_config_free(config)
                throw GhosttyEmbeddedAppServiceError.configuration("ghostty_app_new failed")
            }
            ghostty_app_set_color_scheme(app, GhosttyProcessAppRuntime.currentColorScheme())
            self.config = config
            self.app = app
        }

        public func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        public func registerActionHandler(for surface: ghostty_surface_t, handler: @escaping @MainActor (GhosttyActionEvent) -> Void)
            -> GhosttyMirrorActionHandlerToken
        {
            lastActionHandlerGeneration &+= 1
            let key = surfaceKey(surface)
            surfaceActionHandlers[key] = RegisteredActionHandler(generation: lastActionHandlerGeneration, handler: handler)
            return GhosttyMirrorActionHandlerToken(surfaceKey: key, generation: lastActionHandlerGeneration)
        }

        public func unregisterActionHandler(_ token: GhosttyMirrorActionHandlerToken?) {
            guard let token, surfaceActionHandlers[token.surfaceKey]?.generation == token.generation else { return }
            surfaceActionHandlers.removeValue(forKey: token.surfaceKey)
        }

        func handleAction(_ event: GhosttyActionEvent, surfaceKey: UInt) {
            guard let registered = surfaceActionHandlers[surfaceKey] else { return }
            Task { @MainActor in registered.handler(event) }
        }

        private func surfaceKey(_ surface: ghostty_surface_t) -> UInt { UInt(bitPattern: surface) }
    }
#endif
