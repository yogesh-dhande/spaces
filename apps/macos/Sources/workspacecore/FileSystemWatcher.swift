// FSEvents (CoreServices) backs the macOS watcher; the Linux daemon uses an
// inotify backend with the same surface (see the `#elseif os(Linux)` section).
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
    ///
    /// FSEvents watches each path recursively, so callers pass a single root and
    /// filter the reported paths. The Linux inotify backend is not recursive, so
    /// callers that need a subtree there pass each directory explicitly.
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
            paths: [String], latency: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
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
                    kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
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

#elseif os(Linux)

    import Foundation
    import Glibc

    /// inotify-backed watcher mirroring the macOS `FileSystemWatcher` surface for
    /// the Linux daemon. inotify is not recursive, so each watched directory is
    /// added explicitly and only its direct entries are reported; callers that need
    /// a subtree (e.g. a git `worktrees/` tree) pass each directory in `paths`.
    ///
    /// Reported paths are the absolute child paths (`<watched dir>/<name>`) plus the
    /// watched directory itself for self-events, so callers can apply the same path
    /// filter they use on macOS.
    public final class FileSystemWatcher: @unchecked Sendable {
        public enum WatchError: Error {
            case noPaths
            case streamUnavailable
        }

        private let paths: [String]
        private let queue: DispatchQueue
        private let onChange: @Sendable ([String]) -> Void
        private var fileDescriptor: Int32 = -1
        private var source: DispatchSourceRead?
        private var watchedDirectoriesByDescriptor: [Int32: String] = [:]

        public init(
            paths: [String], latency _: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
            onChange: @escaping @Sendable ([String]) -> Void
        ) {
            self.paths = paths
            self.queue = queue
            self.onChange = onChange
        }

        public func start() throws {
            guard fileDescriptor < 0 else { return }
            guard !paths.isEmpty else { throw WatchError.noPaths }
            let descriptor = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard descriptor >= 0 else { throw WatchError.streamUnavailable }
            // File metadata that git rewrites on worktree/HEAD changes plus the
            // directory-level create/delete/move events that signal a worktree added
            // or removed; self-delete/move so a vanished directory drops its watch.
            let mask = UInt32(IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF | IN_DELETE_SELF | IN_ONLYDIR)
            for path in paths {
                let watchDescriptor = inotify_add_watch(descriptor, path, mask)
                if watchDescriptor >= 0 { watchedDirectoriesByDescriptor[watchDescriptor] = path }
            }
            guard !watchedDirectoriesByDescriptor.isEmpty else {
                close(descriptor)
                throw WatchError.streamUnavailable
            }
            fileDescriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drainEvents() }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
        }

        public func stop() {
            guard fileDescriptor >= 0 else { return }
            source?.cancel()
            source = nil
            // The cancel handler owns closing the descriptor.
            fileDescriptor = -1
            watchedDirectoriesByDescriptor.removeAll()
        }

        /// Reads all currently-available inotify events in one pass (the read source
        /// fires once per readable burst, which coalesces a change burst into one
        /// `onChange`) and reports the affected absolute paths.
        private func drainEvents() {
            let headerSize = MemoryLayout<inotify_event>.size
            var buffer = [UInt8](repeating: 0, count: 8192)
            var changedPaths: [String] = []
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
                if bytesRead <= 0 { break }
                var offset = 0
                while offset + headerSize <= bytesRead {
                    let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                    let nameLength = Int(event.len)
                    let directory = watchedDirectoriesByDescriptor[event.wd]
                    if let directory {
                        if nameLength > 0 {
                            let nameStart = offset + headerSize
                            let nameBytes = buffer[nameStart..<(nameStart + nameLength)].prefix { $0 != 0 }
                            let name = String(decoding: nameBytes, as: UTF8.self)
                            changedPaths.append(name.isEmpty ? directory : directory + "/" + name)
                        } else {
                            changedPaths.append(directory)
                        }
                    }
                    offset += headerSize + nameLength
                }
            }
            if !changedPaths.isEmpty { onChange(changedPaths) }
        }

        deinit { stop() }
    }

#endif
