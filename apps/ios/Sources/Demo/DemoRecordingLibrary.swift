import Foundation
import spacesdevicecore
import spacesterminalcore

/// A grid the demo recording was captured at (one device class: phone portrait, pad, …).
struct DemoRecordingGrid: Hashable, Sendable {
    let columns: Int
    let rows: Int
}

/// The bundled recording manifest. Mirrors the JSON the recorder (`spacese2e record-mobile-demo`)
/// writes; only the fields the loader needs are decoded.
struct DemoRecordingManifest: Decodable, Sendable {
    struct Grid: Decodable, Sendable {
        let columns: Int
        let rows: Int
    }

    struct Session: Decodable, Sendable {
        let stableID: String
        let workspaceName: String
        let title: String
        let kind: String
    }

    let schemaVersion: Int
    let referenceDate: String
    let grids: [Grid]
    let sessions: [Session]
    let sessionIDMap: [String: String]
}

enum DemoRecordingLibraryError: LocalizedError {
    case resourceMissing(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case decodeFailed(resource: String, underlying: String)
    case overviewMissing
    case recordingMissing(sessionID: String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): "The demo recording resource \(name) is missing from the app bundle."
        case .unsupportedSchemaVersion(let found, let supported):
            "The demo recording schema version \(found) is not supported (this build understands \(supported))."
        case .decodeFailed(let resource, let underlying): "The demo recording resource \(resource) could not be decoded: \(underlying)."
        case .overviewMissing: "The demo recording overview response did not contain an overview payload."
        case .recordingMissing(let sessionID): "The demo recording has no terminal frame for session \(sessionID)."
        }
    }
}

/// Loads and validates the bundled Demo Mode recording, decoding it through the same production
/// codecs the network path uses so the demo backend serves byte-for-byte the shapes a real daemon
/// would (`SpacesDeviceAPICodec.decodeResponse` for the overview, `GhosttyRemoteSessionStateCodec`
/// for each terminal frame).
///
/// The recorder normalized every ISO-8601 timestamp to a signed integer second-offset from
/// `manifest.referenceDate`; this loader reverses that at the JSON layer — before decoding — by
/// replacing each offset string with an absolute date measured from load-time "now", so alerts read
/// as fresh on every launch. It also patches the daemon status `protocolVersion` to the client's
/// current `SpacesWireProtocol.version`, so the synthetic demo device is always wire-compatible.
struct DemoRecordingLibrary: Sendable {
    static let supportedSchemaVersion = 1
    private static let resourceSubdirectory = "DemoRecording"

    let manifest: DemoRecordingManifest
    /// The demo device overview, timestamps rebased to "now" and daemon status patched to the current
    /// wire version. This is the pristine baseline; the backend mutates its own copy in place.
    let overview: SpacesDeviceOverviewPayload
    /// Steady-state terminal frames keyed by grid, then by stable session slug.
    let recordings: [DemoRecordingGrid: [String: GhosttyRemoteSessionStatePayload]]

    static func load(bundle: Bundle = .main, now: Date = Date()) throws -> DemoRecordingLibrary {
        let manifestData = try resourceData("manifest", "json", in: bundle)
        let manifest: DemoRecordingManifest
        do { manifest = try JSONDecoder().decode(DemoRecordingManifest.self, from: manifestData) } catch {
            throw DemoRecordingLibraryError.decodeFailed(resource: "manifest.json", underlying: String(describing: error))
        }
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw DemoRecordingLibraryError.unsupportedSchemaVersion(found: manifest.schemaVersion, supported: supportedSchemaVersion)
        }

        let overview = try loadOverview(bundle: bundle, now: now)
        let recordings = try loadRecordings(manifest: manifest, bundle: bundle, now: now)
        return DemoRecordingLibrary(manifest: manifest, overview: overview, recordings: recordings)
    }

    /// The recording grid nearest the requested viewport. With no request, defaults to the phone grid
    /// (the smallest-area recording), so a session served before its first resize still looks native.
    func nearestGrid(to requested: DemoRecordingGrid?) -> DemoRecordingGrid? {
        let grids = Array(recordings.keys)
        guard let requested else { return grids.min { area($0) < area($1) } }
        return grids.min { squaredDistance($0, requested) < squaredDistance($1, requested) }
    }

    /// The steady-state frame for a session at the grid nearest the requested viewport.
    func payload(forSessionSlug slug: String, requested: DemoRecordingGrid?) -> GhosttyRemoteSessionStatePayload? {
        guard let grid = nearestGrid(to: requested) else { return nil }
        return recordings[grid]?[slug]
    }

    private func area(_ grid: DemoRecordingGrid) -> Int { grid.columns * grid.rows }

    private func squaredDistance(_ lhs: DemoRecordingGrid, _ rhs: DemoRecordingGrid) -> Int {
        let dc = lhs.columns - rhs.columns
        let dr = lhs.rows - rhs.rows
        return dc * dc + dr * dr
    }

    // MARK: - Loading

    private static func loadOverview(bundle: Bundle, now: Date) throws -> SpacesDeviceOverviewPayload {
        let data = try resourceData("overview", "json", in: bundle)
        let rebased = try rebasedJSONData(
            data, resource: "overview.json", now: now, timestamp: TerminalSessionTimestamp.string(from:), patchProtocolVersion: true)
        let response: SpacesDeviceAPIResponse
        do { response = try SpacesDeviceAPICodec.decodeResponse(rebased) } catch {
            throw DemoRecordingLibraryError.decodeFailed(resource: "overview.json", underlying: String(describing: error))
        }
        guard let overview = response.overview else { throw DemoRecordingLibraryError.overviewMissing }
        return overview
    }

    private static func loadRecordings(manifest: DemoRecordingManifest, bundle: Bundle, now: Date) throws -> [DemoRecordingGrid: [String:
        GhosttyRemoteSessionStatePayload]]
    {
        var recordings: [DemoRecordingGrid: [String: GhosttyRemoteSessionStatePayload]] = [:]
        for grid in manifest.grids {
            let recordingGrid = DemoRecordingGrid(columns: grid.columns, rows: grid.rows)
            let subdirectory = "\(resourceSubdirectory)/grids/\(grid.columns)x\(grid.rows)"
            var frames: [String: GhosttyRemoteSessionStatePayload] = [:]
            for session in manifest.sessions {
                guard let url = bundle.url(forResource: session.stableID, withExtension: "ndjson", subdirectory: subdirectory) else {
                    throw DemoRecordingLibraryError.resourceMissing("\(subdirectory)/\(session.stableID).ndjson")
                }
                let line = try firstNonEmptyLine(of: url)
                // The recorder normalizes payload timestamps to the fractional-seconds format the remote
                // session-state wire uses, so rebase back into that same format.
                let rebased = try rebasedJSONData(
                    line, resource: "\(session.stableID).ndjson", now: now, timestamp: GhosttyRemoteSessionStateTimestamp.string(from:),
                    patchProtocolVersion: false)
                do { frames[session.stableID] = try GhosttyRemoteSessionStateCodec.decodeLine(rebased) } catch {
                    throw DemoRecordingLibraryError.decodeFailed(resource: "\(session.stableID).ndjson", underlying: String(describing: error))
                }
            }
            recordings[recordingGrid] = frames
        }
        return recordings
    }

    private static func resourceData(_ name: String, _ ext: String, in bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: resourceSubdirectory) else {
            throw DemoRecordingLibraryError.resourceMissing("\(resourceSubdirectory)/\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    private static func firstNonEmptyLine(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let newlineIndex = data.firstIndex(of: 0x0A) else { return data }
        return Data(data.prefix(upTo: newlineIndex))
    }

    // MARK: - Timestamp rebasing

    /// Rebases every signed-integer offset string in a JSON document to an absolute timestamp measured
    /// from `now`, optionally patching `result.overview.daemonStatus.protocolVersion`. The recorder wrote
    /// only timestamp fields as integer offsets, so any pure-integer string is one; all other strings
    /// (ids, commands, the base64 render blob) pass through untouched.
    private static func rebasedJSONData(_ data: Data, resource: String, now: Date, timestamp: (Date) -> String, patchProtocolVersion: Bool) throws
        -> Data
    {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw DemoRecordingLibraryError.decodeFailed(resource: resource, underlying: String(describing: error))
        }
        var rebased = rebase(object, now: now, timestamp: timestamp)
        if patchProtocolVersion { rebased = patchedProtocolVersion(rebased) }
        do { return try JSONSerialization.data(withJSONObject: rebased, options: [.fragmentsAllowed]) } catch {
            throw DemoRecordingLibraryError.decodeFailed(resource: resource, underlying: String(describing: error))
        }
    }

    private static func rebase(_ value: Any, now: Date, timestamp: (Date) -> String) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues { rebase($0, now: now, timestamp: timestamp) }
        case let array as [Any]: return array.map { rebase($0, now: now, timestamp: timestamp) }
        case let string as String:
            guard let offset = offsetSeconds(from: string) else { return string }
            return timestamp(now.addingTimeInterval(TimeInterval(offset)))
        default: return value
        }
    }

    /// Parses a pure signed-integer offset string (e.g. "-7", "0", "12"). Returns nil for anything else,
    /// so ordinary strings are never mistaken for timestamps.
    private static func offsetSeconds(from string: String) -> Int? {
        guard !string.isEmpty else { return nil }
        var digits = Substring(string)
        if digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(string)
    }

    private static func patchedProtocolVersion(_ value: Any) -> Any {
        guard var root = value as? [String: Any], var result = root["result"] as? [String: Any], var overview = result["overview"] as? [String: Any],
            var status = overview["daemonStatus"] as? [String: Any]
        else { return value }
        status["protocolVersion"] = SpacesWireProtocol.version
        overview["daemonStatus"] = status
        result["overview"] = overview
        root["result"] = result
        return root
    }
}
