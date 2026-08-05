import Foundation
import XCTest
import spacesterminalcore
import workspacecore

#if os(macOS)
    @testable import spacesd

    /// Guards that the profile (terminal-service) transport classifies failures identically to the Device API
    /// server (`SpacesDeviceAPIServer.errorCode(for:)`): a client must see the same machine-readable code for
    /// the same cause regardless of transport. Automation boundary rejections are the regression this locks
    /// down — before they were recognized here they landed `internalError` on the profile socket while the
    /// Device API already reported `invalidArgument`.
    final class SpacesDaemonErrorClassificationTests: XCTestCase {
        func testAutomationValidationErrorMapsToInvalidArgument() {
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(AutomationValidationError("bad")), .invalidArgument)
        }

        func testAutomationCronScheduleErrorMapsToInvalidArgument() {
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(AutomationCronScheduleError("bad cron")), .invalidArgument)
        }

        func testWorkspaceErrorAndFallbackClassificationsAreUnchanged() {
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(WorkspaceError.missingWorkspace(project: "p", workspace: "w")), .notFound)
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(WorkspaceError.invalidArgument(message: "x")), .invalidArgument)
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(WorkspaceError.daemonHandoffInProgress), .handingOff)
            struct Unclassified: Error {}
            XCTAssertEqual(SpacesDaemonErrorClassification.errorCode(Unclassified()), .internalError)
        }
    }
#endif
