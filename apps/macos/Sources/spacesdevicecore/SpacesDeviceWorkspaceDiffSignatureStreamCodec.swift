import Foundation

/// Newline-delimited JSON framing for the `subscribeWorkspaceDiffSignature` stream.
/// The daemon writes one `SpacesDeviceWorkspaceDiffSignatureFrame` line whenever the
/// subscribed workspace's `scopeSignature` changes; the client reads them back the
/// same way (matching the device-overview stream's line framing).
public enum SpacesDeviceWorkspaceDiffSignatureStreamCodec {
    public static func encodeLine(_ frame: SpacesDeviceWorkspaceDiffSignatureFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceWorkspaceDiffSignatureFrame {
        try JSONDecoder().decode(SpacesDeviceWorkspaceDiffSignatureFrame.self, from: line)
    }
}
