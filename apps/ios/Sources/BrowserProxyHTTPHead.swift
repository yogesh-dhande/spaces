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
    enum RequestBodyFraming: Equatable, Sendable {
        case none
        case contentLength(Int)
        case chunked
    }

    struct ChunkedBodyProgress: Equatable, Sendable {
        let forwardedByteCount: Int
        let isComplete: Bool
    }

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
            guard range.upperBound <= Self.maxHeadBytes else { throw ParseError.headTooLarge }
            headEndIndex = range.upperBound
            isComplete = true
        } else if consumedBytes.count > Self.maxHeadBytes {
            throw ParseError.headTooLarge
        }
    }

    /// The routing host from the `Host` header: name matched case-insensitively, any `:port` suffix
    /// stripped, lowercased. Nil until the head is complete or if no `Host` header is present.
    var host: String? {
        for value in headerValues(named: "Host") {
            let stripped = Self.stripPort(value).lowercased()
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    func cookieValue(named cookieName: String) -> String? {
        for header in headerValues(named: "Cookie") {
            for part in header.split(separator: ";", omittingEmptySubsequences: false) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let name = trimmed[..<equals]
                guard name == cookieName else { continue }
                return String(trimmed[trimmed.index(after: equals)...])
            }
        }
        return nil
    }

    var isUpgradeRequest: Bool {
        guard !headerValues(named: "Upgrade").isEmpty else { return false }
        return headerValues(named: "Connection").contains { value in
            value.split(separator: ",").contains { token in
                token.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("upgrade") == .orderedSame
            }
        }
    }

    var contentLength: Int? {
        for value in headerValues(named: "Content-Length") {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard let length = Int(trimmed), length >= 0 else { continue }
            return length
        }
        return nil
    }

    var bodyFraming: RequestBodyFraming {
        if transferEncodingTokens.contains(where: { $0.caseInsensitiveCompare("chunked") == .orderedSame }) { return .chunked }
        guard let contentLength, contentLength > 0 else { return .none }
        return .contentLength(contentLength)
    }

    var bodyByteCount: Int {
        guard isComplete, let headEndIndex else { return 0 }
        return consumedBytes.count - headEndIndex
    }

    var chunkedBodyProgress: ChunkedBodyProgress? { Self.chunkedBodyProgress(in: bodyBytes()) }

    func bodyBytes(limit: Int? = nil) -> Data {
        guard isComplete, let headEndIndex else { return Data() }
        let fullBody = consumedBytes[headEndIndex...]
        guard let limit else { return Data(fullBody) }
        return Data(fullBody.prefix(max(0, min(limit, fullBody.count))))
    }

    static func chunkedBodyProgress(in body: Data) -> ChunkedBodyProgress? {
        var tracker = BrowserProxyChunkedBodyTracker()
        return tracker.consume(body)
    }

    func consumedBytes(droppingCookieNamed cookieName: String, forcingConnectionClose: Bool = false, bodyLimit: Int? = nil) -> Data {
        guard isComplete, let headEndIndex, let headText else { return consumedBytes }
        let fullBody = consumedBytes[headEndIndex...]
        let body = if let bodyLimit { fullBody.prefix(max(0, min(bodyLimit, fullBody.count))) } else { fullBody }
        var sanitizedLines: [String] = []
        var addedConnectionClose = false
        for line in headText.components(separatedBy: "\r\n") {
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                sanitizedLines.append(line)
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if forcingConnectionClose,
                name.caseInsensitiveCompare("Connection") == .orderedSame || name.caseInsensitiveCompare("Proxy-Connection") == .orderedSame
                    || name.caseInsensitiveCompare("Keep-Alive") == .orderedSame
            {
                if name.caseInsensitiveCompare("Connection") == .orderedSame, !addedConnectionClose {
                    sanitizedLines.append("Connection: close")
                    addedConnectionClose = true
                }
                continue
            }
            guard name.caseInsensitiveCompare("Cookie") == .orderedSame else {
                sanitizedLines.append(line)
                continue
            }
            let value = line[line.index(after: colon)...]
            let remaining = value.split(separator: ";", omittingEmptySubsequences: false).compactMap { part -> String? in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { return trimmed.isEmpty ? nil : trimmed }
                return trimmed[..<equals] == cookieName ? nil : trimmed
            }
            if !remaining.isEmpty { sanitizedLines.append("Cookie: \(remaining.joined(separator: "; "))") }
        }
        if forcingConnectionClose, !addedConnectionClose { sanitizedLines.append("Connection: close") }
        var sanitized = sanitizedLines.joined(separator: "\r\n").data(using: .isoLatin1)!
        sanitized.append(Data("\r\n\r\n".utf8))
        sanitized.append(body)
        return sanitized
    }

    private var headText: String? {
        guard isComplete, let headEndIndex else { return nil }
        // HTTP header bytes are ASCII; ISO Latin-1 decodes any byte without failing.
        return String(data: consumedBytes.prefix(headEndIndex), encoding: .isoLatin1)
    }

    private func headerValues(named headerName: String) -> [String] {
        guard let headText else { return [] }
        return headText.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            if line.isEmpty { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(headerName) == .orderedSame else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    private var transferEncodingTokens: [String] {
        headerValues(named: "Transfer-Encoding").flatMap { value in
            value.split(separator: ",").map { token in token.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Drops the `:port` suffix from a `Host` header value, handling bracketed IPv6 literals.
    private static func stripPort(_ value: String) -> String {
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") { return String(value[value.index(after: value.startIndex)..<close]) }
            return value
        }
        if let colon = value.lastIndex(of: ":") {
            let portPart = value[value.index(after: colon)...]
            if !portPart.isEmpty, portPart.allSatisfy(\.isNumber) { return String(value[..<colon]) }
        }
        return value
    }
}

struct BrowserProxyChunkedBodyTracker: Sendable {
    private enum State: Sendable {
        case chunkSizeLine([UInt8])
        case chunkData(remaining: Int)
        case chunkDataTerminator(bytesSeen: Int)
        case trailerLine([UInt8])
        case complete
    }

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A

    private var state: State = .chunkSizeLine([])

    mutating func consume(_ data: Data) -> BrowserProxyHTTPHeadParser.ChunkedBodyProgress? {
        var index = data.startIndex
        var forwardedByteCount = 0

        while index < data.endIndex {
            switch state {
            case .complete: return BrowserProxyHTTPHeadParser.ChunkedBodyProgress(forwardedByteCount: forwardedByteCount, isComplete: true)

            case .chunkSizeLine(var line):
                while index < data.endIndex {
                    let byte = data[index]
                    line.append(byte)
                    index = data.index(after: index)
                    forwardedByteCount += 1
                    guard line.count <= BrowserProxyHTTPHeadParser.maxHeadBytes else { return nil }
                    if line.endsWithCRLF {
                        guard let chunkSize = Self.parseChunkSize(line.dropLast(2)) else { return nil }
                        state = chunkSize == 0 ? .trailerLine([]) : .chunkData(remaining: chunkSize)
                        break
                    }
                }
                if case .chunkSizeLine = state { state = .chunkSizeLine(line) }

            case .chunkData(let remaining):
                let available = data.distance(from: index, to: data.endIndex)
                let count = min(remaining, available)
                index = data.index(index, offsetBy: count)
                forwardedByteCount += count
                let nextRemaining = remaining - count
                state = nextRemaining == 0 ? .chunkDataTerminator(bytesSeen: 0) : .chunkData(remaining: nextRemaining)

            case .chunkDataTerminator(var bytesSeen):
                while index < data.endIndex, bytesSeen < 2 {
                    let expected = bytesSeen == 0 ? Self.carriageReturn : Self.lineFeed
                    guard data[index] == expected else { return nil }
                    index = data.index(after: index)
                    forwardedByteCount += 1
                    bytesSeen += 1
                }
                state = bytesSeen == 2 ? .chunkSizeLine([]) : .chunkDataTerminator(bytesSeen: bytesSeen)

            case .trailerLine(var line):
                while index < data.endIndex {
                    let byte = data[index]
                    line.append(byte)
                    index = data.index(after: index)
                    forwardedByteCount += 1
                    guard line.count <= BrowserProxyHTTPHeadParser.maxHeadBytes else { return nil }
                    if line.endsWithCRLF {
                        if line.count == 2 {
                            state = .complete
                            return BrowserProxyHTTPHeadParser.ChunkedBodyProgress(forwardedByteCount: forwardedByteCount, isComplete: true)
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                }
                if case .trailerLine = state { state = .trailerLine(line) }
            }
        }

        let isComplete: Bool
        if case .complete = state { isComplete = true } else { isComplete = false }
        return BrowserProxyHTTPHeadParser.ChunkedBodyProgress(forwardedByteCount: forwardedByteCount, isComplete: isComplete)
    }

    private static func parseChunkSize(_ bytes: ArraySlice<UInt8>) -> Int? {
        let sizeBytes = bytes.prefix { $0 != UInt8(ascii: ";") }.trimmedHTTPWhitespace
        guard !sizeBytes.isEmpty else { return nil }
        var value = 0
        for byte in sizeBytes {
            let digit: Int
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
            guard value <= (Int.max - digit) / 16 else { return nil }
            value = value * 16 + digit
        }
        return value
    }
}

extension Array where Element == UInt8 { fileprivate var endsWithCRLF: Bool { count >= 2 && self[count - 2] == 0x0D && self[count - 1] == 0x0A } }

extension ArraySlice where Element == UInt8 {
    fileprivate var trimmedHTTPWhitespace: ArraySlice<UInt8> {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == UInt8(ascii: " ") || self[start] == UInt8(ascii: "\t") { start = index(after: start) }
        while start < end {
            let previous = index(before: end)
            guard self[previous] == UInt8(ascii: " ") || self[previous] == UInt8(ascii: "\t") else { break }
            end = previous
        }
        return self[start..<end]
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

    /// The request named a routable local proxy host but did not carry the unguessable cookie issued
    /// for the embedded browser session, so the proxy refuses it before opening a daemon tunnel.
    static func forbidden(service: String?, workspace: String?, device: String?, reason: String) -> Data {
        response(status: "403 Forbidden", title: "Can’t open this service", service: service, workspace: workspace, device: device, reason: reason)
    }

    private static func response(status: String, title: String, service: String?, workspace: String?, device: String?, reason: String) -> Data {
        let body = html(status: status, title: title, service: service, workspace: workspace, device: device, reason: reason)
        let bodyData = Data(body.utf8)
        let head =
            "HTTP/1.1 \(status)\r\n" + "Content-Type: text/html; charset=utf-8\r\n" + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n" + "\r\n"
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
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
