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
        public enum WatchError: Error, CustomStringConvertible {
            case noPaths
            case streamUnavailable

            public var description: String {
                switch self {
                case .noPaths: "no paths to watch"
                case .streamUnavailable: "the file watcher could not start"
                }
            }
        }

        private let paths: [String]
        private let latency: TimeInterval
        private let queue: DispatchQueue
        private let watchesRoot: Bool
        private let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        /// Only read or written on `queue`, except in `deinit` where no other
        /// reference to `self` can exist so the access is race-free.
        private var stream: FSEventStreamRef?

        /// `watchesRoot` asks FSEvents to report the watched path (or an ancestor) being moved, replaced,
        /// or deleted as a `mustRescan` batch. FSEvents pays for it with an open descriptor on every
        /// ancestor directory of every watched path, so callers that hold many watchers and do not need
        /// the signal pass `false`.
        public init(
            paths: [String], latency: TimeInterval = 0.5, watchesRoot: Bool = true,
            queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
            onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        ) {
            self.paths = paths
            self.latency = latency
            self.watchesRoot = watchesRoot
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
            var flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            if watchesRoot { flags |= UInt32(kFSEventStreamCreateFlagWatchRoot) }
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info, count > 0 else { return }
                let callbackContext = Unmanaged<FSEventCallbackContext>.fromOpaque(info).takeUnretainedValue()
                let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                // Any of these on any event in the batch means FSEvents coalesced past what it could
                // report precisely (a burst it dropped, or a moved/replaced watch root), so the caller
                // must treat the batch as "something changed somewhere under the root" rather than trust
                // the reported paths.
                let rescanFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagRootChanged)
                let mustRescan = UnsafeBufferPointer(start: eventFlags, count: count).contains { $0 & rescanFlags != 0 }
                callbackContext.onChange(changed, mustRescan)
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

        /// No-op on macOS: FSEvents watches `paths` recursively, so every directory under a watched root
        /// is already covered without registering it explicitly. Present only so callers that support both
        /// backends (`WorkspaceWatch`) have one surface to call; `throws` only to match that shared
        /// surface (the Linux backend's `inotify_add_watch` can fail), never actually thrown here.
        public func addPaths(_ paths: [String]) throws {}

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
        let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        init(onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void) { self.onChange = onChange }
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
    /// Every watcher registers on the one process-wide inotify instance
    /// (`FileSystemWatcherInotifyInstance`) instead of owning its own, because Linux caps
    /// inotify instances per user and that cap is shared with the user's other programs.
    /// A watcher is a subscriber id on that instance; it holds no descriptor of its own.
    ///
    /// Lifecycle invariant (mirrors the macOS backend): `inotify_add_watch` can block
    /// on a slow filesystem, so setup/teardown and all inotify state run on the shared
    /// instance's queue via `async` dispatch (`addPaths` is `sync` so it can throw),
    /// keeping them off the caller's thread and free of data races. Change batches are
    /// delivered by `async` onto this watcher's own `queue`, so a handler never runs on
    /// the shared queue.
    public final class FileSystemWatcher: @unchecked Sendable {
        /// `noPaths` and `streamUnavailable` cover setup failures with no per-syscall detail to report.
        /// `initFailed` and `watchFailed` carry the failing syscall's own errno and `strerror` text (plus,
        /// for `watchFailed`, the path it was registering) so the daemon's live-refresh banner can name the
        /// actual cause (e.g. an exhausted `fs.inotify.max_user_watches`) instead of a generic message.
        public enum WatchError: Error, CustomStringConvertible {
            case noPaths
            case streamUnavailable
            case initFailed(errno: Int32)
            case watchFailed(path: String, errno: Int32)

            public var description: String {
                switch self {
                case .noPaths: "no paths to watch"
                case .streamUnavailable: "the file watcher could not start"
                case .initFailed(let code): "inotify_init1: \(Self.errnoText(code))"
                case .watchFailed(let path, let code): "inotify_add_watch(\(path)): \(Self.errnoText(code))"
                }
            }

            /// `strerror`'s human-readable message plus the errno's own macro name (`ENOSPC`, not just its
            /// numeric value), since the macro name is what an operator recognizes and searches for.
            private static func errnoText(_ code: Int32) -> String { "\(String(cString: strerror(code))) (\(errnoName(code)))" }

            /// Only the errno values `inotify_init1`/`inotify_add_watch` actually document (see their man
            /// pages); anything else falls back to the bare number rather than guessing a name.
            private static func errnoName(_ code: Int32) -> String {
                switch code {
                case EACCES: return "EACCES"
                case EBADF: return "EBADF"
                case EEXIST: return "EEXIST"
                case EFAULT: return "EFAULT"
                case EINVAL: return "EINVAL"
                case EMFILE: return "EMFILE"
                case ENAMETOOLONG: return "ENAMETOOLONG"
                case ENFILE: return "ENFILE"
                case ENOMEM: return "ENOMEM"
                case ENOSPC: return "ENOSPC"
                case ENOTDIR: return "ENOTDIR"
                default: return "errno \(code)"
                }
            }
        }

        private let paths: [String]
        private let queue: DispatchQueue
        private let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        private let subscriber = FileSystemWatcherInotifyInstance.shared.makeSubscriberID()

        public init(
            paths: [String], latency _: TimeInterval = 0.5, watchesRoot _: Bool = true,
            queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
            onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        ) {
            self.paths = paths
            self.queue = queue
            self.onChange = onChange
        }

        /// Starts delivering change events. Idempotent while running. Throws when the
        /// path list is empty or no watch can be added. The inotify setup runs on
        /// the shared instance's queue, so a slow filesystem suspends the awaiting
        /// caller instead of blocking its thread.
        public func start() async throws {
            try await FileSystemWatcherInotifyInstance.shared.start(subscriber: subscriber, roots: paths, queue: queue, onChange: onChange)
        }

        /// Stops delivering events and releases the watches. Idempotent and
        /// non-blocking: the teardown is dispatched onto the shared queue, so it never
        /// runs on the caller's thread. Because the teardown is async, a callback
        /// already in flight may still be delivered shortly after `stop()` returns;
        /// callers that must not act on late callbacks guard on their own stopped state.
        public func stop() { FileSystemWatcherInotifyInstance.shared.stop(subscriber: subscriber) }

        /// Registers additional directories on a running watcher, e.g. one created or moved in after
        /// `start()`. Synchronous so a failure can propagate back to the caller instead of being
        /// swallowed by an untracked background dispatch. A no-op while the watcher is not running;
        /// `WorkspaceWatch` only calls this once its own `start()` has succeeded, so this arises only from
        /// a caller-side race and is not worth reporting.
        ///
        /// Same `ENOENT`-is-not-a-failure rule as `start()`: a directory that vanished between being
        /// listed and registered here is skipped, not thrown; any other `inotify_add_watch` failure stops
        /// the batch and throws immediately.
        public func addPaths(_ paths: [String]) throws { try FileSystemWatcherInotifyInstance.shared.addPaths(subscriber: subscriber, paths: paths) }

        deinit {
            // The shared instance's registrations are keyed by `subscriber`, never by `self`, so the
            // teardown is dispatched onto its queue with only the id captured.
            FileSystemWatcherInotifyInstance.shared.stop(subscriber: subscriber)
        }
    }

#endif
