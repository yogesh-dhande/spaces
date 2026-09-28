import Foundation
import spacesterminalcore

/// Newline-delimited framing for the device-overview subscription stream. Each line is a small JSON
/// envelope (`Envelope` below) carrying the overview's JSON as a raw-DEFLATE stream, not the overview
/// JSON itself: an idle-looking desktop still ticks its terminals' title/cwd metadata once a second, and
/// at ~65 KB per overview that tick alone was measured at ~4 MB/min per subscribed device before this
/// codec compressed it. `GhosttyRenderUpdateBodyCompression` is reused rather than a second DEFLATE
/// implementation, the same primitive the render-update and transcript codecs already carry their bytes
/// through (see its doc comment for why raw DEFLATE: no format negotiation between a Linux daemon and a
/// Darwin or Linux client).
///
/// The daemon writes one envelope line per change; the client reads them back the same way (matching the
/// terminal state stream's line framing).
public enum SpacesDeviceOverviewStreamCodec {
    /// `byteCount` is the overview JSON's uncompressed length, which `inflate` needs up front to size its
    /// destination buffer; see `GhosttyRenderUpdateBodyCompression.inflate`.
    private struct Envelope: Codable {
        let deflated: Data
        let byteCount: Int
    }

    public static func encodeLine(_ payload: SpacesDeviceOverviewPayload) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        let deflated = try GhosttyRenderUpdateBodyCompression.deflate(json)
        var data = try JSONEncoder().encode(Envelope(deflated: deflated, byteCount: json.count))
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceOverviewPayload {
        let envelope = try JSONDecoder().decode(Envelope.self, from: line)
        let json = try GhosttyRenderUpdateBodyCompression.inflate(envelope.deflated, expectedLength: envelope.byteCount)
        return try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: json)
    }
}
