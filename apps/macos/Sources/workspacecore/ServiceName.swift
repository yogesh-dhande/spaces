import Foundation
import spacesterminalcore

/// A service is an app component declared in `spaces.yaml`. Its name is used directly as a DNS
/// label in `<service>.<workspace-slug>.localhost`, so it must be a valid DNS-1123 label, and it
/// also derives the port environment variable injected into processes.
public enum ServiceName {
    /// Whether `name` is already a valid service name (a DNS-1123 label). Used for live UI validation.
    public static func isValidLabel(_ name: String) -> Bool { DNSLabel.isValid(name.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// Validates a service name, returning the trimmed value or throwing with a precise message.
    /// Invalid names are rejected, never coerced, so authoring mistakes surface instead of silently
    /// changing the routed hostname.
    @discardableResult public static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DNSLabel.isValid(trimmed) else {
            throw WorkspaceError.invalidArgument(
                message: "Invalid service name \"\(raw)\": must be a DNS-1123 label "
                    + "(lowercase letters, digits, and hyphens; start and end with a letter or digit; at most \(DNSLabel.maxLength) characters).")
        }
        return trimmed
    }

    /// Validates a service-name list and rejects duplicates before env vars or Caddy hosts are derived.
    public static func validatedUnique(_ rawNames: [String]) throws -> [String] {
        var seen = Set<String>()
        return try rawNames.map { rawName in
            let name = try validated(rawName)
            guard seen.insert(name).inserted else {
                throw WorkspaceError.invalidArgument(message: "Duplicate service name \"\(name)\": service names must be unique.")
            }
            return name
        }
    }

    /// The port environment variable injected for a service, e.g. `admin-ui` → `SPACES_ADMIN_UI_PORT`.
    public static func portEnvVar(for name: String) -> String { "SPACES_\(envToken(name))_PORT" }

    /// The URL environment variable injected for a service, e.g. `admin-ui` → `SPACES_ADMIN_UI_URL`.
    public static func urlEnvVar(for name: String) -> String { "SPACES_\(envToken(name))_URL" }

    private static func envToken(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "_")
    }
}
