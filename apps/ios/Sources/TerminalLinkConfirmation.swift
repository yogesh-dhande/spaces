import Foundation
import spacesdevicecore

/// A tapped terminal link waiting on the user's Open Link, Copy Link or Cancel answer.
///
/// The terminal view hands the dialog's buttons this value rather than letting them read it back from the
/// model: SwiftUI clears the presentation as a button fires, and the model state clears with it before an
/// asynchronous Open runs.
struct TerminalLinkConfirmation: Equatable {
    /// What Open Link does.
    enum Destination: Equatable {
        /// Route the link string through the model's link-open path (web preview, file fetch).
        case routedLink(String)
        /// Hand the URL to the system, which picks the app registered for it (a mail client, a custom scheme).
        case systemURL(URL)
    }

    let title: String
    /// The sanitized target shown in full under the title, and what Copy Link copies.
    let displayString: String
    let destination: Destination

    /// The title for a link with a URL: the address of a `mailto:`, the file name of a file URL, otherwise
    /// the host, falling back to the whole target for a URL with none.
    ///
    /// Titles come from decoded URL parts (Foundation percent-decodes them), so an encoded bidi override or
    /// newline would otherwise reach the prominent title; they are escaped for that reason.
    static func title(for url: URL, displayString: String) -> String {
        if url.scheme?.lowercased() == "mailto", let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, !address.isEmpty {
            return SpacesUntrustedTerminalLink.escapingUnsafeCharacters(address)
        }
        if url.isFileURL {
            return url.lastPathComponent.isEmpty ? displayString : SpacesUntrustedTerminalLink.escapingUnsafeCharacters(url.lastPathComponent)
        }
        if let host = url.host, !host.isEmpty { return SpacesUntrustedTerminalLink.escapingUnsafeCharacters(host) }
        return displayString
    }

    /// The title for a file link, which is a `file://` URL or a bare, tilde or relative path. Escaped like
    /// `title(for:displayString:)`, because a `file://` name is percent-decoded.
    static func title(forFileLink raw: String, displayString: String) -> String {
        let name = URL(string: raw).flatMap { $0.isFileURL ? $0.lastPathComponent : nil } ?? (raw as NSString).lastPathComponent
        return name.isEmpty ? displayString : SpacesUntrustedTerminalLink.escapingUnsafeCharacters(name)
    }
}
