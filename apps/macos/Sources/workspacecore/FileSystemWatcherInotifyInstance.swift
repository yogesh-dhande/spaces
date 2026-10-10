#if os(Linux)

    import Foundation
    import Glibc

    /// The one inotify instance of the process, shared by every Linux `FileSystemWatcher`.
    ///
    /// Linux caps inotify instances per user (`fs.inotify.max_user_instances`, default 128) across every
    /// process the user runs. One instance per watcher would let a daemon with many projects and
    /// subscribed workspaces exhaust it, so unwatched projects and the user's editors, language servers,
    /// and dev servers would all fail with `inotify_init1: Too many open files`. A single shared instance
    /// keeps the footprint at one regardless of watcher count.
    ///
    /// Accepted trade-offs, taken because the instance limit is the scarce per-user resource:
    /// - The kernel's event queue (`max_queued_events`) is shared, so a burst in one watched tree can
    ///   overflow it and make every watcher rescan.
    /// - `inotify_add_watch` can block on a slow filesystem, which now stalls event delivery for every
    ///   watcher in the process, not only the one being set up.
    ///
    /// Queue ownership: `queue` confines all inotify state and every inotify syscall (`inotify_add_watch`,
    /// `inotify_rm_watch`, reads), and is the read source's event queue. Watchers reach it with `async`
    /// (start, stop, deinit) or `sync` (`addPaths`, which must return a failure); it never `sync`s onto a
    /// watcher's queue. Change batches reach a watcher by `async` onto that watcher's own queue.
    ///
    /// Every registration uses `watchMask`. A second `inotify_add_watch` on an already-watched inode
    /// REPLACES its mask unless `IN_MASK_ADD` is passed, so registrations by different subscribers must
    /// all carry one mask for none of them to lose events.
    final class FileSystemWatcherInotifyInstance: @unchecked Sendable {
        static let shared = FileSystemWatcherInotifyInstance()

        /// Metadata git rewrites on worktree/HEAD changes, plus the directory-level create/delete/move
        /// events that signal a worktree (or, for `WorkspaceWatch`, any other directory) added or removed,
        /// and self-delete/move so a vanished directory drops its watch. `IN_ATTRIB` covers a `chmod`,
        /// `chown`, `utimes`, or `truncate` on a tracked file (all report through `setattr`, never through
        /// `IN_MODIFY` alone), which is what `chmod +x` on a tracked file needs to be observed: it changes
        /// the rendered diff and `scopeSignature` without writing any new file content. `IN_ATTRIB` fires
        /// only from those `setattr`-driven changes, not from an inode's atime updating on an ordinary
        /// read, so this adds no read-driven churn.
        static let watchMask = UInt32(
            IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF | IN_DELETE_SELF | IN_ONLYDIR)

        /// Where a subscriber's batches go. Holds the watcher's queue and handler, never the watcher, so a
        /// watcher can deinit while registered.
        private struct Sink {
            let queue: DispatchQueue
            let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        }

        private let queue = DispatchQueue(label: "spaces.filesystemwatcher.inotify", qos: .utility)
        private let idLock = NSLock()
        private var lastSubscriberID: InotifyRoutingTable.SubscriberID = 0
        /// The remaining state is only read or written on `queue`.
        private var descriptor: Int32 = -1
        private var source: DispatchSourceRead?
        private var table = InotifyRoutingTable()
        private var sinks: [InotifyRoutingTable.SubscriberID: Sink] = [:]

        private init() {}

        /// Monotonic, never reused: a late `stop` from a deallocated watcher cannot hit a newer one.
        func makeSubscriberID() -> InotifyRoutingTable.SubscriberID {
            idLock.lock()
            defer { idLock.unlock() }
            lastSubscriberID += 1
            return lastSubscriberID
        }

        /// Synchronous read on `queue` (so it orders after earlier `async` calls), for tests.
        func hasRegistration(atPath path: String) -> Bool { queue.sync { table.hasRegistration(atPath: path) } }

        func start(
            subscriber: InotifyRoutingTable.SubscriberID, roots: [String], queue watcherQueue: DispatchQueue,
            onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        try self.startOnQueue(subscriber: subscriber, roots: roots, sink: Sink(queue: watcherQueue, onChange: onChange))
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        /// A path missing by the time its watch is registered (`ENOENT`, e.g. it was created and removed
        /// again between listing and this call) is not a failure: it is skipped, and the loop continues.
        /// Any other `inotify_add_watch` failure (most commonly `ENOSPC`, the `fs.inotify.max_user_watches`
        /// limit) undoes what this call added and throws, rather than silently leaving the subscriber with
        /// partial coverage the caller has no way to know about.
        private func startOnQueue(subscriber: InotifyRoutingTable.SubscriberID, roots: [String], sink: Sink) throws {
            guard !table.isActive(subscriber) else { return }
            guard !roots.isEmpty else { throw FileSystemWatcher.WatchError.noPaths }
            // A failed `inotify_init1` is not cached: the next start tries again.
            try ensureInitialized()
            table.activate(subscriber: subscriber, roots: roots)
            sinks[subscriber] = sink
            var registered = 0
            for path in roots {
                let watchDescriptor = inotify_add_watch(descriptor, path, Self.watchMask)
                if watchDescriptor >= 0 {
                    table.register(subscriber: subscriber, wd: watchDescriptor, path: path)
                    registered += 1
                    continue
                }
                let failureErrno = errno
                if failureErrno == ENOENT { continue }
                removeOnQueue(subscriber: subscriber)
                throw FileSystemWatcher.WatchError.watchFailed(path: path, errno: failureErrno)
            }
            guard registered > 0 else {
                removeOnQueue(subscriber: subscriber)
                throw FileSystemWatcher.WatchError.streamUnavailable
            }
        }

        /// Creates the instance and its read source on first use; kept open for the process lifetime.
        private func ensureInitialized() throws {
            guard descriptor < 0 else { return }
            let created = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard created >= 0 else { throw FileSystemWatcher.WatchError.initFailed(errno: errno) }
            descriptor = created
            let source = DispatchSource.makeReadSource(fileDescriptor: created, queue: queue)
            source.setEventHandler { [unowned self] in self.drainEvents() }
            self.source = source
            source.resume()
        }

        /// Non-blocking. A batch already dispatched to the watcher's queue may still be delivered shortly
        /// after; callers that must not act on late callbacks guard on their own stopped state.
        func stop(subscriber: InotifyRoutingTable.SubscriberID) { queue.async { self.removeOnQueue(subscriber: subscriber) } }

        private func removeOnQueue(subscriber: InotifyRoutingTable.SubscriberID) {
            sinks.removeValue(forKey: subscriber)
            for watchDescriptor in table.unregister(subscriber: subscriber) { inotify_rm_watch(descriptor, watchDescriptor) }
        }

        /// Synchronous so a failure propagates to the caller. A no-op while `subscriber` is not running.
        /// Same `ENOENT` rule as `startOnQueue`; any other failure stops the batch and throws, keeping
        /// what earlier paths in the batch registered.
        func addPaths(subscriber: InotifyRoutingTable.SubscriberID, paths: [String]) throws {
            try queue.sync {
                guard table.isActive(subscriber) else { return }
                for path in paths {
                    let watchDescriptor = inotify_add_watch(descriptor, path, Self.watchMask)
                    if watchDescriptor >= 0 {
                        table.register(subscriber: subscriber, wd: watchDescriptor, path: path)
                        continue
                    }
                    let failureErrno = errno
                    if failureErrno == ENOENT { continue }
                    throw FileSystemWatcher.WatchError.watchFailed(path: path, errno: failureErrno)
                }
            }
        }

        /// Reads all currently-available events in one pass (the read source fires once per readable
        /// burst, which coalesces a change burst) and hands each subscriber at most one batch.
        private func drainEvents() {
            let headerSize = MemoryLayout<inotify_event>.size
            var buffer = [UInt8](repeating: 0, count: 8192)
            var events: [InotifyRoutingTable.Event] = []
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if bytesRead <= 0 { break }
                var offset = 0
                while offset + headerSize <= bytesRead {
                    let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                    let nameLength = Int(event.len)
                    var name = ""
                    if nameLength > 0 {
                        let nameStart = offset + headerSize
                        name = String(decoding: buffer[nameStart..<(nameStart + nameLength)].prefix { $0 != 0 }, as: UTF8.self)
                    }
                    events.append(InotifyRoutingTable.Event(wd: event.wd, mask: event.mask, name: name))
                    offset += headerSize + nameLength
                }
            }
            guard !events.isEmpty else { return }
            let routing = table.route(events)
            for watchDescriptor in routing.wdsToRemove { inotify_rm_watch(descriptor, watchDescriptor) }
            for (subscriber, delivery) in routing.deliveries {
                guard let sink = sinks[subscriber] else { continue }
                sink.queue.async { sink.onChange(delivery.paths, delivery.mustRescan) }
            }
        }
    }

#endif
