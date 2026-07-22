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
    ///
    /// Lifecycle invariant: every `FSEventStream*` call (create/start/stop/invalidate/
    /// release) does IPC to `fseventsd` that can stall for seconds under load, and
    /// FSEvents has no main-thread affinity once a dispatch queue is set on the stream.
    /// So all of them — and the `stream` property they mutate — are confined to
    /// `queue`, which is also the stream's callback-delivery queue. Lifecycle work is
    /// always dispatched with `async` (never `sync`), so tearing a stream down from
    /// within its own callback cannot deadlock, and the setup/teardown never runs on
    /// the caller's thread (e.g. the daemon main actor that pumps terminal I/O).
    ///
    /// Ownership contract: the FSEvents `info` pointer holds a *retained* reference to
    /// a small `FSEventCallbackContext` box (carrying only `onChange`), never to the
    /// watcher itself. This makes both failure modes structurally impossible:
    /// - No use-after-free: a callback already enqueued on `queue` when the watcher is
    ///   dropped still dereferences the box, which the live stream keeps retained until
    ///   `FSEventStreamInvalidate` runs the release thunk. It never touches `self`.
    /// - No leak: because the stream does not retain the watcher, dropping the last
    ///   external reference deallocates the watcher, whose `deinit` tears the stream
    ///   down (releasing the box). There is no stream↔watcher retain cycle, so the
    ///   `deinit` safety net remains reachable and callers need not call `stop()` to
    ///   avoid a leak (though `WorktreeDiscoveryService` does, on every removal path).
    public final class FileSystemWatcher: @unchecked Sendable {
        public enum WatchError: Error {
            case noPaths
            case streamUnavailable
        }

        private let paths: [String]
        private let latency: TimeInterval
        private let queue: DispatchQueue
        private let onChange: @Sendable ([String]) -> Void
        /// Only read or written on `queue`, except in `deinit` where no other
        /// reference to `self` can exist so the access is race-free.
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
        /// path list is empty or the OS refuses to create the event stream. The
        /// `FSEventStream*` setup runs on `queue`, so a busy `fseventsd` suspends the
        /// awaiting caller instead of blocking its thread.
        public func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        try self.startOnQueue()
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        /// Serialized on `queue`; see the type's lifecycle invariant.
        private func startOnQueue() throws {
            guard stream == nil else { return }
            guard !paths.isEmpty else { throw WatchError.noPaths }
            // File-level events keep the callback path list precise enough for callers
            // to filter (e.g. only git worktree metadata), while NoDefer delivers the
            // first event in an idle period immediately and coalesces the rest.
            let flags = UInt32(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info, count > 0 else { return }
                let callbackContext = Unmanaged<FSEventCallbackContext>.fromOpaque(info).takeUnretainedValue()
                let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                callbackContext.onChange(changed)
            }
            // The context retains this box (never `self`) via the thunks below, so a
            // callback can never observe a freed object; see the type's ownership
            // contract. `withExtendedLifetime` keeps the box alive across
            // `FSEventStreamCreate` — the opaque `info` pointer is invisible to ARC, so
            // without it the box could be freed before Create takes its retain.
            let callbackContext = FSEventCallbackContext(onChange: onChange)
            let created: FSEventStreamRef? = withExtendedLifetime(callbackContext) {
                var context = FSEventStreamContext(
                    version: 0, info: Unmanaged.passUnretained(callbackContext).toOpaque(),
                    retain: { info in
                        guard let info else { return nil }
                        _ = Unmanaged<FSEventCallbackContext>.fromOpaque(info).retain()
                        return info
                    },
                    release: { info in
                        guard let info else { return }
                        Unmanaged<FSEventCallbackContext>.fromOpaque(info).release()
                    }, copyDescription: nil)
                return FSEventStreamCreate(
                    kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            }
            guard let created else { throw WatchError.streamUnavailable }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                throw WatchError.streamUnavailable
            }
            stream = created
        }

        /// Stops delivering events and releases the stream. Idempotent and
        /// non-blocking: the teardown is dispatched onto `queue`, so it never runs
        /// `FSEventStream*` on the caller's thread. Because the teardown is async, a
        /// callback already in flight may still be delivered shortly after `stop()`
        /// returns; callers that must not act on late callbacks guard on their own
        /// stopped state.
        public func stop() { queue.async { self.stopOnQueue() } }

        /// Serialized on `queue`; see the type's lifecycle invariant.
        private func stopOnQueue() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        deinit {
            // At deinit no other reference to `self` can exist, so reading `stream`
            // directly is race-free. This safety net is reachable precisely because the
            // stream retains the callback box rather than `self` (see the ownership
            // contract): the owner may drop the watcher without calling stop(), and this
            // tears the stream down on `queue` (never the calling thread, which may be
            // the main actor). Invalidating releases the box, so an in-flight callback
            // enqueued ahead of this teardown still sees a live box. The pointer is boxed
            // because FSEventStreamRef is not Sendable; `self` is not captured, so this
            // cannot resurrect the object.
            guard let stream else { return }
            let box = UncheckedSendableBox(stream)
            queue.async {
                FSEventStreamStop(box.value)
                FSEventStreamInvalidate(box.value)
                FSEventStreamRelease(box.value)
            }
        }
    }

    /// Carries a non-Sendable `FSEventStreamRef` across a `queue.async` boundary in
    /// `deinit`, where the stream is provably owned by no one else.
    private struct UncheckedSendableBox: @unchecked Sendable {
        let value: FSEventStreamRef
        init(_ value: FSEventStreamRef) { self.value = value }
    }

    /// Carries only the change handler across the FSEvents C callback boundary. The
    /// stream's context retains an instance (via the retain/release thunks in
    /// `startOnQueue`), so a callback always dereferences a live object even after the
    /// owning `FileSystemWatcher` deallocates. It deliberately does NOT reference the
    /// watcher, so the watcher can deinit independently and tear its stream down; the
    /// stream's `FSEventStreamInvalidate` then releases this box.
    private final class FSEventCallbackContext {
        let onChange: @Sendable ([String]) -> Void
        init(onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
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
    ///
    /// Lifecycle invariant (mirrors the macOS backend): `inotify_add_watch` can block
    /// on a slow filesystem, so stream setup/teardown and the `fileDescriptor`,
    /// `source`, and `watchedDirectoriesByDescriptor` state they mutate are confined
    /// to `queue` — also the read source's event queue — via `async` dispatch, keeping
    /// them off the caller's thread and free of data races.
    public final class FileSystemWatcher: @unchecked Sendable {
        public enum WatchError: Error {
            case noPaths
            case streamUnavailable
        }

        private let paths: [String]
        private let queue: DispatchQueue
        private let onChange: @Sendable ([String]) -> Void
        /// Only read or written on `queue`, except in `deinit` where no other
        /// reference to `self` can exist so the access is race-free.
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

        /// Starts delivering change events. Idempotent while running. Throws when the
        /// path list is empty or no watch can be added. The inotify setup runs on
        /// `queue`, so a slow filesystem suspends the awaiting caller instead of
        /// blocking its thread.
        public func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        try self.startOnQueue()
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        /// Serialized on `queue`; see the type's lifecycle invariant.
        private func startOnQueue() throws {
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

        /// Stops delivering events and releases the watch. Idempotent and
        /// non-blocking: the teardown is dispatched onto `queue`, so it never runs on
        /// the caller's thread. Because the teardown is async, a callback already in
        /// flight may still be delivered shortly after `stop()` returns; callers that
        /// must not act on late callbacks guard on their own stopped state.
        public func stop() { queue.async { self.stopOnQueue() } }

        /// Serialized on `queue`; see the type's lifecycle invariant.
        private func stopOnQueue() {
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

        deinit {
            // At deinit no other reference to `self` can exist, so reading `source`
            // directly is race-free. Cancelling schedules the descriptor close on
            // `queue` via the cancel handler, so no blocking teardown runs on the
            // deallocating thread. `self` is not captured.
            source?.cancel()
        }
    }

#endif
