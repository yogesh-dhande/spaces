import XCTest

@testable import workspacecore

final class ServiceNameTests: XCTestCase {
    func testValidatedAcceptsAndTrims() throws {
        XCTAssertEqual(try ServiceName.validated(" web "), "web")
        XCTAssertEqual(try ServiceName.validated("admin-ui"), "admin-ui")
        XCTAssertEqual(try ServiceName.validated("a1"), "a1")
    }

    func testValidatedRejectsNonDNSLabels() {
        for value in ["Web", "web_1", "web.api", "-web", "web-", "", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try ServiceName.validated(value), "expected \(value) to be rejected")
        }
    }

    func testValidatedUniqueRejectsDuplicateServiceNames() throws {
        XCTAssertEqual(try ServiceName.validatedUnique([" web ", "api"]), ["web", "api"])
        XCTAssertThrowsError(try ServiceName.validatedUnique(["web", "api", "web"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Duplicate service name"))
        }
    }

    func testPortEnvVarUppercasesAndReplacesHyphens() {
        XCTAssertEqual(ServiceName.portEnvVar(for: "web"), "SPACES_WEB_PORT")
        XCTAssertEqual(ServiceName.portEnvVar(for: "admin-ui"), "SPACES_ADMIN_UI_PORT")
    }

    func testURLEnvVarUppercasesAndReplacesHyphens() { XCTAssertEqual(ServiceName.urlEnvVar(for: "admin-ui"), "SPACES_ADMIN_UI_URL") }

    func testIsValidLabel() {
        XCTAssertTrue(ServiceName.isValidLabel("web"))
        XCTAssertTrue(ServiceName.isValidLabel(" web "))
        XCTAssertFalse(ServiceName.isValidLabel("Web"))
        XCTAssertFalse(ServiceName.isValidLabel(""))
    }
}
