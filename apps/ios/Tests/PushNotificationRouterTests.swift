#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    @MainActor final class PushNotificationRouterTests: XCTestCase {
        func testTappingTheNotificationOpensAlerts() {
            let router = PushNotificationRouter(system: FakePushSystem())
            var opened = 0
            router.connect(openAlerts: { opened += 1 }, deviceToken: { _ in })

            router.notificationTapped()

            XCTAssertEqual(opened, 1)
        }

        func testATapThatLaunchedTheAppOpensAlertsOnceTheModelConnects() {
            let router = PushNotificationRouter(system: FakePushSystem())
            router.notificationTapped()
            var opened = 0

            router.connect(openAlerts: { opened += 1 }, deviceToken: { _ in })

            XCTAssertEqual(opened, 1)
        }

        func testADeviceTokenThatArrivedEarlyIsDeliveredOnConnect() {
            let router = PushNotificationRouter(system: FakePushSystem())
            router.deviceTokenReceived(Data([1, 2]))
            var received: [Data] = []

            router.connect(openAlerts: {}, deviceToken: { received.append($0) })
            router.deviceTokenReceived(Data([3]))

            XCTAssertEqual(received, [Data([1, 2]), Data([3])])
        }

        func testAWithdrawPushRemovesDeliveredNotificationsWithoutTheModel() {
            let system = FakePushSystem()
            let router = PushNotificationRouter(system: system)

            router.backgroundPushReceived(["aps": ["content-available": 1], "spaces": ["withdraw": true]])

            XCTAssertEqual(system.removedDeliveredCount, 1)
        }

        func testOtherBackgroundPushesLeaveNotificationsAlone() {
            let system = FakePushSystem()
            let router = PushNotificationRouter(system: system)

            router.backgroundPushReceived(["aps": ["badge": 3]])
            router.backgroundPushReceived(["spaces": ["withdraw": false]])

            XCTAssertEqual(system.removedDeliveredCount, 0)
        }

        func testNothingIsPresentedWhileTheAppIsOpen() {
            XCTAssertTrue(PushNotificationRouter(system: FakePushSystem()).foregroundPresentationOptions.isEmpty)
        }
    }
#endif
