#if os(Linux)

    import Glibc

    /// The pure routing rules of the process-wide inotify instance: which subscriber (one
    /// `FileSystemWatcher`) owns which kernel watch descriptors, and what each parsed event means for
    /// each of them. It makes no syscalls; its mutating operations return the descriptors the caller must
    /// `inotify_rm_watch`, so the rules are testable without the kernel.
    ///
    /// The kernel hands two registrations of the same inode the SAME watch descriptor, so a descriptor
    /// maps to every subscriber on it, each with its own path (two paths can resolve to one inode).
    /// Not thread-safe: confined to the shared instance's queue.
    struct InotifyRoutingTable {
        typealias SubscriberID = UInt64

        /// One parsed inotify event. `name` is empty for events about the watched directory itself.
        struct Event: Equatable {
            let wd: Int32
            let mask: UInt32
            let name: String
        }

        /// What one subscriber receives from a drain pass: at most one `onChange` worth of data.
        struct Delivery: Equatable {
            var paths: [String] = []
            var mustRescan = false
        }

        struct Routing {
            var deliveries: [SubscriberID: Delivery] = [:]
            /// Descriptors whose last subscriber left during routing. The caller removes them from the
            /// kernel. Descriptors dropped on `IN_IGNORED` never appear here: the kernel already did.
            var wdsToRemove: [Int32] = []
        }

        private var pathsByDescriptor: [Int32: [SubscriberID: String]] = [:]
        private var descriptorsBySubscriber: [SubscriberID: Set<Int32>] = [:]
        /// Install roots per active subscriber; also what marks a subscriber as running.
        private var rootsBySubscriber: [SubscriberID: Set<String>] = [:]

        var registeredDescriptorCount: Int { pathsByDescriptor.count }

        func hasRegistration(atPath path: String) -> Bool { pathsByDescriptor.values.contains { $0.values.contains(path) } }

        func isActive(_ subscriber: SubscriberID) -> Bool { rootsBySubscriber[subscriber] != nil }

        /// `roots` are the subscriber's install roots (the `paths` it was created with): one of them
        /// being deleted or moved asks that subscriber to rescan, since nothing watches its parent.
        mutating func activate(subscriber: SubscriberID, roots: [String]) {
            rootsBySubscriber[subscriber] = Set(roots)
            descriptorsBySubscriber[subscriber] = []
        }

        mutating func register(subscriber: SubscriberID, wd: Int32, path: String) {
            pathsByDescriptor[wd, default: [:]][subscriber] = path
            descriptorsBySubscriber[subscriber, default: []].insert(wd)
        }

        /// Removes the subscriber and every registration it holds; returns the descriptors it was the
        /// last subscriber on.
        mutating func unregister(subscriber: SubscriberID) -> [Int32] {
            rootsBySubscriber.removeValue(forKey: subscriber)
            let descriptors = descriptorsBySubscriber.removeValue(forKey: subscriber) ?? []
            return descriptors.sorted().filter { dropSubscriber(subscriber, from: $0) }
        }

        /// Applies one drain pass of events. Every subscriber appears in `deliveries` at most once.
        mutating func route(_ events: [Event]) -> Routing {
            var routing = Routing()
            for event in events {
                // The kernel reports a lost-events window as one event with `wd == -1` and
                // `IN_Q_OVERFLOW` (never paired with a watch descriptor). There is no way to know which
                // paths were lost, so every subscriber must rescan: macOS's dropped-flags equivalent.
                if event.wd == -1, event.mask & UInt32(IN_Q_OVERFLOW) != 0 {
                    for subscriber in rootsBySubscriber.keys { routing.deliveries[subscriber, default: Delivery()].mustRescan = true }
                    continue
                }
                guard let subscribers = pathsByDescriptor[event.wd] else { continue }
                let isMoveSelf = event.mask & UInt32(IN_MOVE_SELF) != 0
                for (subscriber, directory) in subscribers {
                    routing.deliveries[subscriber, default: Delivery()].paths.append(event.name.isEmpty ? directory : directory + "/" + event.name)
                    // An INSTALL ROOT disappearing or moving mirrors FSEvents' RootChanged: nothing
                    // watches its parent, so a directory recreated at the same path would go unnoticed.
                    // `WorkspaceWatch` answers the rescan with a full reinstall, which fails outright
                    // with the root gone, so the live-refresh notice offers Retry instead of the pane
                    // silently freezing.
                    if event.mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF) != 0, rootsBySubscriber[subscriber]?.contains(directory) == true {
                        routing.deliveries[subscriber, default: Delivery()].mustRescan = true
                    }
                    // `IN_MOVE_SELF` does not make the kernel drop the watch: left alone, the descriptor
                    // keeps reporting from wherever the directory ended up, still mapped to its OLD path.
                    // inotify is not recursive, so a directory watched beneath the moved one has its own
                    // descriptor, gets no `IN_MOVE_SELF`, and goes just as stale. So every registration of
                    // this subscriber at or beneath the moved path is dropped, from a snapshot.
                    if isMoveSelf {
                        let stale = (descriptorsBySubscriber[subscriber] ?? []).filter { descriptor in
                            guard let path = pathsByDescriptor[descriptor]?[subscriber] else { return false }
                            return path == directory || path.hasPrefix(directory + "/")
                        }
                        for descriptor in stale.sorted() where dropSubscriber(subscriber, from: descriptor) { routing.wdsToRemove.append(descriptor) }
                    }
                }
                // `IN_IGNORED` (delete, unmount, or the removal a drop above queues) means the kernel
                // already dropped the descriptor, for every subscriber on it.
                if !isMoveSelf, event.mask & UInt32(IN_IGNORED) != 0 {
                    for subscriber in subscribers.keys { descriptorsBySubscriber[subscriber]?.remove(event.wd) }
                    pathsByDescriptor.removeValue(forKey: event.wd)
                }
            }
            return routing
        }

        /// Returns true when `subscriber` was the last one on `descriptor`.
        private mutating func dropSubscriber(_ subscriber: SubscriberID, from descriptor: Int32) -> Bool {
            descriptorsBySubscriber[subscriber]?.remove(descriptor)
            pathsByDescriptor[descriptor]?.removeValue(forKey: subscriber)
            guard pathsByDescriptor[descriptor]?.isEmpty == true else { return false }
            pathsByDescriptor.removeValue(forKey: descriptor)
            return true
        }
    }

#endif
