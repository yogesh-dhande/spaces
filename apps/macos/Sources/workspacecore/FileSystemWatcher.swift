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
        private let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        /// Only read or written on `queue`, except in `deinit` where no other
        /// reference to `self` can exist so the access is race-free.
        private var stream: FSEventStreamRef?

        public init(
            paths: [String], latency: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
            onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
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
    /// Lifecycle invariant (mirrors the macOS backend): `inotify_add_watch` can block
    /// on a slow filesystem, so stream setup/teardown and the `fileDescriptor`,
    /// `source`, and `watchedDirectoriesByDescriptor` state they mutate are confined
    /// to `queue` — also the read source's event queue — via `async` dispatch, keeping
    /// them off the caller's thread and free of data races.
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
            private static func errnoText(_ code: Int32) -> String {
                "\(String(cString: strerror(code))) (\(errnoName(code)))"
            }

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

        /// Metadata git rewrites on worktree/HEAD changes, plus the directory-level create/delete/move
        /// events that signal a worktree (or, for `WorkspaceWatch`, any other directory) added or removed,
        /// and self-delete/move so a vanished directory drops its watch. `IN_ATTRIB` covers a `chmod`,
        /// `chown`, `utimes`, or `truncate` on a tracked file (all report through `setattr`, never through
        /// `IN_MODIFY` alone), which is what `chmod +x` on a tracked file needs to be observed: it changes
        /// the rendered diff and `scopeSignature` without writing any new file content. `IN_ATTRIB` fires
        /// only from those `setattr`-driven changes, not from an inode's atime updating on an ordinary
        /// read, so this adds no read-driven churn. Shared by `startOnQueue` and `addPaths` so a directory
        /// registered after start gets the identical mask.
        private static let watchMask = UInt32(
            IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF | IN_DELETE_SELF | IN_ONLYDIR)

        private let paths: [String]
        private let queue: DispatchQueue
        private let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        /// Only read or written on `queue`, except in `deinit` where no other
        /// reference to `self` can exist so the access is race-free.
        private var fileDescriptor: Int32 = -1
        private var source: DispatchSourceRead?
        private var watchedDirectoriesByDescriptor: [Int32: String] = [:]

        public init(
            paths: [String], latency _: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "spaces.filesystemwatcher", qos: .utility),
            onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
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

        /// Serialized on `queue`; see the type's lifecycle invariant. A path missing by the time its watch
        /// is registered (`ENOENT`, e.g. it was created and removed again between listing and this call)
        /// is not a failure: it is simply skipped, and the loop continues with the remaining paths. Any
        /// other `inotify_add_watch` failure (most commonly `ENOSPC`, the `fs.inotify.max_user_watches`
        /// limit) stops the whole install immediately rather than silently leaving the workspace with
        /// partial coverage the caller has no way to know about.
        private func startOnQueue() throws {
            guard fileDescriptor < 0 else { return }
            guard !paths.isEmpty else { throw WatchError.noPaths }
            let descriptor = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard descriptor >= 0 else { throw WatchError.initFailed(errno: errno) }
            for path in paths {
                let watchDescriptor = inotify_add_watch(descriptor, path, Self.watchMask)
                if watchDescriptor >= 0 {
                    watchedDirectoriesByDescriptor[watchDescriptor] = path
                    continue
                }
                let failureErrno = errno
                if failureErrno == ENOENT { continue }
                close(descriptor)
                throw WatchError.watchFailed(path: path, errno: failureErrno)
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

        /// Registers additional directories on a running watcher, e.g. one created or moved in after
        /// `start()`. Serialized on `queue` like the other lifecycle calls, synchronously (`queue.sync`,
        /// not `queue.async`) so a failure can actually propagate back to the caller instead of being
        /// swallowed by an untracked background dispatch. A no-op while the watcher is not running;
        /// `WorkspaceWatch` only calls this once its own `start()` has succeeded, so this arises only from
        /// a caller-side race and is not worth reporting.
        ///
        /// Same `ENOENT`-is-not-a-failure rule as `startOnQueue`: a directory that vanished between being
        /// listed and registered here is skipped, not thrown; any other `inotify_add_watch` failure stops
        /// the batch and throws immediately.
        public func addPaths(_ paths: [String]) throws {
            try queue.sync {
                guard fileDescriptor >= 0 else { return }
                for path in paths {
                    let watchDescriptor = inotify_add_watch(fileDescriptor, path, Self.watchMask)
                    if watchDescriptor >= 0 {
                        watchedDirectoriesByDescriptor[watchDescriptor] = path
                        continue
                    }
                    let failureErrno = errno
                    if failureErrno == ENOENT { continue }
                    throw WatchError.watchFailed(path: path, errno: failureErrno)
                }
            }
        }

        /// Reads all currently-available inotify events in one pass (the read source
        /// fires once per readable burst, which coalesces a change burst into one
        /// `onChange`) and reports the affected absolute paths.
        private func drainEvents() {
            let headerSize = MemoryLayout<inotify_event>.size
            var buffer = [UInt8](repeating: 0, count: 8192)
            var changedPaths: [String] = []
            // The kernel reports a lost-events window as one event with `wd == -1` and `IN_Q_OVERFLOW`
            // set (never paired with a watch descriptor), meaning some events between the last drain and
            // this one were dropped rather than delivered. There is no way to know which paths those were,
            // so this is macOS's `mustScanSubDirs`/dropped-flags equivalent: the caller must rescan.
            var mustRescan = false
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
                if bytesRead <= 0 { break }
                var offset = 0
                while offset + headerSize <= bytesRead {
                    let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                    let nameLength = Int(event.len)
                    if event.wd == -1, event.mask & UInt32(IN_Q_OVERFLOW) != 0 {
                        mustRescan = true
                        offset += headerSize + nameLength
                        continue
                    }
                    let directory = watchedDirectoriesByDescriptor[event.wd]
                    if let directory {
                        if nameLength > 0 {
                            let nameStart = offset + headerSize
                            let nameBytes = buffer[nameStart..<(nameStart + nameLength)].prefix { $0 != 0 }
                            let name = String(decoding: nameBytes, as: UTF8.self)
                            changedPaths.append(name.isEmpty ? directory : directory + "/" + name)
                        } else {
                            // `IN_MOVE_SELF` (the watched directory itself was moved or renamed, to
                            // anywhere, including outside this watcher's root) and `IN_DELETE_SELF` both
                            // land here with no name payload, so this also reports the old path for a
                            // self-move: a destination still inside the workspace is re-registered through
                            // the parent's `IN_MOVED_TO`, which `WorkspaceWatch` already treats as a new
                            // directory, so nothing else needs to observe the new location from here.
                            changedPaths.append(directory)
                        }
                    }
                    // An INSTALL ROOT (one of `paths`) disappearing or moving mirrors FSEvents'
                    // RootChanged (above): nothing watches its parent, so a directory recreated at the
                    // same path would go unnoticed. `WorkspaceWatch` answers a rescan with a full
                    // reinstall, which fails outright with the root gone (`streamUnavailable`, every root
                    // `ENOENT`), surfacing the live-refresh notice with Retry instead of a silent freeze;
                    // a root recreated later is picked up by Retry or the next subscribe.
                    if event.mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF) != 0, let directory, paths.contains(directory) {
                        mustRescan = true
                    }
                    // `IN_MOVE_SELF` does not make the kernel drop the watch (a delete does, via
                    // `IN_IGNORED`): left alone, the descriptor keeps reporting events from wherever the
                    // directory ended up, still mapped to its OLD path. inotify is not recursive, so a
                    // directory watched beneath the moved one (`root/a/b` under `root/a`) has its own
                    // descriptor and gets no `IN_MOVE_SELF` of its own; it goes just as stale. So every
                    // descriptor at or beneath the moved path is removed, from a snapshot since the table
                    // is mutated in the loop. `IN_IGNORED` (delete, unmount, or the `inotify_rm_watch`
                    // just below, which queues one for the same descriptor) drops the mapping too.
                    if event.mask & UInt32(IN_MOVE_SELF) != 0, let movedPath = directory {
                        let staleDescriptors = watchedDirectoriesByDescriptor.filter { $0.value == movedPath || $0.value.hasPrefix(movedPath + "/") }
                            .keys
                        for descriptor in staleDescriptors {
                            inotify_rm_watch(fileDescriptor, descriptor)
                            watchedDirectoriesByDescriptor.removeValue(forKey: descriptor)
                        }
                    } else if event.mask & UInt32(IN_IGNORED) != 0 {
                        watchedDirectoriesByDescriptor.removeValue(forKey: event.wd)
                    }
                    offset += headerSize + nameLength
                }
            }
            if !changedPaths.isEmpty || mustRescan { onChange(changedPaths, mustRescan) }
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
