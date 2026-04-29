import AppKit
import spacesui

@main struct Spaces {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppKitController()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // Set app icon when running outside a proper .app bundle (dev builds).
        // The binary embeds Info.plist via a linker section, so bundleIdentifier is non-nil
        // even without a bundle — use the bundle URL extension to detect a real .app bundle.
        if Bundle.main.bundleURL.pathExtension != "app", let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            app.applicationIconImage = icon
        }
        app.run()
    }
}
