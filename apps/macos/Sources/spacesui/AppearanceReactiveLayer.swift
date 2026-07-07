import AppKit

extension Notification.Name {
    /// Posted after the app-wide `NSApp.appearance` override changes (see
    /// `AppKitController.applyAppAppearance`). Layer-backed chrome listens for this to
    /// re-resolve `CGColor`s, which — unlike dynamic `NSColor`s — snapshot at assignment
    /// and otherwise keep the launch-time light/dark variant until relaunch.
    static let spacesAppAppearanceDidChange = Notification.Name("spacesAppAppearanceDidChange")
}

/// Keeps a layer-backed view's `CGColor` properties in sync with the app appearance.
///
/// A `CGColor` assigned from a dynamic `NSColor` (e.g. `Theme.border.cgColor`) captures the
/// color for the appearance current at assignment and never updates again. This binder re-runs
/// the caller's color assignment — under the view's current `effectiveAppearance` so the dynamic
/// `NSColor` resolves to the right variant — both immediately and every time the appearance
/// changes. The binder is retained by the view via an associated object, so it lives exactly as
/// long as the view and removes its observer on deinit.
@MainActor func bindAppearanceReactiveLayer(_ view: NSView, apply: @escaping @MainActor (NSView) -> Void) {
    view.wantsLayer = true
    let binder = AppearanceReactiveLayerBinder(view: view, apply: apply)
    objc_setAssociatedObject(view, &appearanceReactiveLayerBinderKey, binder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private nonisolated(unsafe) var appearanceReactiveLayerBinderKey = 0

@MainActor private final class AppearanceReactiveLayerBinder: NSObject {
    private weak var view: NSView?
    private let apply: @MainActor (NSView) -> Void

    init(view: NSView, apply: @escaping @MainActor (NSView) -> Void) {
        self.view = view
        self.apply = apply
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceDidChange), name: .spacesAppAppearanceDidChange, object: nil)
        run()
    }

    @objc private func appearanceDidChange() { run() }

    private func run() {
        guard let view else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { apply(view) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
