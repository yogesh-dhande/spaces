import Foundation
import streamctl

/// Information about an available update.
public struct UpdateInfo: Sendable {
    public let version: String
    public let downloadURL: URL
    public let releaseNotes: String
}

/// Checks the GitHub Releases API for new versions of muxy.
public actor UpdateChecker {
    private static let releaseURL = URL(string: "https://api.github.com/repos/yogesh-dhande/agentmux/releases/latest")!
    private static let checkInterval: TimeInterval = 4 * 60 * 60 // 4 hours

    private var cachedResult: UpdateInfo?
    private var lastCheckDate: Date?

    /// Check for an available update, using cache when fresh.
    public func checkForUpdate() async -> UpdateInfo? {
        if let lastCheckDate, let cachedResult,
           Date().timeIntervalSince(lastCheckDate) < Self.checkInterval
        {
            return cachedResult
        }
        return await fetchLatestRelease()
    }

    /// Force a fresh check, ignoring cache.
    public func forceCheck() async -> UpdateInfo? {
        await fetchLatestRelease()
    }

    private func fetchLatestRelease() async -> UpdateInfo? {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard isNewerVersion(remoteVersion, than: AppVersion.current) else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let downloadURL = findDownloadURL(in: json) ?? URL(string: "https://github.com/yogesh-dhande/agentmux/releases/latest")!
            let releaseNotes = json["body"] as? String ?? ""

            let info = UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: releaseNotes)
            lastCheckDate = Date()
            cachedResult = info
            return info
        } catch {
            lastCheckDate = Date()
            cachedResult = nil
            return nil
        }
    }

    private func findDownloadURL(in json: [String: Any]) -> URL? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.hasSuffix("-macos.zip"),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else { continue }
            return url
        }
        return nil
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
