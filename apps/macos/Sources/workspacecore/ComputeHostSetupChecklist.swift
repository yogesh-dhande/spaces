import Foundation

public enum ComputeHostSetupCheckID: String, Codable, Sendable, Equatable, CaseIterable {
    case sshAccess
    case supportedPlatform
    case artifactManifest
    case requiredTools
    case writableInstallRoot
    case gitAvailable
    case gitAuthentication
    case archiveChecksum
    case internalChecksums
    case certificateFingerprint
    case portAvailability
    case daemonLaunch
    case pinnedTLS
    case mobileCredentialProvisioning
}

public enum ComputeHostSetupCheckStatus: String, Codable, Sendable, Equatable {
    case pending
    case passed
    case failed
    case skipped
}

public struct ComputeHostSetupCheckRow: Codable, Sendable, Equatable, Identifiable {
    public var id: ComputeHostSetupCheckID { checkID }

    public let checkID: ComputeHostSetupCheckID
    public let title: String
    public let status: ComputeHostSetupCheckStatus
    public let detail: String
    public let command: String?
    public let fixHint: String?

    public init(
        checkID: ComputeHostSetupCheckID, title: String, status: ComputeHostSetupCheckStatus, detail: String, command: String? = nil,
        fixHint: String? = nil
    ) {
        self.checkID = checkID
        self.title = title
        self.status = status
        self.detail = detail
        self.command = command
        self.fixHint = fixHint
    }
}

public struct ComputeHostSetupChecklist: Codable, Sendable, Equatable {
    public let hostID: String
    public let hostName: String
    public let sshCommand: String
    public let rows: [ComputeHostSetupCheckRow]

    public init(hostID: String, hostName: String, sshCommand: String, rows: [ComputeHostSetupCheckRow]) {
        self.hostID = hostID
        self.hostName = hostName
        self.sshCommand = sshCommand
        self.rows = rows
    }

    public var shouldShow: Bool { rows.contains { $0.status == .failed } }

    public var diagnosticsText: String {
        var lines = ["Remote Host Setup: \(hostName)", "SSH: \(sshCommand)"]
        for row in rows {
            lines.append("")
            lines.append("[\(row.status.rawValue)] \(row.title)")
            if !row.detail.isEmpty { lines.append(row.detail) }
            if let command = row.command, !command.isEmpty { lines.append("Command/check: \(command)") }
            if let fixHint = row.fixHint, !fixHint.isEmpty { lines.append("Fix: \(fixHint)") }
        }
        return lines.joined(separator: "\n")
    }
}

public struct ComputeHostSetupError: LocalizedError, Sendable, Equatable {
    public let checklist: ComputeHostSetupChecklist
    public let underlyingDescription: String

    public init(checklist: ComputeHostSetupChecklist, underlying: Error) {
        self.checklist = checklist
        self.underlyingDescription = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }

    public init(checklist: ComputeHostSetupChecklist, underlyingDescription: String) {
        self.checklist = checklist
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? { "Remote host setup needs attention for \(checklist.hostName). \(underlyingDescription)" }
}

public enum ComputeHostSetupChecklistBuilder {
    public static func success(host: ComputeHostRecord) -> ComputeHostSetupChecklist {
        ComputeHostSetupChecklist(hostID: host.id, hostName: host.name, sshCommand: ComputeHostBootstrapper.sshOpenCommand(host: host), rows: [])
    }

    public static func failure(host: ComputeHostRecord, failedCheck: ComputeHostSetupCheckID, command: String?, detail: String, fixHint: String?)
        -> ComputeHostSetupChecklist
    {
        let rows = ComputeHostSetupCheckID.allCases.map { checkID -> ComputeHostSetupCheckRow in
            let status: ComputeHostSetupCheckStatus
            if checkID == failedCheck {
                status = .failed
            } else if order(of: checkID) < order(of: failedCheck) {
                status = .passed
            } else {
                status = .pending
            }
            return ComputeHostSetupCheckRow(
                checkID: checkID, title: title(for: checkID), status: status,
                detail: detailText(for: checkID, host: host, status: status, detail: detail), command: checkID == failedCheck ? command : nil,
                fixHint: checkID == failedCheck ? fixHint : nil)
        }
        return ComputeHostSetupChecklist(
            hostID: host.id, hostName: host.name, sshCommand: ComputeHostBootstrapper.sshOpenCommand(host: host), rows: rows)
    }

    public static func directTLSFailure(host: ComputeHostRecord, detail: String) -> ComputeHostSetupChecklist {
        failure(
            host: host, failedCheck: .pinnedTLS, command: "pinned TLS ping \(host.daemonEndpoint.host):\(host.daemonEndpoint.port)", detail: detail,
            fixHint:
                "Allow direct access from this Mac to \(host.daemonEndpoint.host):\(host.daemonEndpoint.port) through VPN, firewall, or cloud security group rules."
        )
    }

    private static func title(for checkID: ComputeHostSetupCheckID) -> String {
        switch checkID {
        case .sshAccess: "SSH access"
        case .supportedPlatform: "Supported OS and architecture"
        case .requiredTools: "Required tools"
        case .writableInstallRoot: "Writable install root"
        case .gitAvailable: "Git availability"
        case .gitAuthentication: "Git authentication"
        case .artifactManifest: "Signed artifact manifest"
        case .archiveChecksum: "Archive checksum"
        case .internalChecksums: "Internal checksums"
        case .portAvailability: "Port availability"
        case .daemonLaunch: "Daemon launch"
        case .certificateFingerprint: "Certificate fingerprint"
        case .pinnedTLS: "Direct pinned-TLS reachability"
        case .mobileCredentialProvisioning: "Mobile credential provisioning"
        }
    }

    private static func detailText(for checkID: ComputeHostSetupCheckID, host: ComputeHostRecord, status: ComputeHostSetupCheckStatus, detail: String)
        -> String
    {
        if status == .failed { return detail }
        switch checkID {
        case .sshAccess: return "Strict known-host SSH to \(sshAuthority(host)) must work."
        case .supportedPlatform: return "Remote must be macOS 14+ or Ubuntu 24.04 on x86_64 or arm64."
        case .requiredTools: return "Remote shell must provide curl, tar, gzip, lsof, python3, git, and a SHA-256 checksum tool."
        case .writableInstallRoot: return "~/.spaces/compute-hosts/\(safePathComponent(host.id)) must be writable."
        case .gitAvailable: return "git must be installed for remote workspace preparation."
        case .gitAuthentication: return "Checked when a project remote URL is available."
        case .artifactManifest: return "Spaces verifies the GitHub Release manifest signature before install."
        case .archiveChecksum: return "Downloaded archive SHA-256 must match the signed manifest."
        case .internalChecksums: return "The archive's SHA256SUMS file must validate after extraction."
        case .portAvailability: return "spacesd needs a free listener port on \(host.daemonEndpoint.port)."
        case .daemonLaunch: return "The managed spacesd binary must start from the selected release."
        case .certificateFingerprint: return "spacesd must print a non-empty TLS certificate fingerprint."
        case .pinnedTLS: return "This Mac must reach the daemon directly and verify the saved TLS pin."
        case .mobileCredentialProvisioning:
            return "Remote spacesd must accept scoped mobile terminal credential issuance after pinned TLS validation."
        }
    }

    private static func order(of checkID: ComputeHostSetupCheckID) -> Int { ComputeHostSetupCheckID.allCases.firstIndex(of: checkID) ?? .max }

    private static func sshAuthority(_ host: ComputeHostRecord) -> String {
        let authority = [host.sshUser, host.sshHost].compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }.joined(separator: "@")
        return host.sshPort.map { "\(authority.isEmpty ? host.sshHost : authority):\($0)" } ?? (authority.isEmpty ? host.sshHost : authority)
    }

    private static func safePathComponent(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scalars: [UnicodeScalar] = []
        var lastWasSeparator = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "host" : result
    }
}
