import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Decodes the OSC 7 working-directory payload a terminal program reports.
///
/// libghostty-vt stores the OSC 7 payload verbatim — it never parses the URI — so a caller reading
/// the VT layer's pwd gets `file://host/path` rather than a path. Ghostty's own full-surface path
/// does the parse in `stream_handler.zig` before handing a working directory to the app, so this
/// type reproduces those rules for callers that only have the VT layer: recognize the two schemes
/// Ghostty accepts, reject a host that is not this machine (anyone on the far end of an SSH session
/// can send an OSC 7 for a path that does not exist locally), percent-unescape, and require an
/// absolute path. Anything else is ignored rather than guessed at.
public enum TerminalWorkingDirectoryURI {
    /// This machine's hostname, resolved once. OSC 7 host validation compares against it on every
    /// terminal output tick, and the value is fixed for the life of the process.
    public static let localHostName: String? = readLocalHostName()

    /// The absolute local path `payload` names, or nil when the payload is not a usable local
    /// working-directory URI. `localHostName` is a parameter so tests can pin host validation
    /// instead of depending on the machine they run on.
    public static func decodedPath(fromOSC7 payload: String, localHostName: String? = TerminalWorkingDirectoryURI.localHostName) -> String? {
        guard let separator = payload.range(of: "://") else { return nil }
        let scheme = String(payload[payload.startIndex..<separator.lowerBound])
        // `kitty-shell-cwd` carries an already-unencoded path; `file` is percent-encoded.
        let percentEncoded: Bool
        switch scheme {
        case "file": percentEncoded = true
        case "kitty-shell-cwd": percentEncoded = false
        default: return nil
        }

        let remainder = payload[separator.upperBound...]
        // The authority runs to the first "/", which also begins the path — so the path is absolute
        // by construction. No "/" at all means the payload names no directory.
        guard let pathStart = remainder.firstIndex(of: "/") else { return nil }
        let host = String(remainder[remainder.startIndex..<pathStart])
        guard isLocalHost(host, localHostName: localHostName) else { return nil }

        let rawPath = String(remainder[pathStart...])
        return percentEncoded ? rawPath.removingPercentEncoding : rawPath
    }

    /// Mirrors Ghostty's OSC 7 host check: only "localhost" and this machine's own hostname are
    /// local. An empty authority (`file:///path`) is rejected even though RFC 8089 reads it as
    /// "this machine", because Ghostty rejects it (`hostname.isLocal("")` is false) — so the macOS
    /// core never sees such a report, and accepting it here would both diverge the two cores and
    /// hand anything on the far end of an SSH session a trivial way around the host check.
    private static func isLocalHost(_ host: String, localHostName: String?) -> Bool {
        if host == "localhost" { return true }
        guard let localHostName, !localHostName.isEmpty else { return false }
        return host == localHostName
    }

    private static func readLocalHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}
