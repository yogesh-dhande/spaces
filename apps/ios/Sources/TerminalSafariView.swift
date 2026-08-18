import SafariServices
import SwiftUI

/// Wraps `SFSafariViewController` for presenting a resolved terminal link's plain web page. Unlike the
/// isolated `TerminalWebArtifactView` used for previewable artifacts, `SFSafariViewController` shares
/// the device's per-app persistent website data, so an authenticated link (e.g. a claude.ai artifact)
/// keeps its cookies and gets autofill/passkey support. Default configuration, no custom chrome:
/// Safari supplies its own Done button and toolbar.
struct TerminalSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.view.accessibilityIdentifier = "terminal.safariLink"
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
