import Foundation

public enum GhosttyRenderFrameMetrics {
    public static func attributes(
        reason: String? = nil, frame: GhosttyRenderFrame?, frameByteCount: Int? = nil, frameEncodeMS: Int? = nil, payloadByteCount: Int? = nil,
        payloadEncodeMS: Int? = nil, decodeMS: Int? = nil, outputByteCount: Int? = nil, screenStateRevision: UInt64? = nil, dropped: Bool? = nil,
        dropReason: String? = nil, renderMode: String? = nil, frameKind: String = "full", baseRevision: UInt64? = nil, targetRevision: UInt64? = nil,
        appliedRevision: UInt64? = nil, applyMS: Int? = nil
    ) -> [String: String] {
        let resolvedTargetRevision = targetRevision ?? screenStateRevision ?? frame?.sessionRevision
        var attributes: [String: String] = [
            "render_frame": frame == nil ? "0" : "1", "frame_columns": String(frame?.snapshot.columns ?? 0),
            "frame_rows": String(frame?.snapshot.rows ?? 0), "owner_epoch": String(frame?.ownerEpoch ?? 0),
            "session_revision": frame?.sessionRevision.map(String.init) ?? "nil", "frame_kind": frameKind,
            "base_revision": baseRevision.map(String.init) ?? "nil", "target_revision": resolvedTargetRevision.map(String.init) ?? "nil",
            "applied_revision": appliedRevision.map(String.init) ?? "nil",
        ]
        if let reason { attributes["reason"] = reason }
        if let frameByteCount { attributes["frame_bytes"] = String(frameByteCount) } else if frame == nil { attributes["frame_bytes"] = "0" }
        if let frameEncodeMS { attributes["frame_encode_ms"] = String(frameEncodeMS) }
        if let payloadByteCount { attributes["payload_bytes"] = String(payloadByteCount) }
        if let payloadEncodeMS { attributes["payload_encode_ms"] = String(payloadEncodeMS) }
        if let decodeMS { attributes["decode_ms"] = String(decodeMS) }
        if let outputByteCount { attributes["output_bytes"] = String(outputByteCount) }
        if let screenStateRevision { attributes["screen_revision"] = String(screenStateRevision) }
        if let dropped { attributes["dropped"] = dropped ? "1" : "0" }
        attributes["drop_reason"] = dropReason ?? (dropped == true ? "unknown" : "none")
        if let renderMode { attributes["render_mode"] = renderMode }
        if let applyMS { attributes["apply_ms"] = String(applyMS) }
        return attributes
    }

    public static func detailString(_ attributes: [String: String]) -> String {
        attributes.keys.sorted().map { key in "\(key)=\(attributes[key] ?? "")" }.joined(separator: " ")
    }
}
