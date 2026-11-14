// spacesdevicecore also compiles into the Linux daemon, which never shows a prompt library, so this
// client-only helper is compiled out there (matches AlertsAgeFormatting.swift's guard).
#if !os(Linux)

    import Foundation
    import spacesterminalcore

    /// The prompts of every reachable device merged into one list, shared by the Mac and iPhone clients so
    /// both order, search, and refetch the same way.
    ///
    /// Each device keeps its own prompts. The overview carries only a revision per device, and a client
    /// pulls that device's list when the revision goes up: `reconcile` says which devices to fetch, and
    /// `apply` installs what came back. A slice is kept only while its device is reachable, and a device
    /// that comes back is fetched again rather than served from a cache.
    public struct SavedPromptLibrary: Sendable, Equatable {
        public struct Device: Sendable, Equatable {
            public let id: String
            public let name: String
            /// The `savedPromptsRevision` of the device's latest overview.
            public let overviewRevision: Int

            public init(id: String, name: String, overviewRevision: Int) {
                self.id = id
                self.name = name
                self.overviewRevision = overviewRevision
            }
        }

        public struct Entry: Sendable, Equatable, Identifiable {
            public let deviceID: String
            public let deviceName: String
            public let prompt: SpacesDeviceSavedPrompt

            public var id: String { "\(deviceID)/\(prompt.id)" }

            public init(deviceID: String, deviceName: String, prompt: SpacesDeviceSavedPrompt) {
                self.deviceID = deviceID
                self.deviceName = deviceName
                self.prompt = prompt
            }
        }

        private struct Slice: Equatable {
            var revision: Int
            var prompts: [SpacesDeviceSavedPrompt]
        }

        private var devices: [Device] = []
        private var slices: [String: Slice] = [:]
        private var fetchesInFlight: Set<String> = []

        public init() {}

        /// Every prompt held, before any search filter.
        public var count: Int { slices.values.reduce(0) { $0 + $1.prompts.count } }

        /// Makes `reachable` the set of devices whose prompts are shown, in that order for tie-breaks.
        /// Returns the ids to fetch now: devices with no slice or a newer overview revision than their
        /// slice, and no fetch already in flight. The caller reports each fetch's outcome through `apply`
        /// or `fetchFailed`; a device whose fetch failed is returned again by the next call.
        public mutating func reconcile(reachable: [Device]) -> [String] {
            devices = reachable
            let reachableIDs = Set(reachable.map(\.id))
            slices = slices.filter { reachableIDs.contains($0.key) }
            fetchesInFlight.formIntersection(reachableIDs)
            var toFetch: [String] = []
            for device in reachable where !fetchesInFlight.contains(device.id) {
                if let slice = slices[device.id], slice.revision >= device.overviewRevision { continue }
                fetchesInFlight.insert(device.id)
                toFetch.append(device.id)
            }
            return toFetch
        }

        /// Installs a device's list, from a fetch or from a mutation response. A result for a device that is
        /// not reachable, or older than the slice already held, is dropped: responses can arrive out of order,
        /// and the revision only goes up.
        public mutating func apply(_ result: SpacesDeviceSavedPromptsResult, deviceID: String) {
            guard devices.contains(where: { $0.id == deviceID }) else { return }
            fetchesInFlight.remove(deviceID)
            if let slice = slices[deviceID], result.revision < slice.revision { return }
            slices[deviceID] = Slice(revision: result.revision, prompts: result.prompts)
        }

        public mutating func fetchFailed(deviceID: String) { fetchesInFlight.remove(deviceID) }

        /// The merged list for a search query, most recently used first. An empty query lists everything.
        /// Ties fall to the newer creation time, then the device's position in `reachable`, then the prompt id.
        /// A query matches a title or text containing it, ignoring case and diacritics.
        public func entries(matching query: String) -> [Entry] {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            struct Ranked {
                let entry: Entry
                let lastUsedAt: Date
                let createdAt: Date
                let devicePosition: Int
            }
            var ranked: [Ranked] = []
            for (position, device) in devices.enumerated() {
                guard let slice = slices[device.id] else { continue }
                for prompt in slice.prompts where Self.matches(prompt, needle: needle) {
                    ranked.append(
                        Ranked(
                            entry: Entry(deviceID: device.id, deviceName: device.name, prompt: prompt),
                            lastUsedAt: TerminalSessionTimestamp.date(from: prompt.lastUsedAt) ?? .distantPast,
                            createdAt: TerminalSessionTimestamp.date(from: prompt.createdAt) ?? .distantPast, devicePosition: position))
                }
            }
            ranked.sort { lhs, rhs in
                if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                if lhs.devicePosition != rhs.devicePosition { return lhs.devicePosition < rhs.devicePosition }
                return lhs.entry.prompt.id < rhs.entry.prompt.id
            }
            return ranked.map(\.entry)
        }

        private static func matches(_ prompt: SpacesDeviceSavedPrompt, needle: String) -> Bool {
            if needle.isEmpty { return true }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return prompt.title.range(of: needle, options: options) != nil || prompt.text.range(of: needle, options: options) != nil
        }
    }

#endif
