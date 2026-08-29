import Foundation

/// Newline-delimited JSON framing for the `subscribeWorkspaceFileListSignature` stream.
/// The daemon writes one `SpacesDeviceWorkspaceFileListSignatureFrame` line whenever the
/// subscribed workspace's authoritative `workspaceFileList` result changes; the client reads
/// them back the same way.
public enum SpacesDeviceWorkspaceFileListSignatureStreamCodec {
    public static func encodeLine(_ frame: SpacesDeviceWorkspaceFileListSignatureFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> SpacesDeviceWorkspaceFileListSignatureFrame {
        try JSONDecoder().decode(SpacesDeviceWorkspaceFileListSignatureFrame.self, from: line)
    }
}
