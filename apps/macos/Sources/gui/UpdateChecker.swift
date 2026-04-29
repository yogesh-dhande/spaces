import Foundation
import streamctl

/// Information about an available update.
public struct UpdateInfo: Sendable {
    public let version: String
    public let downloadURL: URL
    public let releaseNotes: String
}

/// Checks GitHub Releases for new versions of Muxy.
public actor UpdateChecker {
    static let latestReleaseURL = URL(string: "https://github.com/yogesh-dhande/spaces/releases/latest")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/yogesh-dhande/spaces/releases/latest")!
    private static let checkInterval: TimeInterval = 4 * 60 * 60  // 4 hours

    private var cachedResult: UpdateInfo?
    private var lastCheckDate: Date?

    /// Check for an available update, using cache when fresh.
    public func checkForUpdate() async -> UpdateInfo? {
        if let lastCheckDate, let cachedResult, Date().timeIntervalSince(lastCheckDate) < Self.checkInterval { return cachedResult }
        return await fetchLatestRelease()
    }

    /// Force a fresh check, ignoring cache.
    public func forceCheck() async -> UpdateInfo? { await fetchLatestRelease() }

    private func fetchLatestRelease() async -> UpdateInfo? {
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Muxy", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let remoteVersion = normalizedVersion(from: release.tagName), let downloadURL = downloadURL(from: release.assets) else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            guard isNewerVersion(remoteVersion, than: AppVersion.current) else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let info = UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: release.body ?? "")
            lastCheckDate = Date()
            cachedResult = info
            return info
        } catch {
            lastCheckDate = Date()
            cachedResult = nil
            return nil
        }
    }

    struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    nonisolated func normalizedVersion(from tagName: String) -> String? {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return version.isEmpty ? nil : version
    }

    nonisolated func downloadURL(from assets: [GitHubAsset]) -> URL? {
        assets.first { $0.name.localizedStandardContains(".dmg") }?.browserDownloadURL
    }

    /// Simple semver comparison: returns true if `remote` is newer than `local`.
    nonisolated func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}
