import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct RowPrimitivesTests {
    // MARK: Status dot

    @Test func statusDotHasFixed14ByteSquareIntrinsicSize() {
        let dot = RowPrimitives.statusDot(.running)
        #expect(dot.intrinsicContentSize == NSSize(width: 14, height: 14))
    }

    @Test func statusDotStoresAssignedKind() {
        let dot = RowPrimitives.statusDot(.idle)
        #expect(dot.kind == .idle)

        dot.kind = .running
        #expect(dot.kind == .running)
    }

    @Test func statusDotSurvivesAppearanceChange() {
        // Smoke test: the override shouldn't crash when AppKit raises it.
        let dot = RowPrimitives.statusDot(.waiting)
        dot.viewDidChangeEffectiveAppearance()
        #expect(dot.kind == .waiting)
    }

    @Test func compactStatusDotUsesWorkspaceRowGeometryAndFillStyle() {
        let running = RowPrimitives.compactStatusDot(filled: true, tint: .systemGreen, tooltip: "Running")
        let stopped = RowPrimitives.compactStatusDot(filled: false, tint: .systemGray, tooltip: "Stopped")

        #expect(running.intrinsicContentSize == NSSize(width: 10, height: 10))
        #expect(stopped.intrinsicContentSize == NSSize(width: 10, height: 10))
        #expect(running.isFilled)
        #expect(!stopped.isFilled)
        #expect(running.toolTip == "Running")
        #expect(stopped.toolTip == "Stopped")
    }

    @Test func emptyStatusSlotPreservesFixedWidth() {
        let slot = RowPrimitives.statusSlot()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(slot)
        parent.layoutSubtreeIfNeeded()

        #expect(slot.frame.width == RowPrimitives.statusSlotWidth)
        #expect(slot.subviews.isEmpty)
    }

    @Test func populatedStatusSlotCentersTheIndicator() {
        let dot = RowPrimitives.statusDot(.running)
        let slot = RowPrimitives.statusSlot(dot)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(slot)
        parent.layoutSubtreeIfNeeded()

        #expect(slot.frame.width == RowPrimitives.statusSlotWidth)
        #expect(dot.superview === slot)
        #expect(abs(dot.frame.midX - slot.frame.midX) < 0.5)
    }

    // MARK: Type icon tile

    @Test func typeIconTileIs22By22WithATintedBackground() {
        let tile = RowPrimitives.typeIconTile(.browser, symbol: "globe")
        // Give it a parent so intrinsic sizing kicks in.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(tile)
        parent.layoutSubtreeIfNeeded()

        #expect(tile.frame.size == NSSize(width: 22, height: 22))
        #expect((tile as? ColoredBackgroundView)?.cornerRadius == 5)
    }

    @Test func typeIconTileEmbedsSymbolImageView() {
        let tile = RowPrimitives.typeIconTile(.process, symbol: "terminal")
        let imageView = tile.subviews.compactMap { $0 as? NSImageView }.first
        #expect(imageView != nil, "Tile should contain one NSImageView for the glyph")
        #expect(imageView?.image != nil, "Symbol image should be populated")
    }

    @Test func typeIconTilePicksFillPairPerKind() {
        // The getter on ColoredBackgroundView holds the dynamic color reference;
        // we can't compare CGColors across appearances without resolving, so
        // just assert each kind produces a *different* background.
        let browser = RowPrimitives.typeIconTile(.browser, symbol: "globe") as? ColoredBackgroundView
        let process = RowPrimitives.typeIconTile(.process, symbol: "terminal") as? ColoredBackgroundView
        let agent = RowPrimitives.typeIconTile(.agent, symbol: "cpu.fill") as? ColoredBackgroundView

        #expect(browser?.fillColor !== process?.fillColor)
        #expect(process?.fillColor !== agent?.fillColor)
        #expect(browser?.fillColor !== agent?.fillColor)
    }

    // MARK: Chips

    @Test func shortcutChipRendersMonospaceText() {
        let chip = RowPrimitives.shortcutChip("⌘1")
        let label = chip.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.stringValue == "⌘1")
        #expect(label?.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func shortcutChipEnforcesMinimumWidth() {
        let chip = RowPrimitives.shortcutChip("⌘9")
        // Placing in a wide parent so width is driven by the constraint, not by layout.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        parent.addSubview(chip)
        parent.layoutSubtreeIfNeeded()
        #expect(chip.frame.width >= 26, "Expected ≥26pt min width, got \(chip.frame.width)")
    }

    @Test func sidebarShortcutHintRendersPlainMonospaceText() {
        let hint = RowPrimitives.sidebarShortcutHint("⌘1")
        #expect(hint.stringValue == "⌘1")
        #expect(hint.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(hint.drawsBackground == false)
        #expect(hint.subviews.isEmpty)
    }

    @Test func projectChipRendersProjectName() {
        let chip = RowPrimitives.projectChip("Spaces")
        let label = chip.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.stringValue == "Spaces")
    }

    @Test func branchChipRendersMonospaceText() {
        let chip = RowPrimitives.branchChip("feature/sidebar-redesign")
        let label = chip.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.stringValue == "feature/sidebar-redesign")
        #expect(label?.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    // MARK: ColoredBackgroundView

    @Test func coloredBackgroundViewOptsIntoWantsUpdateLayer() {
        let view = ColoredBackgroundView()
        #expect(view.wantsLayer == true)
        #expect(view.wantsUpdateLayer == true)
    }

    @Test func coloredBackgroundViewAppliesFillOnUpdateLayer() {
        let view = ColoredBackgroundView()
        view.fillColor = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        view.cornerRadius = 8
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)

        view.updateLayer()

        #expect(view.layer?.cornerRadius == 8)
        #expect(view.layer?.backgroundColor != nil)
    }
}
