#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

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

        public private(set) var app: ghostty_app_t?
        private var config: ghostty_config_t?
        private var surfaceActionHandlers: [UInt: @MainActor (GhosttyActionEvent) -> Void] = [:]

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

        public func registerActionHandler(for surface: ghostty_surface_t, handler: @escaping @MainActor (GhosttyActionEvent) -> Void) {
            surfaceActionHandlers[surfaceKey(surface)] = handler
        }

        public func unregisterActionHandler(for surface: ghostty_surface_t?) {
            guard let surface else { return }
            surfaceActionHandlers.removeValue(forKey: surfaceKey(surface))
        }

        private func handleAction(_ event: GhosttyActionEvent, surfaceKey: UInt) {
            guard let handler = surfaceActionHandlers[surfaceKey] else { return }
            Task { @MainActor in handler(event) }
        }

        private func surfaceKey(_ surface: ghostty_surface_t) -> UInt { UInt(bitPattern: surface) }
    }
#endif
