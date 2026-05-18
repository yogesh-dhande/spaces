import AppKit
import Darwin
import spacesui
import workspacecore

@main struct Spaces {
    static func main() {
        let launchContext: SpacesAppLaunchContext
        do { launchContext = try SpacesLeaseCoordinator.prepareAppLaunchContext() } catch SpacesAppLaunchPreparationError.duplicateProfileOwner(
            let profile, let owner)
        {
            fputs("Spaces is already running for profile \(profile.rootDirectory) (pid \(owner.pid), executable \(owner.executablePath)).\n", stderr)
            Darwin.exit(1)
        } catch {
            fputs("Spaces failed to prepare launch context: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }

        let app = NSApplication.shared
        let delegate = AppKitController(launchContext: launchContext)
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
