import Foundation

/// Newline-delimited JSON framing for the device-overview subscription stream.
/// The daemon writes one `SpacesDeviceOverviewPayload` line per change; the
/// client reads them back the same way (matching the terminal state stream's
/// line framing).
public enum SpacesDeviceOverviewStreamCodec {
    public static func encodeLine(_ payload: SpacesDeviceOverviewPayload) throws -> Data {
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceOverviewPayload {
        try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: line)
    }
}
