import Foundation

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// The open policy for a hyperlink a program put in the terminal's output (OSC 8). The target is
/// producer-controlled text, so it is classified before anything dispatches it; Ghostty's own macOS
/// app applies the same rules to OSC 8 targets, and this type is their port.
///
/// The policy only decides allow, confirm or deny. How an allowed link is opened (browser, loopback
/// notice, remote file fetch, in-app preview, `spaces://` focus) stays with the clients' routing.
///
/// - Allowed: `http`/`https` with a host, `mailto` with an address, a Spaces terminal deep link
///   (an in-app focus that never leaves the app), and a `file://` link that passes the file checks.
/// - Confirmed: every other scheme. A custom scheme can invoke any application registered with the
///   system, so the user is shown the target first.
/// - Denied: an empty target, one with control or bidirectional characters, one without an explicit
///   scheme (so a later layer cannot reinterpret it as a local path), a web link without a host, and
///   a file link that fails the file checks.
public struct SpacesUntrustedTerminalLink: Equatable, Sendable {
    public enum DenialReason: Equatable, Sendable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        public var message: String {
            switch self {
            case .malformedURL: return "The target is not an absolute URL with a scheme."
            case .unsafeCharacters: return "The target contains invisible or line-breaking characters."
            case .invalidWebURL: return "The web target does not contain a valid host."
            case .inaccessibleFile: return "The local target does not exist or is not a regular file or directory."
            case .unsafeFile: return "Opening this local target could execute code."
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow(URL)
        case confirm(URL)
        case deny(DenialReason)
    }

    /// Where a `file://` link's file lives. The existence and type checks have to run on the machine
    /// that holds the file: a link printed by a session on another device names that device's disk, and
    /// this machine's disk says nothing about it.
    public enum FileLocation: Sendable {
        /// The file is on this machine: the policy inspects it, and an allowed file link carries the
        /// canonical (symlink-resolved) URL, so what is opened is what was checked.
        case thisDevice
        /// The file is on another device: only the link's shape is checked here. The device's link
        /// resolver checks the file itself before anything is fetched: an existing, readable regular file
        /// in a location it allows, of a type Spaces previews. Accepted: it does not apply this policy's
        /// executable-bit and unsafe-type checks. Those guard against the system running what it opens,
        /// and a remote file is only fetched as a copy and previewed, never run; a type that would run
        /// has no preview kind, so the resolver already refuses it. The same resolver serves detected
        /// links, where previewing an executable script is wanted.
        case anotherDevice
    }

    public let string: String

    public init(_ string: String) { self.string = string }

    public func decision(fileLocation: FileLocation) -> Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation accepts many control and formatting characters in a URL, and UI text can render
        // them as line breaks, zero-width text or bidirectional overrides. They are rejected before
        // parsing changes their representation.
        guard !string.unicodeScalars.contains(where: Self.isUnsafeCharacter) else { return .deny(.unsafeCharacters) }

        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .deny(.malformedURL) }

        switch scheme {
        case "http", "https":
            // "https:relative" has a scheme but no authority, and consumers resolve it differently.
            guard let host = url.host, !host.isEmpty else { return .deny(.invalidWebURL) }
            return .allow(url)
        case "mailto":
            // The address of a mailto URL is its path; a bare "mailto:" must not open an empty message.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), !components.path.isEmpty else {
                return .deny(.malformedURL)
            }
            return .allow(url)
        case "file": return fileDecision(for: url, fileLocation: fileLocation)
        case SpacesTerminalDeepLink.scheme: return SpacesTerminalDeepLink.parse(url) != nil ? .allow(url) : .confirm(url)
        default: return .confirm(url)
        }
    }

    /// A single-line form of the target, for the confirmation, the blocked notice and the hover readout.
    /// The shown target must be the one that opens, and only this device's files can be resolved here:
    ///
    /// - A `file:` URL is shown as its path with dot segments and repeated separators removed, on every
    ///   location, so traversal cannot make the shown and opened targets differ. Symlinks are resolved
    ///   only for `.thisDevice`, matching what opening does there; another device's symlinks are its own.
    /// - A target without a scheme is shown as written. It is never resolved against this process's
    ///   working directory: a detected relative path opens relative to the session's directory, which
    ///   this process does not know.
    /// - Any other URL is kept byte for byte, because repeated separators can matter to a web or
    ///   custom-scheme handler.
    ///
    /// Unsafe characters are escaped last, so none can survive as a second line or a hidden run.
    public func displayString(fileLocation: FileLocation) -> String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            if !url.isFileURL {
                normalized = string
            } else if fileLocation == .thisDevice {
                normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
            } else {
                normalized = Self.lexicallyStandardized(path: url.path)
            }
        } else {
            normalized = string
        }

        return Self.escapingUnsafeCharacters(normalized)
    }

    /// Writes each unsafe character (control, bidi override, invisible) as `\u{HEX}`. Anything shown
    /// prominently that is derived from a link, including parts Foundation percent-decodes, goes through
    /// this so a hidden character cannot disguise the destination.
    public static func escapingUnsafeCharacters(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

extension SpacesUntrustedTerminalLink {
    /// Removes `.`, `..` and empty segments from an absolute path without touching the filesystem.
    /// `URL.standardizedFileURL` consults the disk (for example to drop a `/private` prefix), which
    /// would answer for this machine's files rather than the device the path names.
    private static func lexicallyStandardized(path: String) -> String {
        var segments: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." { _ = segments.popLast() } else { segments.append(segment) }
        }
        return "/" + segments.joined(separator: "/")
    }

    private func fileDecision(for url: URL, fileLocation: FileLocation) -> Decision {
        // A query or fragment names no part of a filesystem object, and handlers read them inconsistently.
        guard url.isFileURL, url.query == nil, url.fragment == nil else { return .deny(.malformedURL) }

        // An empty host and localhost both mean the machine the link was printed on. A named host could
        // trigger network access.
        if let host = url.host, !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame { return .deny(.malformedURL) }

        switch fileLocation {
        case .anotherDevice: return .allow(url)
        case .thisDevice: return localFileDecision(for: url)
        }
    }

    /// Classifies the effective object, not the spelling the program supplied: dot traversal collapses and
    /// a harmless-looking symlink name cannot hide an executable target.
    private func localFileDecision(for url: URL) -> Decision {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var keys: Set<URLResourceKey> = [.isDirectoryKey, .isExecutableKey, .isRegularFileKey]
        #if canImport(UniformTypeIdentifiers)
            keys.insert(.contentTypeKey)
        #endif
        let values: URLResourceValues
        do {
            // Reading the keys together also proves the canonical target exists and is accessible.
            values = try canonicalURL.resourceValues(forKeys: keys)
        } catch { return .deny(.inaccessibleFile) }
        // Devices, sockets and other special objects are out. A directory is safe to reveal unless its
        // extension or type marks it as an application bundle.
        guard values.isDirectory == true || values.isRegularFile == true else { return .deny(.inaccessibleFile) }
        guard !Self.isUnsafeFile(canonicalURL, values: values) else { return .deny(.unsafeFile) }
        return .allow(canonicalURL)
    }

    private static func isUnsafeFile(_ url: URL, values: URLResourceValues) -> Bool {
        // The system picks a handler by extension, so known executable containers are blocked even with
        // the executable bit clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) { return true }
        #if canImport(UniformTypeIdentifiers)
            // Types cover files whose extension is missing or misleading. The broad system-declared
            // types include subclasses such as shell scripts and application bundles.
            if let contentType = values.contentType, unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) { return true }
        #endif
        // Any regular file the filesystem marks executable, whatever its name or detected type.
        return values.isDirectory != true && values.isExecutable == true
    }

    private static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 and C1 controls: CR, LF, NEL and other non-printing bytes.
        case 0x00...0x1F, 0x7F...0x9F: return true
        // Directional marks and zero-width characters reorder or conceal parts of a target without
        // changing what the handler receives.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        // Line and paragraph separators draw extra visual lines in text views.
        case 0x2028...0x2029: return true
        // Word joiner and BOM are invisible padding that can disguise identical-looking targets.
        case 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    private static let unsafePathExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop", "inetloc", "jar", "mobileconfig", "mpkg", "pkg", "scpt", "terminal", "tool",
        "url", "webloc", "workflow",
    ]

    #if canImport(UniformTypeIdentifiers)
        private static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
    #endif
}
