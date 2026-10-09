#if canImport(UIKit)
    import GhosttyKit
    import UIKit
    import spacesterminalcore

    /// Everything the host view keeps for touch selection. Stored here because an extension cannot hold
    /// stored properties.
    @MainActor final class GhosttyRemoteTerminalSelectionInteraction {
        var accentColor = UIColor.systemTeal
        let startHandle: TerminalSelectionHandleView
        let endHandle: TerminalSelectionHandleView
        let longPressRecognizer = UILongPressGestureRecognizer()
        var editMenuInteraction: UIEditMenuInteraction?

        /// A long press or a handle drag is growing the selection.
        var isTouchActive = false
        /// Where the dragging finger's selection point is, which is the finger itself for a long press and
        /// the finger plus its offset to the bar for a handle. Kept so the cell under it can be resolved
        /// again when the frame beneath it changes.
        var pointerLocation: CGPoint?
        var handleGrabOffset = CGSize.zero
        var isPointerResolveScheduled = false
        var autoscrollTask: Task<Void, Never>?
        var autoscrollDirection: TerminalSelectionAutoscroll.Direction?

        /// A long press that went to a program tracking the mouse, with the cell it last reported.
        var programDragPosition: TerminalScrollPointerPosition?

        /// The Select key forces the next long press to select text. It turns itself off once a selection
        /// is made.
        var isSelectModeOn = false

        var isMenuWanted = false
        var isMenuPresented = false
        var presentedMenuAnchor = CGRect.zero
        var menuAnchor = CGRect.zero
        /// Where the handles are drawn now, which decides which of them a touch grabs.
        var handleLayout: TerminalSelectionHandleLayout?

        var wordSelectionHandlerForTesting: ((CGPoint) -> TerminalAbsoluteSelection?)?

        init() {
            startHandle = TerminalSelectionHandleView(handle: .start, color: accentColor)
            endHandle = TerminalSelectionHandleView(handle: .end, color: accentColor)
            for handleView in [startHandle, endHandle] {
                handleView.owningHandle = { [weak self] point in self?.handleLayout?.handle(atX: Double(point.x), y: Double(point.y)) }
            }
        }
    }

    extension GhosttyRemoteTerminalHostView {
        // MARK: Install

        func installSelectionInteraction() {
            let interaction = selectionInteraction
            interaction.longPressRecognizer.addTarget(self, action: #selector(handleSelectionLongPress(_:)))
            // A pan that starts before the hold finishes is a scroll; the hold must stay still to count.
            interaction.longPressRecognizer.allowableMovement = 10
            interaction.longPressRecognizer.delegate = self
            addGestureRecognizer(interaction.longPressRecognizer)
            for handleView in [interaction.startHandle, interaction.endHandle] {
                handleView.isHidden = true
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
                pan.maximumNumberOfTouches = 1
                handleView.addGestureRecognizer(pan)
                addSubview(handleView)
            }
            let menu = UIEditMenuInteraction(delegate: self)
            interaction.editMenuInteraction = menu
            addInteraction(menu)
        }

        public func setSelectionAccentColor(_ color: UIColor) {
            guard selectionInteraction.accentColor != color else { return }
            selectionInteraction.accentColor = color
            selectionInteraction.startHandle.setColor(color)
            selectionInteraction.endHandle.setColor(color)
        }

        /// Takes the selection the owner holds. Called before the frame it paints into is rendered.
        public func setClientSelection(_ selection: TerminalAbsoluteSelection?) {
            guard clientSelection != selection else { return }
            clientSelection = selection
            if selection == nil {
                selectionInteraction.isMenuWanted = false
                dismissSelectionMenu()
            } else if !selectionInteraction.isTouchActive {
                selectionInteraction.isMenuWanted = true
            }
        }

        // MARK: Geometry

        struct SelectionGridGeometry {
            let originX: CGFloat
            let originY: CGFloat
            let cellWidth: CGFloat
            let cellHeight: CGFloat
        }

        /// Where the grid sits in this view: inside Ghostty's own padding, laid out with the cell size the
        /// surface renders with. A tap's cell and a selection's cell are quantized by the same numbers so
        /// they name the cell the user sees.
        func selectionGridGeometry() -> SelectionGridGeometry? {
            let renderBounds = visibleRenderBounds()
            guard renderBounds.width > 0, renderBounds.height > 0 else { return nil }
            let scale = currentScaleFactor
            let padding = CGFloat(Double(GhosttyTerminalCellMetricsCache.paddingPerSidePx(scale: scale)) / scale)
            let cell = GhosttyRemoteTerminalViewport.cellMetrics(fontSize: fontSize, scale: CGFloat(scale))
            guard cell.width > 0, cell.height > 0 else { return nil }
            return SelectionGridGeometry(
                originX: renderBounds.minX + padding, originY: renderBounds.minY + padding, cellWidth: cell.width, cellHeight: cell.height)
        }

        /// The absolute cell under `location`, held inside the grid: a finger past an edge names the
        /// edge row, and the edge scroll carries it further.
        private func absoluteCell(at location: CGPoint) -> TerminalAbsoluteCell? {
            guard let geometry = selectionGridGeometry(), let snapshot = currentRenderedSnapshot, snapshot.columns > 0, snapshot.rows > 0 else {
                return nil
            }
            let column = Int(((location.x - geometry.originX) / geometry.cellWidth).rounded(.down))
            let row = Int(((location.y - geometry.originY) / geometry.cellHeight).rounded(.down))
            return TerminalAbsoluteCell(
                column: min(max(column, 0), snapshot.columns - 1), row: Int64(snapshot.historyRowBase) + Int64(min(max(row, 0), snapshot.rows - 1)))
        }

        // MARK: Long press

        private var shouldSendLongPressToProgram: Bool {
            acceptsTerminalInput && onSendMouseButton != nil && mirrorCapturesMouse && !selectionInteraction.isSelectModeOn && !isShiftModifierPending
        }

        @objc private func handleSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: self)
            switch recognizer.state {
            case .began: beginLongPress(at: location)
            case .changed: continueLongPress(at: location)
            case .ended, .cancelled, .failed: endLongPress()
            default: break
            }
        }

        private func beginLongPress(at location: CGPoint) {
            stopMomentum()
            if shouldSendLongPressToProgram, let position = tappedCellPointerPosition(for: location),
                onSendMouseButton?(UInt8(clamping: GHOSTTY_MOUSE_LEFT.rawValue), true, position) == true
            {
                selectionInteraction.programDragPosition = position
                return
            }
            // A refused press (this client is not the owner, or it is reading its own replay) leaves the
            // long press to select text.
            guard let word = selectWord(at: location) else { return }
            beginSelectionTouch()
            selectionInteraction.pointerLocation = location
            selectionActions?.beginWordSelection(word)
            setSelectModeOn(false)
        }

        private func continueLongPress(at location: CGPoint) {
            if let last = selectionInteraction.programDragPosition {
                // Motion goes once per cell, and only when the frame's tracking level wants it with the
                // button held.
                guard let position = tappedCellPointerPosition(for: location), position.x != last.x || position.y != last.y else { return }
                selectionInteraction.programDragPosition = position
                guard currentRenderedSnapshot?.mouseTrackingLevel.reportsMotion(buttonHeld: true) == true else { return }
                _ = onSendMouseMotion?(position)
            } else if selectionInteraction.isTouchActive {
                updateSelectionDrag(pointer: location)
            }
        }

        private func endLongPress() {
            if let last = selectionInteraction.programDragPosition {
                selectionInteraction.programDragPosition = nil
                _ = onSendMouseButton?(UInt8(clamping: GHOSTTY_MOUSE_LEFT.rawValue), false, last)
            } else if selectionInteraction.isTouchActive {
                finishSelectionTouch()
            }
        }

        /// Selects the word under the finger by Ghostty's own word rule, which the mirror's surface applies
        /// to a double click on the frame on screen (live or replay) with no read of the replay.
        ///
        /// A program tracking the mouse swallows the click unless shift rides with it, which is how the
        /// terminal tells "this click is mine"; that is why the Select key exists, and why a program that
        /// captures shift itself (XTSHIFTESCAPE) cannot be selected in.
        private func selectWord(at location: CGPoint) -> TerminalAbsoluteSelection? {
            if let handler = selectionInteraction.wordSelectionHandlerForTesting { return handler(location) }
            guard let mirror, let surface = mirrorSurface(), let snapshot = currentRenderedSnapshot else { return nil }
            // The mirror keeps the previous word's selection and click gesture across frames (the client
            // paints its own selection into the snapshot, never into the mirror). Ghostty reads a shift
            // press with a selection standing, once the click-repeat interval has passed, as "extend that
            // selection", so a second word pressed in a mouse-tracking program would grow from the first.
            // With no selection standing the shift press falls through to an ordinary click, and the two
            // presses below make a double click on the pressed word.
            ghostty_mirror_set_selection(mirror, false, false, 0, 0, 0, 0)
            let position = Self.ghosttyMousePosition(for: location)
            let mods = ghostty_input_mods_e(mirrorCapturesMouse ? GHOSTTY_MODS_SHIFT.rawValue : 0)
            ghostty_surface_mouse_pos(surface, position.x, position.y, mods)
            for _ in 0..<2 {
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
            }
            var info = ghostty_mirror_selection_info_s()
            ghostty_mirror_selection_info(mirror, &info)
            guard info.present else { return nil }
            let base = Int64(snapshot.historyRowBase)
            return TerminalAbsoluteSelection(
                from: TerminalAbsoluteCell(column: Int(info.start_x), row: base + Int64(info.start_y)),
                to: TerminalAbsoluteCell(column: Int(info.end_x), row: base + Int64(info.end_y)), isRectangle: false,
                historyEpoch: snapshot.historyEpoch)
        }

        // MARK: Handles

        @objc private func handleSelectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let handleView = recognizer.view as? TerminalSelectionHandleView else { return }
            let location = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                stopMomentum()
                beginSelectionTouch()
                // The bar's point travels with the finger; the end bar sits on the boundary after its cell,
                // so half a cell inward names the cell the bar belongs to.
                let inset = (selectionGridGeometry()?.cellWidth ?? 0) / 2
                selectionInteraction.handleGrabOffset = CGSize(
                    width: handleView.grabPoint.x - location.x + (handleView.handle == .start ? inset : -inset),
                    height: handleView.grabPoint.y - location.y)
                selectionActions?.beginHandleDrag(handleView.handle)
                updateSelectionDrag(pointer: pointer(for: location))
            case .changed: updateSelectionDrag(pointer: pointer(for: location))
            case .ended, .cancelled, .failed: finishSelectionTouch()
            default: break
            }
        }

        private func pointer(for fingerLocation: CGPoint) -> CGPoint {
            let offset = selectionInteraction.handleGrabOffset
            return CGPoint(x: fingerLocation.x + offset.width, y: fingerLocation.y + offset.height)
        }

        // MARK: Drag

        private func beginSelectionTouch() {
            selectionInteraction.isTouchActive = true
            selectionInteraction.isMenuWanted = false
            dismissSelectionMenu()
        }

        private func updateSelectionDrag(pointer: CGPoint) {
            selectionInteraction.pointerLocation = pointer
            resolveSelectionPointer()
            updateSelectionAutoscroll(pointer: pointer)
        }

        private func resolveSelectionPointer() {
            guard selectionInteraction.isTouchActive, let pointer = selectionInteraction.pointerLocation, let cell = absoluteCell(at: pointer) else {
                return
            }
            selectionActions?.extendDrag(cell)
        }

        /// A frame changed under a held finger (the edge scroll moved the replay, or output arrived), so
        /// the cell under it names other text. Hopped out of the render because rendering can run inside a
        /// SwiftUI update, which must not mutate the observable selection it is reading.
        func scheduleSelectionPointerResolve() {
            guard selectionInteraction.isTouchActive, selectionInteraction.pointerLocation != nil, !selectionInteraction.isPointerResolveScheduled
            else { return }
            selectionInteraction.isPointerResolveScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectionInteraction.isPointerResolveScheduled = false
                self.resolveSelectionPointer()
            }
        }

        private func finishSelectionTouch() {
            selectionInteraction.isTouchActive = false
            selectionInteraction.pointerLocation = nil
            stopSelectionAutoscroll()
            selectionActions?.endDrag()
            selectionInteraction.isMenuWanted = clientSelection != nil
            refreshSelectionChrome()
        }

        private func updateSelectionAutoscroll(pointer: CGPoint) {
            let bounds = visibleRenderBounds()
            let direction: TerminalSelectionAutoscroll.Direction? =
                pointer.y <= bounds.minY + 1 ? .towardOlderRows : pointer.y >= bounds.maxY - 1 ? .towardNewerRows : nil
            guard let direction else {
                stopSelectionAutoscroll()
                return
            }
            guard selectionInteraction.autoscrollDirection != direction else { return }
            stopSelectionAutoscroll()
            selectionInteraction.autoscrollDirection = direction
            selectionInteraction.autoscrollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.selectionActions?.autoscroll(direction == .towardOlderRows)
                    try? await Task.sleep(for: TerminalSelectionAutoscroll.interval)
                }
            }
        }

        func stopSelectionAutoscroll() {
            selectionInteraction.autoscrollTask?.cancel()
            selectionInteraction.autoscrollTask = nil
            selectionInteraction.autoscrollDirection = nil
        }

        // MARK: Select key

        func setSelectModeOn(_ isOn: Bool) {
            guard selectionInteraction.isSelectModeOn != isOn else { return }
            selectionInteraction.isSelectModeOn = isOn
            updateSelectKey()
        }

        func toggleSelectMode() { setSelectModeOn(!selectionInteraction.isSelectModeOn) }

        /// The Select key exists while the program tracks the mouse, since only then does a long press
        /// go to the program instead of selecting text.
        func refreshSelectKey() {
            if currentRenderedSnapshot?.mouseTrackingLevel.isActive != true { selectionInteraction.isSelectModeOn = false }
            updateSelectKey()
        }

        private func updateSelectKey() {
            let isVisible = acceptsTerminalInput && currentRenderedSnapshot?.mouseTrackingLevel.isActive == true
            setSelectKeyState(isVisible: isVisible, isOn: selectionInteraction.isSelectModeOn)
        }

        // MARK: Chrome

        /// Places the handles on the selection's ends and shows the menu above it when the selection is
        /// at rest.
        func refreshSelectionChrome() {
            let interaction = selectionInteraction
            guard clientSelection != nil, let snapshot = currentRenderedSnapshot, let range = snapshot.selection,
                let geometry = selectionGridGeometry()
            else {
                interaction.startHandle.isHidden = true
                interaction.endHandle.isHidden = true
                interaction.handleLayout = nil
                dismissSelectionMenu()
                return
            }
            let layout = TerminalSelectionHandleLayout(
                range: range, originX: Double(geometry.originX), originY: Double(geometry.originY), cellWidth: Double(geometry.cellWidth),
                cellHeight: Double(geometry.cellHeight), columns: snapshot.columns)
            interaction.handleLayout = layout
            place(interaction.startHandle, at: layout.start)
            place(interaction.endHandle, at: layout.end)
            interaction.menuAnchor = CGRect(x: layout.anchorMinX, y: layout.anchorMinY, width: layout.anchorWidth, height: layout.anchorHeight)
            presentSelectionMenuIfAtRest()
        }

        private func place(_ handleView: TerminalSelectionHandleView, at handle: TerminalSelectionHandleLayout.Handle?) {
            guard let handle else {
                handleView.isHidden = true
                return
            }
            handleView.isHidden = false
            handleView.place(handle)
        }

        private func presentSelectionMenuIfAtRest() {
            let interaction = selectionInteraction
            guard interaction.isMenuWanted, !interaction.isTouchActive, scrollInteractionDepth == 0, window != nil,
                bounds.intersects(interaction.menuAnchor), let menu = interaction.editMenuInteraction
            else {
                if interaction.isTouchActive || scrollInteractionDepth > 0 { dismissSelectionMenu() }
                return
            }
            if interaction.isMenuPresented {
                guard interaction.presentedMenuAnchor != interaction.menuAnchor else { return }
                menu.dismissMenu()
            }
            interaction.presentedMenuAnchor = interaction.menuAnchor
            menu.presentEditMenu(
                with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: interaction.menuAnchor.midX, y: interaction.menuAnchor.minY)))
        }

        func dismissSelectionMenu() { selectionInteraction.editMenuInteraction?.dismissMenu() }

        func copySelectionFromMenu() {
            selectionInteraction.isMenuWanted = false
            selectionActions?.copy()
        }

        func selectAllFromMenu() { selectionActions?.selectAll() }

        // MARK: Testing

        func setWordSelectionHandlerForTesting(_ handler: ((CGPoint) -> TerminalAbsoluteSelection?)?) {
            selectionInteraction.wordSelectionHandlerForTesting = handler
        }

        func debugLongPressForTesting(_ state: UIGestureRecognizer.State, at location: CGPoint) {
            switch state {
            case .began: beginLongPress(at: location)
            case .changed: continueLongPress(at: location)
            default: endLongPress()
            }
        }

        func debugSelectionHandleDragForTesting(_ handle: TerminalSelectionHandle, from start: CGPoint, to end: CGPoint) {
            let handleView = handle == .start ? selectionInteraction.startHandle : selectionInteraction.endHandle
            beginSelectionTouch()
            let inset = (selectionGridGeometry()?.cellWidth ?? 0) / 2
            selectionInteraction.handleGrabOffset = CGSize(
                width: handleView.grabPoint.x - start.x + (handle == .start ? inset : -inset), height: handleView.grabPoint.y - start.y)
            selectionActions?.beginHandleDrag(handle)
            updateSelectionDrag(pointer: pointer(for: end))
            finishSelectionTouch()
        }

        func debugToggleSelectKeyForTesting() { toggleSelectMode() }

        func debugSelectionHandleGrabPointForTesting(_ handle: TerminalSelectionHandle) -> CGPoint {
            (handle == .start ? selectionInteraction.startHandle : selectionInteraction.endHandle).grabPoint
        }

        var debugIsSelectKeyOnForTesting: Bool { selectionInteraction.isSelectModeOn }
        var debugVisibleSelectionHandlesForTesting: [TerminalSelectionHandle] {
            [selectionInteraction.startHandle, selectionInteraction.endHandle].filter { !$0.isHidden }.map(\.handle)
        }
    }

    extension GhosttyRemoteTerminalHostView: UIGestureRecognizerDelegate {
        /// A touch on a selection handle belongs to the handle's own drag, not to a scroll, a long press or
        /// a tap on the terminal behind it.
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view is TerminalSelectionHandleView)
        }
    }

    extension GhosttyRemoteTerminalHostView: @preconcurrency UIEditMenuInteractionDelegate {
        public func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            UIMenu(children: [
                UIAction(title: "Copy") { [weak self] _ in self?.copySelectionFromMenu() },
                UIAction(title: "Select All") { [weak self] _ in self?.selectAllFromMenu() },
            ])
        }

        public func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            selectionInteraction.menuAnchor
        }

        public func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) { selectionInteraction.isMenuPresented = true }

        public func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) { selectionInteraction.isMenuPresented = false }
    }
#endif
