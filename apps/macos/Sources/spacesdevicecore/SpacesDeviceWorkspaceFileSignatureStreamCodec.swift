import Foundation

/// Newline-delimited JSON framing for the `subscribeWorkspaceFileSignature` stream.
/// The daemon writes one `SpacesDeviceWorkspaceFileSignatureFrame` line whenever the
/// subscribed file's `sha256`/`missing` state changes; the client reads them back the
/// same way (matching the device-overview stream's line framing).
public enum SpacesDeviceWorkspaceFileSignatureStreamCodec {
    public static func encodeLine(_ frame: SpacesDeviceWorkspaceFileSignatureFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceWorkspaceFileSignatureFrame {
        try JSONDecoder().decode(SpacesDeviceWorkspaceFileSignatureFrame.self, from: line)
    }
}
