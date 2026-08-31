#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import spacesterminalmobileghostty

    /// `GhosttyTerminalCellMetricsCache` needs no live surface, window, or main actor either, so it is
    /// exercised directly against an isolated `UserDefaults` suite per the repo's test-env hygiene
    /// (a distinct suite name per test, removed in `tearDown`) rather than through the host view.
    final class GhosttyTerminalCellMetricsCacheTests: XCTestCase {
        private var suiteName = ""
        private var defaults: UserDefaults!

        override func setUp() {
            super.setUp()
            suiteName = "GhosttyTerminalCellMetricsCacheTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)
        }

        override func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            defaults = nil
            super.tearDown()
        }

        private func makeCache(stamp: String = "stamp-1") -> GhosttyTerminalCellMetricsCache {
            GhosttyTerminalCellMetricsCache(defaults: defaults, storageKey: "cache", stamp: stamp)
        }

        func testEntriesAreKeyedByFontSizeAndScaleIndependently() {
            let cache = makeCache()
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 24, height: 51)
            cache.recordCellPixelSize(fontSizePoints: 12, scale: 3.0, width: 29, height: 61)
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 2.0, width: 16, height: 34)

            XCTAssertEqual(cache.cellPixelSize(fontSizePoints: 10, scale: 3.0), .init(width: 24, height: 51))
            XCTAssertEqual(cache.cellPixelSize(fontSizePoints: 12, scale: 3.0), .init(width: 29, height: 61))
            XCTAssertEqual(cache.cellPixelSize(fontSizePoints: 10, scale: 2.0), .init(width: 16, height: 34))
            XCTAssertNil(cache.cellPixelSize(fontSizePoints: 11, scale: 3.0), "an unrecorded font size must miss, not fall back to a neighbor")
        }

        func testAStampMismatchDropsEveryExistingEntry() {
            let cacheV1 = makeCache(stamp: "stamp-1")
            cacheV1.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 24, height: 51)
            XCTAssertNotNil(cacheV1.cellPixelSize(fontSizePoints: 10, scale: 3.0))

            // A different stamp (an app/GhosttyKit update, or the generated config's content
            // changing) reads through the same UserDefaults storage but must see nothing recorded
            // under the old stamp.
            let cacheV2 = makeCache(stamp: "stamp-2")
            XCTAssertNil(cacheV2.cellPixelSize(fontSizePoints: 10, scale: 3.0))

            cacheV2.recordCellPixelSize(fontSizePoints: 9, scale: 2.0, width: 16, height: 34)
            XCTAssertNil(cacheV1.cellPixelSize(fontSizePoints: 10, scale: 3.0), "recording under the new stamp must not resurrect the old entry")
            XCTAssertEqual(cacheV2.cellPixelSize(fontSizePoints: 9, scale: 2.0), .init(width: 16, height: 34))
        }

        func testRecordingOverwritesAMismatchedEntryForTheSameKey() {
            let cache = makeCache()
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 20, height: 40)
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 24, height: 51)

            XCTAssertEqual(
                cache.cellPixelSize(fontSizePoints: 10, scale: 3.0), .init(width: 24, height: 51),
                "the live surface's later read must replace a stale prediction rather than sit alongside it")
        }

        func testAnEntryPersistsThroughANewCacheInstanceOverTheSameStorage() {
            let cache = makeCache()
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 24, height: 51)

            let reloaded = makeCache()
            XCTAssertEqual(reloaded.cellPixelSize(fontSizePoints: 10, scale: 3.0), .init(width: 24, height: 51))
        }

        /// `paddingPerSidePx` per iOS's non-macOS `default_dpi = 96` (see the doc comment on the
        /// constant): scale 2.0 -> 5px/side, scale 3.0 -> 8px/side. Confirmed against a live iOS
        /// surface (booted-simulator `xcodebuild test`, font sizes 9/10/12): scale 2.0 measured a
        /// 10px total padding, scale 3.0 measured 16px total, both exactly 2x this per-side value.
        func testPaddingPerSidePixelsMatchesTheMeasuredIOSDefaultDPI() {
            XCTAssertEqual(GhosttyTerminalCellMetricsCache.paddingPerSidePx(scale: 2.0), 5)
            XCTAssertEqual(GhosttyTerminalCellMetricsCache.paddingPerSidePx(scale: 3.0), 8)
        }

        func testPredictedGridAppliesThePaddingCorrectFloorMathOnBothAxes() {
            let cache = makeCache()
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 2.0, width: 10, height: 20)

            // scale 2.0 -> 5px padding/side (10 total). 125pt x 100pt at scale 2.0 is 250x200px;
            // content is (250-10)x(200-10) = 240x190px; 240/10 = 24 columns, 190/20 = 9.5 -> 9 rows.
            let predicted = cache.predictedGrid(fontSizePoints: 10, scale: 2.0, renderBoundsWidth: 125, renderBoundsHeight: 100)
            XCTAssertEqual(predicted?.columns, 24)
            XCTAssertEqual(predicted?.rows, 9)
        }

        /// Grounded in the same live-surface probe as `testPaddingPerSidePixelsMatchesTheMeasuredIOSDefaultDPI`:
        /// at scale 3.0, font size 10, a real surface measured `cellWidthPx=24` and reported the
        /// grid's column count flipping from 6 to 7 exactly at `widthPx=184`. `predictedGrid` must
        /// reproduce that same flip from a cached `cellWidthPx=24` alone.
        func testPredictedGridReproducesALiveMeasuredColumnFlip() {
            let cache = makeCache()
            cache.recordCellPixelSize(fontSizePoints: 10, scale: 3.0, width: 24, height: 51)

            // 61pt * 3.0 = 183px (one below the measured flip) -> still 6 columns.
            XCTAssertEqual(cache.predictedGrid(fontSizePoints: 10, scale: 3.0, renderBoundsWidth: 61, renderBoundsHeight: 400)?.columns, 6)
            // 62pt * 3.0 = 186px (past the measured flip at 184) -> 7 columns.
            XCTAssertEqual(cache.predictedGrid(fontSizePoints: 10, scale: 3.0, renderBoundsWidth: 62, renderBoundsHeight: 400)?.columns, 7)
        }

        func testPredictedGridReturnsNilWithoutACachedEntry() {
            let cache = makeCache()
            XCTAssertNil(cache.predictedGrid(fontSizePoints: 10, scale: 3.0, renderBoundsWidth: 400, renderBoundsHeight: 400))
        }
    }

#endif
