import AppKit
import gui

@main struct SpaceshipApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppKitController()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
