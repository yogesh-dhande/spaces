#if canImport(UIKit)
    import spacesdevicecore
    import spacesterminalcore

    /// Records every request a viewer sent its backend, so a test can count what a gesture actually paid
    /// for rather than infer it from the screen. Shared by every test in this target that stands a fake
    /// client in front of a `TerminalViewerModel`, real backend or demo recording alike.
    actor DeviceAPIRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }

        func snapshot() -> [SpacesDeviceAPIRequest] { requests }

        func containsTerminalControlAction(_ action: SpacesDeviceTerminalControlAction) -> Bool {
            requests.contains { request in
                if case .terminalControl(let payload) = request.command { return payload.action == action }
                return false
            }
        }

        func countTerminalControlAction(_ action: SpacesDeviceTerminalControlAction) -> Int {
            requests.filter { request in
                if case .terminalControl(let payload) = request.command { return payload.action == action }
                return false
            }.count
        }

        func countStateRequests() -> Int { stateRequests().count }

        /// The `.state` reads in the order they were sent, so a test can inspect what each one asked
        /// the daemon for.
        func stateRequests() -> [SpacesDeviceTerminalSessionRequest] {
            requests.compactMap { request in
                guard case .state(let payload) = request.command else { return nil }
                return payload
            }
        }

        /// The transcript reads in the order they were sent, so a test can count the pages a gesture paid
        /// for and inspect what each one asked the daemon for.
        func transcriptRequests() -> [SpacesDeviceTerminalTranscriptRequest] { Self.transcriptRequests(in: requests) }

        func lastAttachedClient() -> TerminalClient? {
            for request in requests.reversed() {
                guard case .terminalControl(let payload) = request.command, payload.action == .attach else { continue }
                return payload.client
            }
            return nil
        }

        /// The transcript reads inside an already-taken `snapshot()`, for a caller that reads several
        /// things off one snapshot rather than asking the actor again.
        nonisolated static func transcriptRequests(in requests: [SpacesDeviceAPIRequest]) -> [SpacesDeviceTerminalTranscriptRequest] {
            requests.compactMap { request in
                guard case .terminalTranscript(let payload) = request.command else { return nil }
                return payload
            }
        }
    }
#endif
