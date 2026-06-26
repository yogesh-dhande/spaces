// FSEvents (CoreServices) is macOS-only; workspacecore also builds for the Linux
// daemon, where this watcher is unused, so keep it out of non-macOS targets.
#if os(macOS)

    import CoreServices
    import Foundation

/// FSEvents-backed watcher for a fixed set of filesystem paths.
///
/// The watcher coalesces change bursts with the FSEvents `latency` window and
/// invokes `onChange` with the affected paths on `queue`. Callers own the
/// lifetime explicitly via `start()`/`stop()`; `start()` throws when the event
/// stream cannot be created so the caller can surface a degraded-live-feature
/// state instead of silently falling back to polling.
public final class FileSystemWatcher: @unchecked Sendable {
    public enum WatchError: Error {
        case noPaths
        case streamUnavailable
    }

    private let paths: [String]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    public init(
        paths: [String], latency: TimeInterval = 0.5,
        queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
    }

    /// Starts delivering change events. Idempotent while running. Throws when the
    /// path list is empty or the OS refuses to create the event stream.
    public func start() throws {
        guard stream == nil else { return }
        guard !paths.isEmpty else { throw WatchError.noPaths }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // File-level events keep the callback path list precise enough for callers
        // to filter (e.g. only git worktree metadata), while NoDefer delivers the
        // first event in an idle period immediately and coalesces the rest.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.onChange(changed)
        }
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { throw WatchError.streamUnavailable }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WatchError.streamUnavailable
        }
        stream = created
    }

    /// Stops delivering events and releases the stream. Idempotent.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

#endif
