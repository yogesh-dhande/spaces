// Routing rules of the shared inotify instance, exercised without the kernel.
#if os(Linux)
    import Glibc
    import Testing

    @testable import workspacecore

    @Suite struct FileSystemWatcherInotifyRoutingTests {
        private typealias Table = InotifyRoutingTable

        private let a: Table.SubscriberID = 1
        private let b: Table.SubscriberID = 2

        private func event(_ wd: Int32, _ mask: Int32, _ name: String = "") -> Table.Event { Table.Event(wd: wd, mask: UInt32(mask), name: name) }

        @Test func overflowAsksEveryActiveSubscriberToRescan() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/x"])
            table.activate(subscriber: b, roots: ["/y"])

            let routing = table.route([event(-1, Int32(IN_Q_OVERFLOW))])

            #expect(routing.deliveries == [a: .init(paths: [], mustRescan: true), b: .init(paths: [], mustRescan: true)])
            #expect(routing.wdsToRemove.isEmpty)
        }

        @Test func eventOnASharedDescriptorReachesBothSubscribersWithTheirOwnPaths() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/real/dir"])
            table.activate(subscriber: b, roots: ["/alias/dir"])
            table.register(subscriber: a, wd: 7, path: "/real/dir")
            table.register(subscriber: b, wd: 7, path: "/alias/dir")

            let routing = table.route([event(7, Int32(IN_MODIFY), "f.txt")])

            #expect(routing.deliveries[a] == .init(paths: ["/real/dir/f.txt"], mustRescan: false))
            #expect(routing.deliveries[b] == .init(paths: ["/alias/dir/f.txt"], mustRescan: false))
        }

        @Test func eventForADescriptorWithNoSubscribersIsIgnored() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/x"])
            #expect(table.route([event(99, Int32(IN_MODIFY), "f")]).deliveries.isEmpty)
        }

        @Test func unregisterReturnsADescriptorOnlyWhenItsLastSubscriberLeaves() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/d"])
            table.activate(subscriber: b, roots: ["/d"])
            table.register(subscriber: a, wd: 3, path: "/d")
            table.register(subscriber: b, wd: 3, path: "/d")
            table.register(subscriber: a, wd: 4, path: "/d/sub")

            #expect(table.unregister(subscriber: a) == [4])
            #expect(table.registeredDescriptorCount == 1)
            #expect(!table.isActive(a))
            #expect(table.unregister(subscriber: b) == [3])
            #expect(table.registeredDescriptorCount == 0)
        }

        @Test func ignoredDropsTheDescriptorForEverySubscriberWithoutAskingForRemoval() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/d"])
            table.activate(subscriber: b, roots: ["/d"])
            table.register(subscriber: a, wd: 3, path: "/d")
            table.register(subscriber: b, wd: 3, path: "/d")

            let routing = table.route([event(3, Int32(IN_IGNORED))])

            #expect(routing.wdsToRemove.isEmpty)
            #expect(table.registeredDescriptorCount == 0)
            #expect(table.unregister(subscriber: a).isEmpty)
        }

        @Test func moveSelfDropsTheSubscribersRegistrationsAtOrBeneathTheMovedPath() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/root"])
            table.activate(subscriber: b, roots: ["/other"])
            table.register(subscriber: a, wd: 1, path: "/root")
            table.register(subscriber: a, wd: 2, path: "/root/a")
            table.register(subscriber: a, wd: 3, path: "/root/a/b")
            table.register(subscriber: a, wd: 4, path: "/root/ab")
            // Subscriber b also watches the moved inode, and keeps a registration of its own beneath it.
            table.register(subscriber: b, wd: 2, path: "/root/a")
            table.register(subscriber: b, wd: 3, path: "/elsewhere/b")

            let routing = table.route([event(2, Int32(IN_MOVE_SELF))])

            // Both subscribers receive the move and drop their own registrations beneath /root/a. wd 2 has
            // no subscriber left and is removed; wd 3 is still held by b through a path outside the move.
            #expect(routing.wdsToRemove == [2])
            #expect(table.hasRegistration(atPath: "/root"))
            #expect(table.hasRegistration(atPath: "/root/ab"))
            #expect(!table.hasRegistration(atPath: "/root/a"))
            #expect(!table.hasRegistration(atPath: "/root/a/b"))
            #expect(table.hasRegistration(atPath: "/elsewhere/b"))
        }

        @Test func rootDeletionOrMoveRescansOnlyTheSubscriberWhoseInstallRootItIs() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/root"])
            table.activate(subscriber: b, roots: ["/other"])
            table.register(subscriber: a, wd: 1, path: "/root")
            table.register(subscriber: b, wd: 1, path: "/root")

            let deleted = table.route([event(1, Int32(IN_DELETE_SELF))])
            #expect(deleted.deliveries[a]?.mustRescan == true)
            #expect(deleted.deliveries[b]?.mustRescan == false)

            let moved = table.route([event(1, Int32(IN_MOVE_SELF))])
            #expect(moved.deliveries[a]?.mustRescan == true)
            #expect(moved.deliveries[b]?.mustRescan == false)
        }

        @Test func oneDrainPassProducesOneDeliveryPerSubscriberInEventOrder() {
            var table = Table()
            table.activate(subscriber: a, roots: ["/d"])
            table.register(subscriber: a, wd: 1, path: "/d")

            let routing = table.route([event(1, Int32(IN_CREATE), "one"), event(1, Int32(IN_MODIFY), "two"), event(-1, Int32(IN_Q_OVERFLOW))])

            #expect(routing.deliveries == [a: .init(paths: ["/d/one", "/d/two"], mustRescan: true)])
        }
    }
#endif
