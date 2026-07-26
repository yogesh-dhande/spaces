import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import UIKit
    import spacesterminalcore

    /// The one Ghostty mirror, and the one renderer surface, the iOS app ever creates.
    ///
    /// A mirror owns an `IOSurface` sized to the screen plus the Metal resources that render into
    /// it — tens of megabytes of process footprint at phone screen sizes. `ghostty_mirror_free`
    /// rebinds the renderer host while tearing the mirror down and can block indefinitely, so it
    /// cannot be called from a user-facing path such as leaving a terminal screen. Creating a
    /// mirror per terminal view therefore grew the footprint by a whole surface for every visit,
    /// with nothing able to give it back.
    ///
    /// So the app creates one mirror lazily and hands it between terminal views instead. The view
    /// that is rendering holds it; a view that mounts while another holds it takes it over, and the
    /// previous holder falls back to its plain black background and re-acquires when it is on
    /// screen again. Only a view that is in a window and has something to render ever asks, so a
    /// takeover always moves the mirror towards the terminal the user is looking at.
    ///
    /// Handing the mirror over re-parents ``surfaceHostView`` into the new holder. The surface host
    /// pointer Ghostty renders against never changes, so the renderer keeps its existing
    /// `IOSurface` and Metal resources across the whole process lifetime: nothing is allocated on
    /// navigation, nothing is freed on navigation, and the footprint is bounded at one mirror
    /// regardless of how many sessions the user opens. Nothing releases the final mirror before
    /// process exit, and nothing should: releasing it is the blocking call this design exists to
    /// avoid, and one parked mirror is the bound.
    @MainActor final class GhosttySharedTerminalMirror {
        static let shared = GhosttySharedTerminalMirror()

        /// The `UIView` Ghostty's renderer binds to (unretained) and hangs its `IOSurface` layer on.
        /// It is process-wide for the same reason the mirror is: the renderer's pixel memory is
        /// attached to this view, so re-parenting it moves the rendered terminal between holders
        /// without reallocating any of it.
        let surfaceHostView = UIView(frame: .zero)

        private var mirror: ghostty_mirror_t?
        private var appliedFontSize: TerminalFontSize?
        private weak var holder: GhosttyRemoteTerminalHostView?

        private init() {
            surfaceHostView.translatesAutoresizingMaskIntoConstraints = false
            surfaceHostView.backgroundColor = .black
            surfaceHostView.isUserInteractionEnabled = false
            // Parked and holding the previous session's pixels until a holder applies a frame of
            // its own, so a rebind can never flash one session's content inside another's view.
            surfaceHostView.isHidden = true
        }

        var liveMirrorCountForTesting: Int { mirror == nil ? 0 : 1 }
        var mirrorSurfaceIdentityForTesting: UInt? { mirror.flatMap(ghostty_mirror_surface).map { surface in UInt(bitPattern: surface) } }
        var isSurfaceHostAttachedForTesting: Bool { surfaceHostView.superview != nil }
        var isSurfaceHostVisibleForTesting: Bool { !surfaceHostView.isHidden }
        var appliedFontSizeForTesting: TerminalFontSize? { appliedFontSize }

        /// Hands the mirror to `view`, creating it the first time anyone asks. Any previous holder
        /// surrenders it first, and the mirror is retuned to `fontSize` if it was built or last used
        /// at a different size.
        func acquire(for view: GhosttyRemoteTerminalHostView, fontSize: TerminalFontSize, scaleFactor: Double) throws -> ghostty_mirror_t {
            if holder !== view {
                holder?.surrenderSharedMirror()
                park()
            }
            attachSurfaceHost(to: view)
            holder = view

            if let mirror {
                applyFontSize(fontSize, to: mirror)
                focusSurface(of: mirror)
                return mirror
            }
            let mirror = try makeMirror(fontSize: fontSize, scaleFactor: scaleFactor)
            self.mirror = mirror
            appliedFontSize = fontSize
            focusSurface(of: mirror)
            return mirror
        }

        /// Parks the mirror when `view` stops rendering. A view that has already lost the mirror to
        /// a newer holder is a no-op here, so a late teardown cannot disturb the current holder.
        func release(from view: GhosttyRemoteTerminalHostView) {
            guard holder === view else { return }
            park()
        }

        /// Retunes the live mirror to a new font size. The mirror is not rebuilt: Ghostty's
        /// `set_font_size` binding action rebuilds the font grid on the existing surface, which
        /// keeps the surface and its renderer resources — the expensive part — in place.
        func setFontSize(_ fontSize: TerminalFontSize, from view: GhosttyRemoteTerminalHostView) {
            guard holder === view, let mirror else { return }
            applyFontSize(fontSize, to: mirror)
        }

        /// Shows the surface once `view` has applied a frame of its own session to it.
        func revealSurface(from view: GhosttyRemoteTerminalHostView) {
            guard holder === view else { return }
            surfaceHostView.isHidden = false
        }

        /// Describes the shared surface host to Ghostty. The renderer holds the view unretained, which
        /// is safe precisely because this one view outlives every holder.
        func makeSurfaceHost(scaleFactor: Double) -> ghostty_surface_host_s {
            var host = ghostty_surface_host_s()
            host.platform_tag = GHOSTTY_PLATFORM_IOS
            host.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(surfaceHostView).toOpaque()))
            host.scale_factor = scaleFactor
            return host
        }

        /// Refocuses the surface for its incoming holder. ``park()`` unfocuses the one surface every
        /// holder shares, and Ghostty draws an unfocused surface with a hollow, non-blinking cursor,
        /// so without this the second and every later terminal the user opens would show a dead
        /// cursor. Ghostty builds a surface focused, so this is a no-op on the very first acquire; it
        /// is stated anyway so the pairing with `park()` is visible here rather than resting on a
        /// default in Ghostty. The other half of what `park()` clears, occlusion, is restored by the
        /// holder's geometry pass, which re-runs on acquire.
        private func focusSurface(of mirror: ghostty_mirror_t) {
            guard let surface = ghostty_mirror_surface(mirror) else { return }
            ghostty_surface_set_focus(surface, true)
        }

        private func park() {
            surfaceHostView.isHidden = true
            surfaceHostView.removeFromSuperview()
            if let surface = mirror.flatMap(ghostty_mirror_surface) {
                GhosttyMobileAppService.shared.unregisterActionHandler(for: surface)
                ghostty_surface_set_focus(surface, false)
                ghostty_surface_set_occlusion(surface, false)
            }
            holder = nil
        }

        private func attachSurfaceHost(to view: GhosttyRemoteTerminalHostView) {
            guard surfaceHostView.superview !== view else { return }
            surfaceHostView.removeFromSuperview()
            view.insertSubview(surfaceHostView, at: 0)
            NSLayoutConstraint.activate([
                surfaceHostView.topAnchor.constraint(equalTo: view.topAnchor), surfaceHostView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surfaceHostView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surfaceHostView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            // Ghostty sizes its render target from the host layer's bounds, and a layer attached to
            // a zero-sized view never grows back, so the freshly constrained subview has to be laid
            // out before the mirror binds to it.
            view.layoutIfNeeded()
        }

        private func makeMirror(fontSize: TerminalFontSize, scaleFactor: Double) throws -> ghostty_mirror_t {
            try GhosttyMobileAppService.shared.startIfNeeded()
            guard let app = GhosttyMobileAppService.shared.app else { throw GhosttyMobileAppServiceError.configuration("ghostty app missing") }
            var host = makeSurfaceHost(scaleFactor: scaleFactor)
            var config = ghostty_session_config_new()
            config.surface.platform_tag = host.platform_tag
            config.surface.platform = host.platform
            config.surface.scale_factor = host.scale_factor
            config.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            config.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.surface.font_size = Float(fontSize.points)
            config.parked_host = host
            guard let mirror = ghostty_mirror_new(app, &host, &config) else {
                throw GhosttyMobileAppServiceError.configuration("ghostty_mirror_new failed")
            }
            return mirror
        }

        private func applyFontSize(_ fontSize: TerminalFontSize, to mirror: ghostty_mirror_t) {
            guard appliedFontSize != fontSize, let surface = ghostty_mirror_surface(mirror) else { return }
            let action = "set_font_size:\(fontSize.points)"
            let applied = action.withCString { pointer in ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count)) }
            guard applied else { return }
            appliedFontSize = fontSize
            ghostty_surface_refresh(surface)
        }
    }
#endif
