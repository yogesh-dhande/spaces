import Foundation

/// Accumulates the leading bytes of an HTTP/1.1 request until the end of the header block
/// (`\r\n\r\n`) so the loopback browser proxy can read the `Host` header and route the connection,
/// then replay every byte it consumed verbatim to the chosen upstream tunnel.
///
/// This type does no networking: the proxy feeds it `Data` chunks as they arrive. It keeps the head
/// bounded (a request whose header block exceeds `maxHeadBytes` is rejected rather than buffered
/// without limit), but once the head is complete it keeps appending later bytes to `consumedBytes`
/// so any request-body bytes that arrived in the same read are replayed too.
struct BrowserProxyHTTPHeadParser {
    enum ParseError: Error, Equatable {
        /// The header block grew past `maxHeadBytes` without a terminator; the client is either not
        /// speaking HTTP or is trying to exhaust memory. Either way the connection is refused.
        case headTooLarge
    }

    /// Cap on the header block. 64 KiB comfortably fits real browser request heads (cookies, long
    /// URLs) while bounding a misbehaving or hostile client.
    static let maxHeadBytes = 64 * 1024

    /// Every byte fed so far, verbatim, for replay to the upstream tunnel.
    private(set) var consumedBytes = Data()
    /// True once the `\r\n\r\n` header terminator has been seen.
    private(set) var isComplete = false
    /// Offset just past the header terminator, so `host` parses only the header block.
    private var headEndIndex: Int?

    /// Feeds another chunk. Throws `.headTooLarge` if the header block exceeds the cap before the
    /// terminator is found.
    mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        consumedBytes.append(data)
        guard !isComplete else { return }
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        if let range = consumedBytes.range(of: terminator) {
            headEndIndex = range.upperBound
            isComplete = true
        } else if consumedBytes.count > Self.maxHeadBytes {
            throw ParseError.headTooLarge
        }
    }

    /// The routing host from the `Host` header: name matched case-insensitively, any `:port` suffix
    /// stripped, lowercased. Nil until the head is complete or if no `Host` header is present.
    var host: String? {
        guard isComplete, let headEndIndex else { return nil }
        let headData = consumedBytes.prefix(headEndIndex)
        // HTTP header bytes are ASCII; ISO Latin-1 decodes any byte without failing.
        guard let headText = String(data: headData, encoding: .isoLatin1) else { return nil }
        // The first line is the request line; skip it and scan header lines for `Host:`.
        for line in headText.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Host") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let stripped = Self.stripPort(value).lowercased()
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    /// Drops the `:port` suffix from a `Host` header value, handling bracketed IPv6 literals.
    private static func stripPort(_ value: String) -> String {
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex)..<close])
            }
            return value
        }
        if let colon = value.lastIndex(of: ":") {
            let portPart = value[value.index(after: colon)...]
            if !portPart.isEmpty, portPart.allSatisfy(\.isNumber) {
                return String(value[..<colon])
            }
        }
        return value
    }
}

/// Canned HTTP error responses the loopback browser proxy returns to WKWebView when it cannot
/// establish an upstream tunnel. Each is a complete, self-contained `Connection: close` response
/// with a compact HTML body that names the service, workspace, and device so the failure is legible
/// in the web view.
enum BrowserProxyErrorResponse {
    /// The proxy could not reach or authenticate to the owning daemon, or the request did not map to
    /// any known workspace service.
    static func badGateway(service: String?, workspace: String?, device: String?, reason: String) -> Data {
        response(status: "502 Bad Gateway", title: "Can’t reach this service", service: service, workspace: workspace, device: device, reason: reason)
    }

    /// The daemon was reached but reported the workspace service is not currently running.
    static func serviceUnavailable(service: String?, workspace: String?, device: String?, reason: String) -> Data {
        response(
            status: "503 Service Unavailable", title: "Service isn’t running", service: service, workspace: workspace, device: device, reason: reason)
    }

    private static func response(status: String, title: String, service: String?, workspace: String?, device: String?, reason: String) -> Data {
        let body = html(status: status, title: title, service: service, workspace: workspace, device: device, reason: reason)
        let bodyData = Data(body.utf8)
        let head =
            "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(head.utf8)
        data.append(bodyData)
        return data
    }

    private static func html(status: String, title: String, service: String?, workspace: String?, device: String?, reason: String) -> String {
        var rows = ""
        func row(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows += "<div class=\"row\"><span class=\"k\">\(escape(label))</span><span class=\"v\">\(escape(value))</span></div>"
        }
        row("Service", service)
        row("Workspace", workspace)
        row("Device", device)
        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            <title>\(escape(title))</title><style>\
            :root{color-scheme:light dark}\
            *{box-sizing:border-box}\
            body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
            font:15px/1.5 -apple-system,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:24px}\
            .card{max-width:420px;width:100%;background:#fff;border:1px solid #e3e3e6;border-radius:14px;padding:22px}\
            h1{margin:0 0 6px;font-size:18px;font-weight:600}\
            .status{margin:0 0 14px;font-size:12px;letter-spacing:.02em;text-transform:uppercase;color:#8a8a8e}\
            .reason{margin:0 0 16px;color:#3a3a3c}\
            .row{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-top:1px solid #ededf0}\
            .k{color:#8a8a8e}.v{font-weight:500;text-align:right;word-break:break-all}\
            @media(prefers-color-scheme:dark){\
            body{background:#000;color:#f5f5f7}\
            .card{background:#1c1c1e;border-color:#2c2c2e}\
            .status{color:#98989d}.reason{color:#c7c7cc}.row{border-top-color:#2c2c2e}.k{color:#98989d}}\
            </style></head><body><div class="card">\
            <p class="status">\(escape(status))</p><h1>\(escape(title))</h1>\
            <p class="reason">\(escape(reason))</p>\(rows)</div></body></html>
            """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
