import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct AppearanceReactiveLayerTests {
    /// A dynamic color that is pure black in light and pure white in dark, so the resolved
    /// layer color unambiguously identifies which variant the binder applied.
    private func blackWhiteDynamic() -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
        }
    }

    private func layerWhiteComponent(_ view: NSView) -> CGFloat? {
        guard let cg = view.layer?.backgroundColor, let ns = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return nil }
        return ns.redComponent
    }

    @Test func rebindsLayerColorWhenAppearanceChanges() {
        // Drive the view's own appearance (what the binder reads) rather than NSApp, which
        // isn't initialized in a plain test process.
        let view = NSView()
        view.appearance = NSAppearance(named: .darkAqua)
        let color = blackWhiteDynamic()
        bindAppearanceReactiveLayer(view) { $0.layer?.backgroundColor = color.cgColor }

        // Dark resolves to white (component ≈ 1).
        #expect((layerWhiteComponent(view) ?? 0) > 0.9)

        // Flip the view's appearance and fire the same notification the setting change posts.
        view.appearance = NSAppearance(named: .aqua)
        NotificationCenter.default.post(name: .spacesAppAppearanceDidChange, object: nil)

        // Light resolves to black (component ≈ 0) — proving the snapshot was re-resolved.
        #expect((layerWhiteComponent(view) ?? 1) < 0.1)
    }
}
