import XCTest

@testable import spacesterminalcore

final class DNSLabelTests: XCTestCase {
    func testIsValidAcceptsDNSLabels() {
        for value in ["web", "admin-ui", "a1", "a", String(repeating: "a", count: 63)] {
            XCTAssertTrue(DNSLabel.isValid(value), "expected \(value) to be valid")
        }
    }

    func testIsValidRejectsNonLabels() {
        for value in ["", "Web", "web_1", "web.api", "-web", "web-", String(repeating: "a", count: 64)] {
            XCTAssertFalse(DNSLabel.isValid(value), "expected \(value) to be rejected")
        }
    }

    func testSanitizeProducesValidLabel() {
        XCTAssertEqual(DNSLabel.sanitize("Feature/Foo Bar"), "feature-foo-bar")
        XCTAssertEqual(DNSLabel.sanitize("--a--"), "a")
        XCTAssertEqual(DNSLabel.sanitize("!!!"), "x")
        XCTAssertTrue(DNSLabel.isValid(DNSLabel.sanitize(String(repeating: "a", count: 100))))
    }

    func testWorkspaceHostSlugIsValidAndDeterministic() {
        let slug = SpacesProfile.workspaceHostSlug(branch: "feature/Foo Bar", workspaceID: "abc-123")
        XCTAssertTrue(DNSLabel.isValid(slug))
        XCTAssertTrue(slug.hasPrefix("feature-foo-bar-"))
        XCTAssertEqual(slug, SpacesProfile.workspaceHostSlug(branch: "feature/Foo Bar", workspaceID: "abc-123"))
        XCTAssertTrue(DNSLabel.isValid(SpacesProfile.workspaceHostSlug(branch: nil, workspaceID: "x")))
        XCTAssertTrue(DNSLabel.isValid(SpacesProfile.workspaceHostSlug(branch: "HEAD", workspaceID: "x")))
    }

    func testWorkspaceHostSlugPreservesHashSuffixForLongBranches() {
        let branch = String(repeating: "feature-", count: 12) + "workspace-router"
        let first = SpacesProfile.workspaceHostSlug(branch: branch, workspaceID: "workspace-one")
        let second = SpacesProfile.workspaceHostSlug(branch: branch, workspaceID: "workspace-two")

        XCTAssertTrue(DNSLabel.isValid(first))
        XCTAssertTrue(DNSLabel.isValid(second))
        XCTAssertEqual(first.count, DNSLabel.maxLength)
        XCTAssertEqual(second.count, DNSLabel.maxLength)
        XCTAssertTrue(first.hasSuffix("-\(SpacesProfile.shortStableHash("workspace-one"))"))
        XCTAssertTrue(second.hasSuffix("-\(SpacesProfile.shortStableHash("workspace-two"))"))
        XCTAssertNotEqual(first, second)
    }
}
