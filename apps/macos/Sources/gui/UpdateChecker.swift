import Foundation
import streamctl

/// Information about an available update.
public struct UpdateInfo: Sendable {
    public let version: String
    public let downloadURL: URL
    public let releaseNotes: String
}

/// Checks the appcast feed for new versions of Muxy.
public actor UpdateChecker {
    private static let appcastURL = URL(string: "https://muxy-dev.web.app/releases/appcast.xml")!
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
        var request = URLRequest(url: Self.appcastURL)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let parser = AppcastParser()
            guard let item = parser.parse(data), let remoteVersion = item.version, let downloadURL = item.downloadURL else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            guard isNewerVersion(remoteVersion, than: AppVersion.current) else {
                lastCheckDate = Date()
                cachedResult = nil
                return nil
            }

            let info = UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: item.releaseNotes ?? "")
            lastCheckDate = Date()
            cachedResult = info
            return info
        } catch {
            lastCheckDate = Date()
            cachedResult = nil
            return nil
        }
    }

    private struct AppcastItem {
        let version: String?
        let downloadURL: URL?
        let releaseNotes: String?
    }

    private class AppcastParser: NSObject, XMLParserDelegate {
        private var currentElement = ""
        private var currentVersion: String?
        private var currentURL: String?
        private var foundItem = false

        func parse(_ data: Data) -> AppcastItem? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            let url = currentURL.flatMap { URL(string: $0) }
            return AppcastItem(version: currentVersion, downloadURL: url, releaseNotes: nil)
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes: [String: String] = [:]
        ) {
            currentElement = elementName
            if elementName == "item" { foundItem = true } else if elementName == "enclosure", foundItem { currentURL = attributes["url"] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentElement == "sparkle:version" || currentElement == "sparkle:shortVersionString" {
                if currentVersion == nil { currentVersion = string.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
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
