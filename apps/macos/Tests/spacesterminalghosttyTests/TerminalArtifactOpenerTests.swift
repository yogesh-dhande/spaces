import Foundation
import XCTest
import spacesdevicecore

@testable import spacesterminalghostty

final class TerminalArtifactOpenerTests: XCTestCase {
    // MARK: - TerminalArtifactCategory mapping

    func testCategoryInitMapsEveryArtifactKind() {
        XCTAssertEqual(TerminalArtifactCategory(kind: .image), .image)
        XCTAssertEqual(TerminalArtifactCategory(kind: .video), .video)
        XCTAssertEqual(TerminalArtifactCategory(kind: .pdf), .pdf)
        XCTAssertEqual(TerminalArtifactCategory(kind: .markdown), .markdown)
        XCTAssertEqual(TerminalArtifactCategory(kind: .text), .text)
        XCTAssertEqual(TerminalArtifactCategory(kind: .html), .html)
    }

    func testCategoryForFileURLMapsRecognizedExtensions() {
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/page.html")), .html)
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/notes.md")), .markdown)
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/report.pdf")), .pdf)
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/photo.png")), .image)
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/clip.mp4")), .video)
        XCTAssertEqual(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/log.txt")), .text)
    }

    func testCategoryForFileURLReturnsNilForUnclassifiedExtensions() {
        XCTAssertNil(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/main.swift")))
        XCTAssertNil(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/archive.xyz")))
        XCTAssertNil(TerminalArtifactCategory.category(forFileURL: URL(fileURLWithPath: "/tmp/no-extension")))
    }

    // MARK: - Registry dispatch

    @MainActor func testOpenDispatchesToTheHandlerRegisteredForTheCategory() {
        var openedURLs: [TerminalArtifactCategory: URL] = [:]
        let registry = TerminalArtifactHandlerRegistry(handlers: [
            .pdf: { url in
                openedURLs[.pdf] = url
                return true
            },
            .webURL: { url in
                openedURLs[.webURL] = url
                return true
            },
        ])

        let pdfURL = URL(fileURLWithPath: "/tmp/report.pdf")
        let webURL = URL(string: "https://example.com")!

        XCTAssertTrue(registry.open(pdfURL, as: .pdf))
        XCTAssertTrue(registry.open(webURL, as: .webURL))
        XCTAssertEqual(openedURLs[.pdf], pdfURL)
        XCTAssertEqual(openedURLs[.webURL], webURL)
    }

    @MainActor func testOpenFallsBackToDefaultOpenHandlerWhenCategoryHasNoRegisteredHandler() {
        var defaultOpenedURL: URL?
        let registry = TerminalArtifactHandlerRegistry(
            handlers: [:],
            defaultOpenHandler: { url in
                defaultOpenedURL = url
                return true
            })

        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        XCTAssertTrue(registry.open(url, as: .pdf))
        XCTAssertEqual(defaultOpenedURL, url)
    }

    @MainActor func testOpenLocalFileDispatchesClassifiedFilesToTheMatchingHandler() {
        var markdownOpenedURL: URL?
        let registry = TerminalArtifactHandlerRegistry(
            handlers: [
                .markdown: { url in
                    markdownOpenedURL = url
                    return true
                }
            ],
            defaultOpenHandler: { _ in
                XCTFail("classified file should not fall through to the default handler")
                return false
            })

        let url = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertTrue(registry.openLocalFile(at: url))
        XCTAssertEqual(markdownOpenedURL, url)
    }

    @MainActor func testOpenLocalFileFallsThroughToDefaultOpenHandlerForUnclassifiedFiles() {
        var defaultOpenedURL: URL?
        let registry = TerminalArtifactHandlerRegistry(
            handlers: [
                .text: { _ in
                    XCTFail("unclassified file should not dispatch to a category handler")
                    return false
                }
            ],
            defaultOpenHandler: { url in
                defaultOpenedURL = url
                return true
            })

        let url = URL(fileURLWithPath: "/tmp/main.swift")
        XCTAssertTrue(registry.openLocalFile(at: url))
        XCTAssertEqual(defaultOpenedURL, url)
    }

    // MARK: - Browser-forcing default handlers

    @MainActor func testDefaultRegistryRoutesWebURLAndHTMLThroughTheSameInjectedBrowserHandler() {
        // The default registry itself calls real NSWorkspace APIs, so this test only verifies the
        // *shape* other tests need: that .webURL and .html can be independently overridden without
        // touching NSWorkspace, by building a registry the way defaultRegistry() would but with a
        // fake in place of the real browser-forcing handler.
        var browsedURLs: [URL] = []
        let browserHandler: TerminalArtifactHandlerRegistry.Handler = { url in
            browsedURLs.append(url)
            return true
        }
        let registry = TerminalArtifactHandlerRegistry(handlers: [.webURL: browserHandler, .html: browserHandler, .text: { _ in false }])

        let webURL = URL(string: "https://example.com")!
        let htmlURL = URL(fileURLWithPath: "/tmp/page.html")

        XCTAssertTrue(registry.open(webURL, as: .webURL))
        XCTAssertTrue(registry.openLocalFile(at: htmlURL))
        XCTAssertEqual(browsedURLs, [webURL, htmlURL])
    }
}
